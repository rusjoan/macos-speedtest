import SwiftUI
import ServiceManagement

@main
struct AgentApp: App {
    @ObservedObject private var scheduler = MeasurementScheduler.shared

    init() {
        // MenuBarExtra(.window) создаёт контент только по клику на иконку,
        // поэтому планировщик стартуем сразу при запуске приложения.
        MeasurementScheduler.shared.startIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(scheduler: scheduler)
        } label: {
            Text(menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: String {
        if case .running = scheduler.state {
            return "⟳"
        }
        if scheduler.isPaused {
            return "⏸"
        }
        if let last = scheduler.history.last {
            return "↓\(Int(last.downloadMbps.rounded()))"
        }
        return "⇅"
    }
}

struct MenuContentView: View {
    @ObservedObject var scheduler: MeasurementScheduler
    @State private var autostartOn = false

    private let intervals: [(Int, String)] = [
        (15, "15 минут"), (30, "30 минут"), (60, "1 час"),
        (180, "3 часа"), (360, "6 часов"), (720, "12 часов"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Selectel Speedtest")
                    .font(.headline)
                Spacer()
                if let last = scheduler.history.last {
                    Text(last.date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SpeedGrid(history: scheduler.history, chartHeight: 34)

            Text(scheduler.state.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let note = scheduler.lastNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if case .running = scheduler.state {
                    Button("Стоп", role: .destructive) {
                        scheduler.stopMeasurement()
                    }
                } else {
                    Button("Измерить сейчас") {
                        scheduler.measureNow()
                    }
                }
                Spacer()
                Picker("Интервал:", selection: Binding(
                    get: { scheduler.intervalMinutes },
                    set: { scheduler.intervalMinutes = $0 }
                )) {
                    ForEach(intervals, id: \.0) { value, title in
                        Text(title).tag(value)
                    }
                }
                .frame(width: 130)
            }

            Toggle("Пауза измерений", isOn: $scheduler.isPaused)
                .font(.caption)
                .help("Выключите, если Mac подключён к телефону в режиме модема или трафик нужно беречь")

            Divider()

            HStack {
                Toggle("Запускать при входе", isOn: $autostartOn)
                    .onChange(of: autostartOn) { _, newValue in
                        setAutostart(newValue)
                    }
                Spacer()
                Button("Выйти") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear {
            autostartOn = SMAppService.mainApp.status == .enabled
        }
    }

    private func setAutostart(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            autostartOn = SMAppService.mainApp.status == .enabled
        }
    }
}
