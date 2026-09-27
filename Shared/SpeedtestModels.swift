import Foundation

public enum SpeedtestPhase: Sendable, Equatable {
    case latency
    case download
    case upload

    public var title: String {
        switch self {
        case .latency: "Пинг"
        case .download: "Скачивание"
        case .upload: "Загрузка"
        }
    }
}

public struct SpeedtestResult: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var downloadMbps: Double
    public var uploadMbps: Double
    public var pingMs: Double
    public var jitterMs: Double
    public var ip: String?

    public init(id: UUID = UUID(), date: Date, downloadMbps: Double, uploadMbps: Double,
                pingMs: Double, jitterMs: Double, ip: String? = nil) {
        self.id = id
        self.date = date
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.pingMs = pingMs
        self.jitterMs = jitterMs
        self.ip = ip
    }

    public static func samples(_ count: Int = 20) -> [SpeedtestResult] {
        var rng = SystemRandomNumberGenerator()
        let now = Date()
        return (0..<count).map { i in
            let base = Double(80 + Int((0..<6).randomElement(using: &rng)!))
            return SpeedtestResult(
                date: now.addingTimeInterval(Double(i - count) * 1800),
                downloadMbps: base + Double.random(in: -15...15),
                uploadMbps: base * 0.6 + Double.random(in: -10...10),
                pingMs: 12 + Double.random(in: 0...8),
                jitterMs: 1 + Double.random(in: 0...4)
            )
        }
    }
}

public enum SpeedtestError: LocalizedError, Equatable {
    case badResponse
    case downloadFailed
    case uploadFailed
    case cancelled(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse: "Сервер вернул неожиданный ответ"
        case .downloadFailed: "Не удалось скачать тестовые данные"
        case .uploadFailed: "Не удалось загрузить тестовые данные"
        case .cancelled(let reason): reason
        }
    }
}

extension Double {
    /// "138" для >= 100, иначе "72.5"
    public var speedString: String {
        self >= 100 ? String(Int(self.rounded())) : String(format: "%.1f", self)
    }

    public var latencyString: String {
        self >= 100 ? String(Int(self.rounded())) : String(format: "%.1f", self)
    }
}
