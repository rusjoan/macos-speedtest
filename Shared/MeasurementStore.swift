import Foundation

/// История измерений. Храним в собственном контейнере расширения виджета
/// (~/Library/Containers/<widget bundle id>/Data/...): appex обязан быть сэндбоксированным
/// и умеет читать только свой контейнер, а несэндбоксированный агент спокойно пишет туда же.
/// App Group не используем — она требует registered capability в профиле.
public final class MeasurementStore: @unchecked Sendable {
    public static let shared = MeasurementStore()

    public static let historyLimit = 48

    public let directory: URL
    public let fileURL: URL

    private let lock = NSLock()
    private var items: [SpeedtestResult]

    public init() {
        let fm = FileManager.default
        let widgetBundleID = "ru.rusjoan.selectel-speedtest.widget"
        let home = fm.homeDirectoryForCurrentUser
        let dir: URL
        if home.path.contains("/Library/Containers/\(widgetBundleID)/Data") {
            // мы запущены внутри сэндбокс-контейнера виджета: home уже указывает на его Data
            dir = home.appendingPathComponent("Library/SelectelSpeedtest", isDirectory: true)
        } else {
            dir = home.appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Library/SelectelSpeedtest", isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        fileURL = dir.appendingPathComponent("history.json")
        items = Self.loadResults(from: fileURL)
        NSLog("[SpeedtestStore] dir=%@ exists=%d loaded=%d", dir.path, fm.fileExists(atPath: fileURL.path), items.count)
    }

    public var results: [SpeedtestResult] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    public func append(_ result: SpeedtestResult) {
        lock.lock()
        items.append(result)
        if items.count > Self.historyLimit {
            items.removeFirst(items.count - Self.historyLimit)
        }
        let snapshot = items
        lock.unlock()
        Self.save(snapshot, to: fileURL)
    }

    public func reload() {
        lock.lock()
        items = Self.loadResults(from: fileURL)
        lock.unlock()
    }

    private static func loadResults(from url: URL) -> [SpeedtestResult] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let ns = error as NSError
            NSLog("[SpeedtestStore] read failed: %@ (%d) %@", url.path, ns.code, ns.userInfo[NSLocalizedDescriptionKey] as? String ?? "")
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            let results = try decoder.decode([SpeedtestResult].self, from: data)
            NSLog("[SpeedtestStore] decoded %d records from %@", results.count, url.path)
            return results
        } catch {
            NSLog("[SpeedtestStore] decode failed: %@", String(describing: error))
            return []
        }
    }

    private static func save(_ results: [SpeedtestResult], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(results) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
