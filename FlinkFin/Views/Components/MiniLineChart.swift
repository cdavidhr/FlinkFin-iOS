import SwiftUI
import Charts

/// Sparkline minimalista (sin ejes ni etiquetas) — usado en las filas de
/// Posiciones y en la cabecera de Resumen. Equivalente visual a los
/// mini-gráficos Chart.js del dashboard web.
struct MiniLineChart: View {
    let values: [Double]
    var color: Color = .accentColor

    var body: some View {
        if values.count < 2 {
            Rectangle().fill(.clear).frame(height: 32)
        } else {
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("idx", index), y: .value("valor", value))
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
