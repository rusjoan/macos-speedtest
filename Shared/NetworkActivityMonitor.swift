import Foundation

/// Оценка сетевой активности по системным счётчикам интерфейсов (sysctl NET_RT_IFLIST2, 64-битные счётчики).
/// Не различает процессы: это суммарный трафик машины, поэтому «чужая» активность во время
/// измерения оценивается как общий трафик минус трафик самого теста.
public enum NetworkActivityMonitor {

    private static let excludedPrefixes = ["lo", "awdl", "llw", "bridge", "ap", "pktap", "stf", "gif", "utun", "vmnet"]

    // NET_RT_IFLIST2 / RTM_IFINFO2 не экспортируются в Swift — используем их числовые значения.
    private static let netRTIFLIST2: Int32 = 0x0068
    private static let rtmIFINFO2: u_char = 0x12

    /// Суммарные байты по всем физическим интерфейсам (rx + tx) на данный момент.
    public static func counters() -> (rx: Int64, tx: Int64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, netRTIFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        let names = interfaceNamesByIndex()
        var rx: Int64 = 0
        var tx: Int64 = 0

        buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= length {
                let ptr = base.advanced(by: offset)
                let header = ptr.load(as: rt_msghdr.self)
                let messageLength = Int(header.rtm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                if header.rtm_type == rtmIFINFO2,
                   messageLength >= MemoryLayout<if_msghdr2>.size {
                    let message = ptr.load(as: if_msghdr2.self)
                    let name = names[message.ifm_index] ?? ""
                    let excluded = excludedPrefixes.contains { name.hasPrefix($0) }
                    if !excluded {
                        rx += Int64(message.ifm_data.ifi_ibytes)
                        tx += Int64(message.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
        }
        return (rx, tx)
    }

    /// Средняя пропускная способность (rx+tx) за окно `window` секунд, Мбит/с.
    public static func throughputMbps(window: TimeInterval = 3) async -> Double {
        let first = counters()
        try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
        let second = counters()
        let bytes = max(0, second.rx - first.rx) + max(0, second.tx - first.tx)
        return Double(bytes) * 8 / window / 1_000_000
    }

    private static func interfaceNamesByIndex() -> [UInt16: String] {
        var result: [UInt16: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }
        var cursor = ifaddr
        while let current = cursor {
            let ifa = current.pointee
            if let name = ifa.ifa_name {
                let nameString = String(cString: name)
                let index = if_nametoindex(name)
                if index != 0 { result[UInt16(index)] = nameString }
            }
            cursor = current.pointee.ifa_next
        }
        return result
    }
}

/// Постоянно работающий сэмплер: раз в ~20 секунд измеряет трафик за 3-секундное окно
/// и хранит историю за последние 10 минут. Используется для решения «спокойна ли сеть
/// в последние 5 минут» и для отмены измерения при начавшейся активности.
public final class ActivitySampler: @unchecked Sendable {
    public struct Sample: Sendable {
        public let date: Date
        public let mbps: Double
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var task: Task<Void, Never>?
    private var lastMbps: Double = 0

    public init() {}

    public func start(interval: TimeInterval = 20, window: TimeInterval = 3) {
        lock.lock()
        let alreadyRunning = task != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let newTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let mbps = await NetworkActivityMonitor.throughputMbps(window: window)
                self.recordSample(mbps: mbps)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        lock.lock()
        task = newTask
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    private func recordSample(mbps: Double) {
        lock.lock()
        lastMbps = mbps
        samples.append(Sample(date: Date(), mbps: mbps))
        let cutoff = Date().addingTimeInterval(-600)
        samples.removeAll { $0.date < cutoff }
        lock.unlock()
    }

    /// Мгновенная оценка текущего трафика (последний замер), Мбит/с.
    public var currentMbps: Double {
        lock.lock(); defer { lock.unlock() }
        return lastMbps
    }

    /// true, если в последние `minutes` минут все замеры ниже `thresholdMbps`.
    /// Недостаток истории трактуется оптимистично (важно, чтобы свежие замеры были тихими).
    public func wasQuiet(minutes: Double = 5, thresholdMbps: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        let recent = samples.filter { $0.date >= cutoff }
        guard let newest = samples.last, newest.date > Date().addingTimeInterval(-120) else { return false }
        return recent.allSatisfy { $0.mbps < thresholdMbps }
    }
}
