import AppKit
import Foundation

/// A single labelled fact about the file.
struct InfoRow: Identifiable, Hashable, Codable {
    let id: UUID
    /// Human label shown in the UI.
    let label: String
    let value: String
    /// The original ffprobe / API key, kept so the value can be traced back to its source.
    let rawKey: String?
    /// Short explanation of what the field means, shown as a tooltip.
    let note: String?
    /// Rows that deserve visual emphasis (codec, resolution, bitrate…).
    let isHighlighted: Bool

    init(_ label: String, _ value: String, rawKey: String? = nil, note: String? = nil, highlighted: Bool = false) {
        self.id = UUID()
        self.label = label
        self.value = value
        self.rawKey = rawKey
        self.note = note
        self.isHighlighted = highlighted
    }

    /// Convenience for optional values: returns nil so callers can `compactMap`.
    init?(_ label: String, optional value: String?, rawKey: String? = nil, note: String? = nil, highlighted: Bool = false) {
        guard let value, !value.isEmpty, value != "unknown", value != "N/A" else { return nil }
        self.init(label, value, rawKey: rawKey, note: note, highlighted: highlighted)
    }

    var searchText: String {
        [label, value, rawKey ?? ""].joined(separator: " ").lowercased()
    }
}

/// A group of rows, optionally containing nested groups (a stream inside "Streams", say).
struct InfoSection: Identifiable, Hashable, Codable {
    let id: UUID
    let title: String
    let subtitle: String?
    let symbol: String
    var rows: [InfoRow]
    var subsections: [InfoSection]

    init(_ title: String, subtitle: String? = nil, symbol: String = "list.bullet",
         rows: [InfoRow] = [], subsections: [InfoSection] = []) {
        self.id = UUID()
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.rows = rows
        self.subsections = subsections
    }

    var isEmpty: Bool { rows.isEmpty && subsections.allSatisfy(\.isEmpty) }

    /// Returns a copy keeping only rows matching `query`, dropping sections left empty.
    func filtered(by query: String) -> InfoSection? {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return self }

        // A section whose own title matches keeps all of its contents.
        if title.lowercased().contains(needle) { return self }

        let keptRows = rows.filter { $0.searchText.contains(needle) }
        let keptSubsections = subsections.compactMap { $0.filtered(by: query) }
        guard !keptRows.isEmpty || !keptSubsections.isEmpty else { return nil }

        var copy = self
        copy.rows = keptRows
        copy.subsections = keptSubsections
        return copy
    }
}

/// One sample of the bitrate curve, aggregated over `windowSeconds`.
struct BitrateSample: Hashable, Codable {
    let time: Double
    let bitsPerSecond: Double
    let keyframes: Int
}

/// Everything the analysers found about one file.
struct MediaReport: Identifiable, Hashable {
    let id: UUID
    let url: URL

    var sections: [InfoSection] = []
    /// Compact facts for the sidebar and the header strip.
    var summary: Summary = Summary()
    var bitrateSamples: [BitrateSample] = []
    var bitrateStats: BitrateStats?
    /// Which stream the curve was measured on ("del vídeo", "del audio").
    var bitrateStreamLabel = "de la pista"
    /// Set during the fast pass so the slow packet scan knows what to measure and where
    /// to slot its section in.
    var pendingBitrate: PendingBitrate?
    /// First-frame preview rendered with AVFoundation.
    var thumbnail: NSImage?
    /// Raw ffprobe JSON, kept verbatim for the "Raw" tab and the JSON export.
    var rawProbeJSON: String = ""
    /// Non-fatal problems (missing ffprobe, unreadable track…) surfaced in the UI.
    var warnings: [String] = []

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }

    struct Summary: Hashable {
        var container: String?
        var duration: Double?
        var fileSize: Int?
        var videoCodec: String?
        var resolution: String?
        var frameRate: Double?
        var audioCodec: String?
        var channels: String?
        var overallBitrate: Double?
        var isHDR: Bool = false
        var hdrFormat: String?
    }

    /// The packet scan reads the whole file, so it runs as a second pass after the
    /// rest of the report is already on screen.
    struct PendingBitrate: Hashable {
        let streamIndex: Int
        let label: String
        let containerDuration: Double?
    }

    struct BitrateStats: Hashable, Codable {
        let average: Double
        let peak: Double
        let minimum: Double
        let peakTime: Double
        /// Peak / average — how variable the encode is.
        let variability: Double
        let keyframeCount: Int
        let averageGOPSeconds: Double?
        let frameCount: Int
        let largestFrameBytes: Int
        let smallestFrameBytes: Int
    }

    static func == (lhs: MediaReport, rhs: MediaReport) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
