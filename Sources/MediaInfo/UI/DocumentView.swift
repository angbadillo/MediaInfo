import SwiftUI

struct DocumentView: View {
    @ObservedObject var document: Document
    @EnvironmentObject private var state: AppState

    private enum Tab: String, CaseIterable, Identifiable {
        case report = "Informe"
        case bitrate = "Tasa de bits"
        case raw = "JSON de ffprobe"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .report
    @State private var query = ""

    var body: some View {
        switch document.state {
        case .queued, .analyzing:
            AnalyzingView(url: document.url)
        case .failed(let message):
            FailureView(url: document.url, message: message) {
                state.analyze(document)
            }
        case .ready(let report):
            content(for: report)
        }
    }

    @ViewBuilder
    private func content(for report: MediaReport) -> some View {
        VStack(spacing: 0) {
            ReportHeader(report: report)
            Divider()

            Picker("", selection: $tab) {
                ForEach(availableTabs(for: report)) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .report:
                ReportBody(report: report, query: $query)
            case .bitrate:
                if report.bitrateSamples.isEmpty {
                    MeasuringBitrateView()
                } else {
                    BitrateView(report: report)
                }
            case .raw:
                RawJSONView(text: report.rawProbeJSON)
            }
        }
        .onChange(of: document.id) {
            tab = .report
            query = ""
        }
    }

    private func availableTabs(for report: MediaReport) -> [Tab] {
        var tabs: [Tab] = [.report]
        // Keep the tab present while the second pass runs so it does not pop in and
        // shift the segmented control under the pointer.
        if !report.bitrateSamples.isEmpty || document.isMeasuringBitrate { tabs.append(.bitrate) }
        if !report.rawProbeJSON.isEmpty { tabs.append(.raw) }
        return tabs
    }
}

// MARK: - Header

private struct ReportHeader: View {
    let report: MediaReport

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            thumbnail

            VStack(alignment: .leading, spacing: 8) {
                Text(report.url.lastPathComponent)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(2)

                Text(report.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                FlowLayout(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Chip(text: chip)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            if !report.warnings.isEmpty {
                WarningBar(warnings: report.warnings)
            }
        }
        .padding(.bottom, report.warnings.isEmpty ? 0 : 34)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = report.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 150, height: 90)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary)
                }
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 150, height: 90)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var chips: [String] {
        let summary = report.summary
        var result: [String] = []
        if let duration = summary.duration { result.append(Fmt.timecode(duration)) }
        if let size = summary.fileSize { result.append(Fmt.bytesShort(size)) }
        if let codec = summary.videoCodec { result.append(codec) }
        if let resolution = summary.resolution { result.append(resolution) }
        if let fps = summary.frameRate { result.append("\(Fmt.decimal(fps, fractionDigits: 3)) fps") }
        if let bitrate = summary.overallBitrate { result.append(Fmt.bitrateShort(bitrate)) }
        if let audio = summary.audioCodec { result.append(audio) }
        if let channels = summary.channels { result.append(channels) }
        if summary.isHDR { result.append(summary.hdrFormat ?? "HDR") }
        return result
    }
}

private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .textSelection(.enabled)
    }
}

private struct WarningBar: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.10))
        .offset(y: 34)
    }
}

// MARK: - Report body

private struct ReportBody: View {
    let report: MediaReport
    @Binding var query: String

    private var sections: [InfoSection] {
        report.sections.compactMap { $0.filtered(by: query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(query: $query, resultCount: matchCount)
            Divider()

            if sections.isEmpty {
                ContentUnavailableView(
                    "Sin coincidencias",
                    systemImage: "magnifyingglass",
                    description: Text("Ningún campo contiene «\(query)»."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            SectionCard(section: section, startsExpanded: startsExpanded(section))
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    /// With a search active everything opens, otherwise only the sections you
    /// almost always want to see first.
    private func startsExpanded(_ section: InfoSection) -> Bool {
        if !query.isEmpty { return true }
        return ["Resumen", "Pistas", "HDR"].contains(section.title)
    }

    private var matchCount: Int {
        func count(_ section: InfoSection) -> Int {
            section.rows.count + section.subsections.reduce(0) { $0 + count($1) }
        }
        return sections.reduce(0) { $0 + count($1) }
    }
}

private struct SearchBar: View {
    @Binding var query: String
    let resultCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Buscar un campo o un valor…", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Text("\(resultCount) campos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - States

private struct AnalyzingView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Analizando \(url.lastPathComponent)…")
                .font(.headline)
            Text("Se está recorriendo el fichero para medir la tasa de bits real.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    let url: URL
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.orange)
            Text("No se pudo analizar \(url.lastPathComponent)")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)
            Button("Reintentar", action: retry)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown while the packet scan is still running.
private struct MeasuringBitrateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Midiendo la tasa de bits…")
                .font(.headline)
            Text("Se está recorriendo el fichero paquete a paquete. En ficheros grandes tarda unos segundos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RawJSONView: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
