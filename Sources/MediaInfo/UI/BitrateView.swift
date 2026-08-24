import Charts
import SwiftUI

/// Bitrate over time, measured from real packet sizes rather than the container header.
struct BitrateView: View {
    let report: MediaReport

    @State private var hoveredSample: BitrateSample?
    @State private var showsKeyframes = false

    private var samples: [BitrateSample] { report.bitrateSamples }
    private var stats: MediaReport.BitrateStats? { report.bitrateStats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let stats { statsStrip(stats) }
                chart
                legend
            }
            .padding(16)
        }
    }

    // MARK: Stats

    private func statsStrip(_ stats: MediaReport.BitrateStats) -> some View {
        FlowLayout(spacing: 10) {
            StatTile(title: "Media", value: Fmt.bitrateShort(stats.average), tint: .accentColor)
            StatTile(title: "Pico", value: Fmt.bitrateShort(stats.peak),
                     caption: "en \(Fmt.timecode(stats.peakTime))", tint: .orange)
            StatTile(title: "Mínimo", value: Fmt.bitrateShort(stats.minimum), tint: .teal)
            StatTile(title: "Variabilidad", value: "\(Fmt.decimal(stats.variability))×",
                     caption: stats.variability < 1.3 ? "casi CBR" : "VBR", tint: .purple)
            if let gop = stats.averageGOPSeconds {
                StatTile(title: "GOP medio", value: "\(Fmt.decimal(gop)) s",
                         caption: "\(Fmt.integer(stats.keyframeCount)) frames clave", tint: .pink)
            }
            StatTile(title: "Paquetes", value: Fmt.integer(stats.frameCount),
                     caption: "mayor: \(Fmt.bytesShort(stats.largestFrameBytes))", tint: .gray)
        }
    }

    // MARK: Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasa de bits \(report.bitrateStreamLabel)")
                    .font(.headline)
                Spacer()
                Toggle("Marcar frames clave", isOn: $showsKeyframes)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(keyframeMarks.isEmpty)
            }

            Chart {
                ForEach(samples, id: \.time) { sample in
                    AreaMark(
                        x: .value("Tiempo", sample.time),
                        y: .value("Tasa", sample.bitsPerSecond / 1_000_000)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.accentColor.opacity(0.45), .accentColor.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Tiempo", sample.time),
                        y: .value("Tasa", sample.bitsPerSecond / 1_000_000)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
                }

                if let stats {
                    RuleMark(y: .value("Media", stats.average / 1_000_000))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("media \(Fmt.bitrateShort(stats.average))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }

                if showsKeyframes {
                    ForEach(keyframeMarks, id: \.self) { time in
                        RuleMark(x: .value("Frame clave", time))
                            .foregroundStyle(.pink.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }

                if let hoveredSample {
                    RuleMark(x: .value("Tiempo", hoveredSample.time))
                        .foregroundStyle(.primary.opacity(0.35))
                    PointMark(
                        x: .value("Tiempo", hoveredSample.time),
                        y: .value("Tasa", hoveredSample.bitsPerSecond / 1_000_000)
                    )
                    .foregroundStyle(Color.accentColor)
                }
            }
            .chartXAxisLabel("Tiempo")
            .chartYAxisLabel("Mb/s")
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(Fmt.timecode(seconds).prefix(8))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoveredSample = sample(at: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                hoveredSample = nil
                            }
                        }
                }
            }
            .frame(height: 300)

            if let hoveredSample {
                HStack(spacing: 14) {
                    Label(Fmt.timecode(hoveredSample.time), systemImage: "clock")
                    Label(Fmt.bitrateShort(hoveredSample.bitsPerSecond), systemImage: "gauge.medium")
                    if hoveredSample.keyframes > 0 {
                        Label("\(hoveredSample.keyframes) frames clave", systemImage: "key")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("Pasa el cursor por la gráfica para ver los valores exactos.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var legend: some View {
        Text("Cada punto agrupa los paquetes de una ventana de tiempo fija. Los picos coinciden "
             + "con planos de mucho movimiento o cambios de escena; los valles, con planos estáticos.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Drawing one rule per keyframe would be unusable on a long film, so the marks are thinned.
    private var keyframeMarks: [Double] {
        let times = samples.filter { $0.keyframes > 0 }.map(\.time)
        guard times.count > 200 else { return times }
        let stride = times.count / 200
        return times.enumerated().compactMap { $0.offset.isMultiple(of: stride) ? $0.element : nil }
    }

    private func sample(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> BitrateSample? {
        let origin = geometry[proxy.plotFrame!].origin
        guard let time: Double = proxy.value(atX: location.x - origin.x) else { return nil }
        return samples.min { abs($0.time - time) < abs($1.time - time) }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 130, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
    }
}
