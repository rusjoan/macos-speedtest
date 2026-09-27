import WidgetKit
import SwiftUI

struct HistoryEntry: TimelineEntry {
    let date: Date
    let results: [SpeedtestResult]
}

struct HistoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> HistoryEntry {
        HistoryEntry(date: .now, results: SpeedtestResult.samples())
    }

    func getSnapshot(in context: Context, completion: @escaping (HistoryEntry) -> Void) {
        completion(HistoryEntry(date: .now, results: MeasurementStore.shared.results))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HistoryEntry>) -> Void) {
        // Свежие данные агент проталкивает через WidgetCenter.reloadAllTimers();
        // .after — просто подстраховка на случай, если агент давно не обновлял виджет.
        let entry = HistoryEntry(date: .now, results: MeasurementStore.shared.results)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct WidgetRootView: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Selectel Speedtest", systemImage: "gauge.with.needle")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let last = entry.results.last {
                    Text(last.date, style: .relative)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            if entry.results.isEmpty {
                Text("Пока нет измерений.\nЗапустите SelectelSpeedtest.app")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                SpeedGrid(history: entry.results, chartHeight: 34, showsEmptyHint: false)
            }
        }
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

struct SelectelSpeedtestWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SelectelSpeedtest", provider: HistoryProvider()) { entry in
            WidgetRootView(entry: entry)
        }
        .configurationDisplayName("Selectel Speedtest")
        .description("Последнее измерение и графики истории: скачивание, загрузка, пинг, джиттер.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SpeedtestWidgetBundle: WidgetBundle {
    var body: some Widget {
        SelectelSpeedtestWidget()
    }
}
