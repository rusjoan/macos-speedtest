import Foundation
import Network
import WidgetKit

/// Планировщик фоновых измерений.
///
/// Правила:
///  - измерение запускается по расписанию (интервал, по умолчанию 1 час) только если
///    в последние 5 минут сетевая активность была околонулевой;
///  - явная кнопка «Измерить сейчас» запускает измерение независимо от активности;
///  - если во время измерения началась другая сетевая активность («чужой» трафик,
///    т.е. общий минус трафик самого теста), измерение останавливается;
///  - то же самое можно сделать кнопкой «Стоп».
@MainActor
public final class MeasurementScheduler: ObservableObject {

    public static let shared = MeasurementScheduler()

    public enum State: Equatable {
        case idle(nextRun: Date)
        case waitingQuiet(nextRun: Date)
        case offline(nextRun: Date)
        case paused
        case running(phase: SpeedtestPhase, currentMbps: Double)

        public var label: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            switch self {
            case .idle(let next):
                return "Следующее измерение: \(formatter.string(from: next))"
            case .waitingQuiet(let next):
                return "Жду затишья в сети (по \(formatter.string(from: next)) не позднее)"
            case .offline(let next):
                return "Нет сети, повторю в \(formatter.string(from: next))"
            case .paused:
                return "Пауза: измерения остановлены (например, телефон в режиме модема)"
            case .running(let phase, let mbps):
                if phase == .latency {
                    return "Измеряю \(phase.title.lowercased())…"
                }
                return "Измеряю \(phase.title.lowercased()): \(mbps.speedString) Мбит/с"
            }
        }
    }

    // MARK: Настройки (UserDefaults, можно менять из интерфейса и извне)

    public static let intervalKey = "measurementIntervalMinutes"
    public static let quietThresholdKey = "quietActivityThresholdMbps"
    public static let cancelThresholdKey = "cancelActivityThresholdMbps"
    public static let quietWindowMinutesKey = "quietWindowMinutes"
    public static let lastRunKey = "lastRunDate"
    public static let pausedKey = "measurementsPaused"

    public var intervalMinutes: Int {
        get { UserDefaults.standard.object(forKey: Self.intervalKey) as? Int ?? 60 }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.intervalKey)
            rescheduleAfterIntervalChange()
        }
    }

    /// «Околонулевая» активность — всё, что ниже этого порога, Мбит/с.
    public var quietThresholdMbps: Double {
        get { UserDefaults.standard.object(forKey: Self.quietThresholdKey) as? Double ?? 1.5 }
        set { UserDefaults.standard.set(newValue, forKey: Self.quietThresholdKey) }
    }

    /// «Чужая» активность во время измерения выше этого порога — измерение останавливается.
    public var cancelThresholdMbps: Double {
        get { UserDefaults.standard.object(forKey: Self.cancelThresholdKey) as? Double ?? 6.0 }
        set { UserDefaults.standard.set(newValue, forKey: Self.cancelThresholdKey) }
    }

    /// Окно тишины перед запуском по расписанию.
    public var quietWindowMinutes: Double {
        get { UserDefaults.standard.object(forKey: Self.quietWindowMinutesKey) as? Double ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: Self.quietWindowMinutesKey) }
    }

    // MARK: Состояние

    @Published public private(set) var state: State = .idle(nextRun: Date())
    @Published public private(set) var history: [SpeedtestResult] = []
    @Published public private(set) var lastNote: String?

    /// Ручная пауза: расписание не срабатывает (например, Mac подключён к телефону,
    /// раздающему интернет, и его трафик не надо расходовать). Кнопка «Измерить сейчас»
    /// продолжает работать по явному решению пользователя.
    @Published public var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: Self.pausedKey) }
    }

    private let engine = SpeedtestEngine()
    private let sampler = ActivitySampler()
    private let pathMonitor = NWPathMonitor()
    private var online = true
    private var loopTask: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?
    private var isRunning = false
    private var nextRun: Date
    private var started = false

    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }
    private var cancelBox = CancelBox()
    private var cancelReason = ""

    public init() {
        isPaused = UserDefaults.standard.bool(forKey: Self.pausedKey)
        let interval = UserDefaults.standard.object(forKey: Self.intervalKey) as? Int ?? 60
        let lastRun = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date
        if let lastRun {
            let due = lastRun.addingTimeInterval(TimeInterval(interval) * 60)
            nextRun = due <= Date() ? Date().addingTimeInterval(15) : due
        } else {
            nextRun = Date().addingTimeInterval(20)
        }
        history = MeasurementStore.shared.results
    }

    public func startIfNeeded() {
        guard !started else { return }
        started = true
        sampler.start()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.online = path.status == .satisfied
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "path-monitor"))
        // при старте агента просим систему перерисовать виджет свежими данными
        WidgetCenter.shared.reloadAllTimelines()
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    // MARK: Управление из интерфейса

    public func measureNow() {
        guard !isRunning else { return }
        nextRun = Date()
    }

    /// Явная остановка текущего измерения.
    public func stopMeasurement(reason: String = "Измерение остановлено вручную") {
        guard isRunning else { return }
        cancelReason = reason
        cancelBox.cancel()
        measureTask?.cancel()
    }

    private func rescheduleAfterIntervalChange() {
        let lastRun = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date
        let due = lastRun.map { $0.addingTimeInterval(TimeInterval(intervalMinutes) * 60) } ?? Date()
        nextRun = due <= Date() ? Date().addingTimeInterval(15) : due
    }

    // MARK: Основной цикл

    private func loop() async {
        var lastLoggedState: State?
        while !Task.isCancelled {
            if !isRunning {
                if isPaused {
                    state = .paused
                } else if Date() >= nextRun {
                    if !online {
                        nextRun = Date().addingTimeInterval(60)
                        state = .offline(nextRun: nextRun)
                    } else {
                        let quiet = sampler.wasQuiet(minutes: quietWindowMinutes, thresholdMbps: quietThresholdMbps)
                        log("измерение запланировано; тишина за \(quietWindowMinutes) мин: \(quiet)")
                        if quiet {
                            await runMeasurementTask()
                            markCompleted()
                        } else {
                            state = .waitingQuiet(nextRun: nextRun)
                        }
                    }
                } else {
                    state = .idle(nextRun: nextRun)
                }
                if state != lastLoggedState {
                    log("состояние: \(state.label)")
                    lastLoggedState = state
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func log(_ message: String) {
        NSLog("[SpeedtestAgent] %@", message)
    }

    private func markCompleted() {
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.lastRunKey)
        nextRun = now.addingTimeInterval(TimeInterval(intervalMinutes) * 60)
    }

    private func runMeasurementTask() async {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runMeasurement()
        }
        measureTask = task
        await task.value
        measureTask = nil
    }

    private func runMeasurement() async {
        isRunning = true
        cancelBox = CancelBox()
        cancelReason = ""
        state = .running(phase: .latency, currentMbps: 0)
        lastNote = nil
        log("начинаю измерение (история: \(MeasurementStore.shared.results.count) записей, файл: \(MeasurementStore.shared.fileURL.path))")

        let ownRate = OwnRateBox()
        let watcher = Task { [weak self] in
            await self?.watchExternalActivity(ownRate: ownRate)
        }

        do {
            let result = try await engine.measure(
                progress: { phase, mbps in
                    ownRate.set(phase == .latency ? 0 : mbps)
                    Task { @MainActor [weak self] in
                        self?.state = .running(phase: phase, currentMbps: mbps)
                    }
                },
                shouldCancel: { [cancelBox] in cancelBox.isCancelled }
            )
            MeasurementStore.shared.append(result)
            history = MeasurementStore.shared.results
            state = .idle(nextRun: Date())
            log("измерение готово: ↓\(result.downloadMbps.speedString) ↑\(result.uploadMbps.speedString) Мбит/с, ping \(result.pingMs.speedString) мс")
            WidgetCenter.shared.reloadAllTimelines()
        } catch let error as SpeedtestError {
            if case .cancelled = error {
                lastNote = cancelReason.isEmpty ? error.errorDescription : cancelReason
            } else {
                lastNote = "Ошибка: \(error.errorDescription ?? "неизвестная")"
            }
            log("ошибка измерения: \(lastNote ?? "")")
        } catch is CancellationError {
            lastNote = cancelReason.isEmpty ? "Измерение остановлено" : cancelReason
            log("измерение отменено: \(lastNote ?? "")")
        } catch {
            lastNote = "Ошибка: \(error.localizedDescription)"
            log("ошибка измерения: \(error)")
        }
        watcher.cancel()
        isRunning = false
    }

    /// Следит за «чужим» трафиком во время измерения: общий трафик минус трафик теста.
    /// Два подряд идущих замера выше порога — останавливаем измерение.
    private func watchExternalActivity(ownRate: OwnRateBox) async {
        var previousExternal = false
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            let total = await NetworkActivityMonitor.throughputMbps(window: 2)
            let external = max(0, total - ownRate.get())
            if external > cancelThresholdMbps {
                if previousExternal {
                    stopMeasurement(
                        reason: "Остановлено: в сети началась активность (~\(Int(external.rounded())) Мбит/с)"
                    )
                    return
                }
                previousExternal = true
            } else {
                previousExternal = false
            }
        }
    }
}

/// Потокобезопасное хранилище текущей скорости самого теста (для вычитания из общего трафика).
final class OwnRateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    func set(_ newValue: Double) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Double {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
