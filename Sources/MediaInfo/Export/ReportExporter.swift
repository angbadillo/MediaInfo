import Foundation

/// Serialises a report to the formats offered in the export menu.
enum ReportExporter {
    enum Format: String, CaseIterable, Identifiable {
        case text = "Texto"
        case markdown = "Markdown"
        case json = "JSON"
        case rawJSON = "JSON de ffprobe"
        case csv = "CSV"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .text: return "txt"
            case .markdown: return "md"
            case .json, .rawJSON: return "json"
            case .csv: return "csv"
            }
        }
    }

    static func export(_ report: MediaReport, as format: Format) -> String {
        switch format {
        case .text: return plainText(report)
        case .markdown: return markdown(report)
        case .json: return json(report)
        case .rawJSON: return report.rawProbeJSON
        case .csv: return csv(report)
        }
    }

    static func suggestedFilename(for report: MediaReport, format: Format) -> String {
        let base = report.url.deletingPathExtension().lastPathComponent
        return "\(base) — análisis.\(format.fileExtension)"
    }

    // MARK: - Plain text

    private static func plainText(_ report: MediaReport) -> String {
        var lines: [String] = []
        lines.append(report.url.lastPathComponent)
        lines.append(String(repeating: "=", count: report.url.lastPathComponent.count))
        lines.append("")

        for warning in report.warnings {
            lines.append("⚠︎ \(warning)")
        }
        if !report.warnings.isEmpty { lines.append("") }

        func render(_ section: InfoSection, depth: Int) {
            let indent = String(repeating: "    ", count: depth)
            lines.append("\(indent)\(section.title.uppercased())")
            if let subtitle = section.subtitle {
                lines.append("\(indent)\(subtitle)")
            }
            lines.append("\(indent)\(String(repeating: "-", count: max(section.title.count, 8)))")

            let width = section.rows.map(\.label.count).max() ?? 0
            for row in section.rows {
                let label = row.label.padding(toLength: max(width, row.label.count), withPad: " ", startingAt: 0)
                // Multi-line values (UTI, xattr plists) get their continuation lines aligned.
                let value = row.value.replacingOccurrences(
                    of: "\n", with: "\n\(indent)  \(String(repeating: " ", count: width + 2))")
                lines.append("\(indent)  \(label)  \(value)")
            }
            lines.append("")
            for subsection in section.subsections {
                render(subsection, depth: depth + 1)
            }
        }

        for section in report.sections { render(section, depth: 0) }
        lines.append("Generado por MediaInfo · \(Fmt.date(Date()))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown

    private static func markdown(_ report: MediaReport) -> String {
        var lines: [String] = ["# \(report.url.lastPathComponent)", ""]
        lines.append("`\(report.url.path)`")
        lines.append("")

        for warning in report.warnings {
            lines.append("> ⚠️ \(warning)")
            lines.append("")
        }

        func render(_ section: InfoSection, depth: Int) {
            let level = String(repeating: "#", count: min(depth + 2, 6))
            lines.append("\(level) \(section.title)")
            if let subtitle = section.subtitle {
                lines.append("")
                lines.append("*\(subtitle)*")
            }
            if !section.rows.isEmpty {
                lines.append("")
                lines.append("| Campo | Valor |")
                lines.append("| --- | --- |")
                for row in section.rows {
                    let value = row.value
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: "<br>")
                    lines.append("| \(row.label) | \(value) |")
                }
            }
            lines.append("")
            for subsection in section.subsections {
                render(subsection, depth: depth + 1)
            }
        }

        for section in report.sections { render(section, depth: 0) }
        lines.append("---")
        lines.append("Generado por MediaInfo · \(Fmt.date(Date()))")
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON

    /// The app's own structured view: labelled sections plus the bitrate curve.
    private static func json(_ report: MediaReport) -> String {
        struct Payload: Encodable {
            let file: String
            let path: String
            let generatedAt: String
            let warnings: [String]
            let sections: [InfoSection]
            let bitrate: [BitrateSample]
            let bitrateStats: MediaReport.BitrateStats?
        }

        let payload = Payload(
            file: report.url.lastPathComponent,
            path: report.url.path,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            warnings: report.warnings,
            sections: report.sections,
            bitrate: report.bitrateSamples,
            bitrateStats: report.bitrateStats
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: - CSV

    /// Flat `section,field,value,key` rows — the form that pastes cleanly into a sheet
    /// when comparing several files.
    private static func csv(_ report: MediaReport) -> String {
        var lines = ["seccion,campo,valor,clave_original"]

        func escape(_ text: String) -> String {
            let cleaned = text.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(cleaned)\""
        }

        func render(_ section: InfoSection, path: String) {
            let fullPath = path.isEmpty ? section.title : "\(path) / \(section.title)"
            for row in section.rows {
                lines.append([
                    escape(fullPath),
                    escape(row.label),
                    escape(row.value.replacingOccurrences(of: "\n", with: " ")),
                    escape(row.rawKey ?? ""),
                ].joined(separator: ","))
            }
            for subsection in section.subsections { render(subsection, path: fullPath) }
        }

        for section in report.sections { render(section, path: "") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Batch comparison

    /// Side-by-side summary of several files, for the batch view's "compare" action.
    static func comparison(_ reports: [MediaReport]) -> String {
        var lines = ["fichero,contenedor,duracion_s,tamano_bytes,tasa_total_bps,codec_video,resolucion,fps,codec_audio,canales,hdr"]
        for report in reports {
            let summary = report.summary
            let fields = [
                report.url.lastPathComponent,
                summary.container ?? "",
                summary.duration.map { String(format: "%.3f", $0) } ?? "",
                summary.fileSize.map(String.init) ?? "",
                summary.overallBitrate.map { String(Int($0)) } ?? "",
                summary.videoCodec ?? "",
                summary.resolution ?? "",
                summary.frameRate.map { String(format: "%.3f", $0) } ?? "",
                summary.audioCodec ?? "",
                summary.channels ?? "",
                summary.isHDR ? (summary.hdrFormat ?? "sí") : "no",
            ]
            lines.append(fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
