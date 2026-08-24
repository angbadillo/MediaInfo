import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One file in the batch list, with the state of its analysis.
@MainActor
final class Document: ObservableObject, Identifiable {
    enum State {
        case queued
        case analyzing
        case ready(MediaReport)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    @Published var state: State = .queued
    /// True while the second-pass packet scan is still running.
    @Published var isMeasuringBitrate = false

    init(url: URL) {
        self.url = url
    }

    var report: MediaReport? {
        if case .ready(let report) = state { return report }
        return nil
    }

    var isBusy: Bool {
        if case .analyzing = state { return true }
        return isMeasuringBitrate
    }

    /// One-line description for the sidebar.
    var subtitle: String {
        switch state {
        case .queued: return "En cola…"
        case .analyzing: return "Analizando…"
        case .failed(let message): return message
        case .ready(let report):
            var parts: [String] = []
            if let codec = report.summary.videoCodec { parts.append(codec) }
            if let resolution = report.summary.resolution { parts.append(resolution) }
            if let duration = report.summary.duration { parts.append(Fmt.timecode(duration)) }
            if let size = report.summary.fileSize { parts.append(Fmt.bytesShort(size)) }
            return parts.joined(separator: " · ")
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var documents: [Document] = []
    @Published var selection: Document.ID?
    /// Packet-level scanning is the slow part; it can be turned off for very large files.
    @AppStorage("analyzeBitrateCurve") var analyzeBitrateCurve = true

    /// File types the open panel and the drop target accept.
    static let acceptedTypes: [UTType] = [
        .movie, .video, .audiovisualContent, .audio, .mpeg4Movie, .quickTimeMovie, .mpeg2Video,
    ]

    var selectedDocument: Document? {
        documents.first { $0.id == selection }
    }

    var readyReports: [MediaReport] {
        documents.compactMap(\.report)
    }

    // MARK: - Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.acceptedTypes
        panel.message = "Selecciona uno o varios ficheros de vídeo o audio"
        panel.prompt = "Analizar"
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    func open(urls: [URL]) {
        var added: [Document] = []
        for url in urls {
            // Re-opening a file already in the list just re-selects it.
            if let existing = documents.first(where: { $0.url == url }) {
                selection = existing.id
                continue
            }
            let document = Document(url: url)
            documents.append(document)
            added.append(document)
        }
        if selection == nil { selection = added.first?.id ?? documents.first?.id }
        for document in added { analyze(document) }
    }

    func analyze(_ document: Document) {
        document.state = .analyzing
        document.isMeasuringBitrate = false
        let url = document.url
        let includeCurve = analyzeBitrateCurve

        Task.detached(priority: .userInitiated) {
            // Two passes: the fast one puts a complete report on screen straight away, the
            // slow packet scan then slots the bitrate curve in.
            let report = await ReportBuilder.build(url: url)
            await MainActor.run {
                // A report with no sections at all means nothing could be read.
                if report.sections.isEmpty, let failure = report.warnings.first {
                    document.state = .failed(failure)
                } else {
                    document.state = .ready(report)
                    document.isMeasuringBitrate = includeCurve && report.pendingBitrate != nil
                }
            }
            guard includeCurve, report.pendingBitrate != nil else { return }

            let refined = await ReportBuilder.attachBitrateCurve(to: report)
            await MainActor.run {
                // Ignore the result if the document was re-analysed meanwhile.
                guard case .ready(let current) = document.state, current.id == report.id else { return }
                document.state = .ready(refined)
                document.isMeasuringBitrate = false
            }
        }
    }

    func reanalyze() {
        guard let document = selectedDocument else { return }
        analyze(document)
    }

    // MARK: - Removing

    func remove(_ document: Document) {
        documents.removeAll { $0.id == document.id }
        if selection == document.id { selection = documents.first?.id }
    }

    func removeSelected() {
        guard let document = selectedDocument else { return }
        remove(document)
    }

    func removeAll() {
        documents.removeAll()
        selection = nil
    }

    // MARK: - Export

    func copyToPasteboard(format: ReportExporter.Format) {
        guard let report = selectedDocument?.report else { return }
        let text = ReportExporter.export(report, as: format)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func save(format: ReportExporter.Format) {
        guard let report = selectedDocument?.report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ReportExporter.suggestedFilename(for: report, format: format)
        panel.message = "Guardar el análisis de \(report.url.lastPathComponent)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ReportExporter.export(report, as: format)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// CSV with one row per analysed file — the point of the batch view.
    func saveComparison() {
        let reports = readyReports
        guard !reports.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Comparativa de \(reports.count) ficheros.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ReportExporter.comparison(reports).write(to: url, atomically: true, encoding: .utf8)
    }

    func copyComparison() {
        let reports = readyReports
        guard !reports.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReportExporter.comparison(reports), forType: .string)
    }

    func revealInFinder() {
        guard let url = selectedDocument?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
