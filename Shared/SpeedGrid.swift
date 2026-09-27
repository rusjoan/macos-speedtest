import SwiftUI

extension Color {
    public static let speedDownload = Color(red: 0.937, green: 0.408, blue: 0.425) // #EF686C
    public static let speedUpload = Color(red: 0.937, green: 0.596, blue: 0.400)   // #EF9866
    public static let speedPing = Color(red: 0.133, green: 0.757, blue: 0.478)     // #22C17A
    public static let speedJitter = Color(red: 0.737, green: 0.616, blue: 1.000)   // #BC9DFF
}

/// Мини-график (спарклайн) одного ряда измерений.
public struct MiniChart: View {
    public let values: [Double]
    public let color: Color

    public init(values: [Double], color: Color) {
        self.values = values
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            let points = values.filter { $0.isFinite }
            guard points.count >= 2, size.width > 4, size.height > 4 else { return }
            let maxV = max(points.max() ?? 1, 0.0001)
            let minV = min(points.min() ?? 0, 0)
            let range = max(maxV - minV, maxV * 0.15, 0.0001)

            var path = Path()
            let n = points.count
            for (index, value) in points.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(n - 1)
                let fraction = CGFloat((value - minV) / range)
                let y = size.height - fraction * (size.height - 2) - 1
                let point = CGPoint(x: x, y: min(max(y, 0), size.height))
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }

            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.35), color.opacity(0.03)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }
}

/// Сетка 2×2: скачивание, загрузка / пинг, джиттер.
/// Используется и в виджете, и в окне агента в меню-баре.
public struct SpeedGrid: View {
    public let history: [SpeedtestResult]
    public var chartHeight: CGFloat
    public var showsEmptyHint: Bool

    public init(history: [SpeedtestResult], chartHeight: CGFloat = 26, showsEmptyHint: Bool = true) {
        self.history = history
        self.chartHeight = chartHeight
        self.showsEmptyHint = showsEmptyHint
    }

    public var body: some View {
        if let last = history.last {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    cell("Скачивание", color: .speedDownload,
                         values: history.map(\.downloadMbps), value: last.downloadMbps, unit: "Мбит/с")
                    cell("Загрузка", color: .speedUpload,
                         values: history.map(\.uploadMbps), value: last.uploadMbps, unit: "Мбит/с")
                }
                HStack(spacing: 8) {
                    cell("Пинг", color: .speedPing,
                         values: history.map(\.pingMs), value: last.pingMs, unit: "мс")
                    cell("Джиттер", color: .speedJitter,
                         values: history.map(\.jitterMs), value: last.jitterMs, unit: "мс")
                }
            }
        } else if showsEmptyHint {
            Text("Пока нет измерений")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private func cell(_ title: String, color: Color, values: [Double], value: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(value.speedString) \(unit)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            MiniChart(values: Array(values.suffix(20)), color: color)
                .frame(height: chartHeight)
        }
    }
}
