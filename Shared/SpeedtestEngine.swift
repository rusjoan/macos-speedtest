import Foundation

/// Реализация протокола LibreSpeed, который использует https://speedtest.selectel.ru:
///   - latency:   GET  empty.php                  (N маленьких запросов)
///   - download:  GET  garbage.php?r=..&ckSize=20 (потоковые данные)
///   - upload:    POST empty.php                  (тело произвольного размера)
public final class SpeedtestEngine: @unchecked Sendable {
    public static let baseURL = URL(string: "https://speedtest.selectel.ru")!

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 180
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: cfg)
    }

    private func makeURL(_ path: String, query: String) -> URL {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.query = query
        return comps.url!
    }

    private var requestID: String { String(Double.random(in: 0..<1)) }

    // MARK: - Полный цикл измерения

    public func measure(
        progress: @escaping @Sendable (SpeedtestPhase, Double) -> Void = { _, _ in },
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) async throws -> SpeedtestResult {
        func cancelled() -> Bool { Task.isCancelled || shouldCancel() }

        let latency = try await measureLatency(progress: progress) { cancelled() }
        let download = try await measureDownload(progress: progress) { cancelled() }
        let upload = try await measureUpload(progress: progress) { cancelled() }
        let ip = await fetchIP()

        return SpeedtestResult(
            date: Date(),
            downloadMbps: download,
            uploadMbps: upload,
            pingMs: latency.pingMs,
            jitterMs: latency.jitterMs,
            ip: ip
        )
    }

    // MARK: - Пинг и джиттер

    private struct LatencyStats {
        var pingMs: Double
        var jitterMs: Double
    }

    private func measureLatency(
        progress: @escaping @Sendable (SpeedtestPhase, Double) -> Void,
        cancelled: @escaping () -> Bool
    ) async throws -> LatencyStats {
        progress(.latency, 0)
        var rtts: [Double] = []
        for i in 0..<14 {
            if cancelled() { throw SpeedtestError.cancelled("Измерение остановлено") }
            var request = URLRequest(url: makeURL("empty.php", query: "r=\(requestID)"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let start = DispatchTime.now()
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw SpeedtestError.badResponse
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            rtts.append(ms)
            if i < 13 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        let kept = Array(rtts.dropFirst(2))
        guard !kept.isEmpty else { throw SpeedtestError.badResponse }
        let ping = kept.sorted()[kept.count / 2]
        let diffs = zip(kept, kept.dropFirst()).map { abs($1 - $0) }
        let jitter = diffs.reduce(0, +) / Double(max(diffs.count, 1))
        return LatencyStats(pingMs: ping, jitterMs: jitter)
    }

    private func fetchIP() async -> String? {
        var request = URLRequest(url: makeURL("getIP.php", query: "isp=false&r=\(requestID)"))
        request.timeoutInterval = 5
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        return String(data: data.prefix(128), encoding: .utf8)
    }

    // MARK: - Скачивание

    private final class DownloadProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let lock = NSLock()
        var bytes: Int64 = 0

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            bytes += Int64(data.count)
            lock.unlock()
        }
    }

    private func measureDownload(
        progress: @escaping @Sendable (SpeedtestPhase, Double) -> Void,
        cancelled: @escaping () -> Bool
    ) async throws -> Double {
        let probe = DownloadProbe()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        let session = URLSession(configuration: cfg, delegate: probe, delegateQueue: nil)

        let request = URLRequest(url: makeURL("garbage.php", query: "r=\(requestID)&ckSize=20"))
        let streams = 4
        let budget: TimeInterval = 10
        let byteCap: Int64 = 500_000_000

        // garbage.php отдаёт ровно один чанк ckSize (20 МБ) и закрывает ответ, поэтому
        // завершившиеся потоки нужно сразу перезапускать, иначе окно измерения простаивает.
        let startedAt = Date()
        var tasks: [URLSessionDataTask?] = Array(repeating: nil, count: streams)
        for i in 0..<streams {
            let task = session.dataTask(with: request)
            tasks[i] = task
            task.resume()
        }

        var lastReport = Date.distantPast
        while true {
            try Task.checkCancellation()
            if cancelled() {
                tasks.compactMap { $0 }.forEach { $0.cancel() }
                throw SpeedtestError.cancelled("Измерение остановлено")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= budget || probe.bytes >= byteCap { break }
            for i in 0..<streams where tasks[i]?.state == .completed {
                let task = session.dataTask(with: request)
                tasks[i] = task
                task.resume()
            }
            if Date().timeIntervalSince(lastReport) > 0.5 {
                lastReport = Date()
                progress(.download, Double(probe.bytes) * 8 / max(elapsed, 0.5) / 1_000_000)
            }
        }
        tasks.compactMap { $0 }.forEach { $0.cancel() }
        session.invalidateAndCancel()

        let elapsed = max(Date().timeIntervalSince(startedAt), 0.2)
        guard probe.bytes > 0 else { throw SpeedtestError.downloadFailed }
        return Double(probe.bytes) * 8 / elapsed / 1_000_000
    }

    // MARK: - Загрузка

    private final class UploadProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let lock = NSLock()
        var bytes: Int64 = 0
        private var lastTotalByTask: [Int: Int64] = [:]

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            lock.lock()
            let prev = lastTotalByTask[task.taskIdentifier] ?? 0
            bytes += totalBytesSent - prev
            lastTotalByTask[task.taskIdentifier] = totalBytesSent
            lock.unlock()
        }
    }

    private func measureUpload(
        progress: @escaping @Sendable (SpeedtestPhase, Double) -> Void,
        cancelled: @escaping () -> Bool
    ) async throws -> Double {
        let probe = UploadProbe()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        let session = URLSession(configuration: cfg, delegate: probe, delegateQueue: nil)

        var request = URLRequest(url: makeURL("empty.php", query: "r=\(requestID)"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let chunk = Data(count: 4 * 1024 * 1024)

        let streams = 4
        let budget: TimeInterval = 10
        let byteCap: Int64 = 500_000_000
        let startedAt = Date()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<streams {
                group.addTask {
                    while !Task.isCancelled, Date().timeIntervalSince(startedAt) < budget {
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            let task = session.uploadTask(with: request, from: chunk) { _, _, _ in
                                cont.resume()
                            }
                            task.resume()
                        }
                    }
                }
            }

            var lastReport = Date.distantPast
            while !group.isEmpty {
                if Task.isCancelled { group.cancelAll(); break }
                if cancelled() {
                    session.getAllTasks { $0.forEach { $0.cancel() } }
                    group.cancelAll()
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed >= budget || probe.bytes >= byteCap {
                    session.getAllTasks { $0.forEach { $0.cancel() } }
                    group.cancelAll()
                    break
                }
                if Date().timeIntervalSince(lastReport) > 0.5 {
                    lastReport = Date()
                    progress(.upload, Double(probe.bytes) * 8 / max(elapsed, 0.5) / 1_000_000)
                }
            }
            for await _ in group {}
        }
        session.invalidateAndCancel()

        let elapsed = max(Date().timeIntervalSince(startedAt), 0.2)
        guard probe.bytes > 0 else { throw SpeedtestError.uploadFailed }
        return Double(probe.bytes) * 8 / elapsed / 1_000_000
    }
}
