import SwiftUI
import Charts

/// Minimalist sparkline (no axes or labels) — used in Holdings rows and Overview header.
/// Visual equivalent of the Chart.js mini-charts in the web dashboard.
struct MiniLineChart: View {
    let values: [Double]
    var color: Color = .accentColor

    var body: some View {
        if values.count < 2 {
            Rectangle().fill(.clear).frame(height: 32)
        } else {
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("idx", index), y: .value("value", value))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
            }
            .foregroundStyle(color)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 32)
        }
    }
}

#Preview {
    MiniLineChart(values: [10, 10.5, 9.8, 11, 11.5, 11.2, 12])
        .padding()
}
