import AppKit
import Foundation

/// Runs every analyser and assembles the final report.
enum ReportBuilder {
    /// How many frames to decode for the detailed head-of-stream analysis.
    /// Enough to see a full GOP and any in-band HDR metadata without decoding the film.
    private static let frameSampleCount = 120

    /// Fast pass: everything except the packet scan. Runs in well under a second even on
    /// large files, so the window can show real data immediately.
    static func build(url: URL) async -> MediaReport {
        var report = MediaReport(url: url)

        // The file system never fails and needs no external process, so it goes first:
        // even an unreadable video still produces a useful report.
        let fileSections = FileProbe.analyze(url: url)

        var probe: (json: [String: JSONValue], raw: String)?
        do {
            probe = try FFProbe.inspect(url: url)
        } catch {
            report.warnings.append(error.localizedDescription)
        }

        let native = await NativeProbe.analyze(url: url)
        report.thumbnail = native.thumbnail
        report.warnings.append(contentsOf: native.warnings)

        // AVFoundation cannot open Matroska, WebM or transport streams; ffmpeg can.
        if report.thumbnail == nil, let probe, hasVideoStream(probe.json) {
            let duration = probe.json["format"]?.objectValue?[double: "duration"] ?? 0
            report.thumbnail = FFmpegThumbnail.image(
                for: url, at: duration > 1 ? min(duration * 0.1, 30) : 0)
        }

        var sections: [InfoSection] = []

        if let probe {
            report.rawProbeJSON = probe.raw
            let streams = probe.json["streams"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let format = probe.json["format"]?.objectValue ?? [:]

            report.summary = summarize(format: format, streams: streams, url: url)

            sections.append(overviewSection(report.summary, streams: streams))
            sections.append(containerSection(format))

            // Frame-level detail for the first video stream: pict_type mix, interlacing
            // and the HDR SEI messages that never appear in -show_streams.
            var frameSection: InfoSection?
            if let videoIndex = streams.first(where: { $0[string: "codec_type"] == "video" })?[int: "index"] {
                let frames = (try? FFProbe.frames(url: url, streamSpecifier: "\(videoIndex)", count: frameSampleCount)) ?? []
                frameSection = frameAnalysisSection(frames)
                if let hdr = hdrSection(streams: streams, frames: frames) {
                    sections.append(hdr)
                    report.summary.isHDR = true
                    report.summary.hdrFormat = hdr.subtitle
                }
            }

            if !streams.isEmpty {
                sections.append(InfoSection(
                    "Pistas",
                    subtitle: "\(streams.count) pistas en el contenedor",
                    symbol: "square.stack.3d.down.right",
                    subsections: streams.map(streamSection)
                ))
            }

            if let frameSection { sections.append(frameSection) }

            // Prefer the video stream; for music files the audio stream is the interesting one.
            let curveStream = streams.first { $0[string: "codec_type"] == "video" }
                ?? streams.first { $0[string: "codec_type"] == "audio" }
            if let curveStream, let curveIndex = curveStream[int: "index"] {
                report.pendingBitrate = MediaReport.PendingBitrate(
                    streamIndex: curveIndex,
                    label: curveStream[string: "codec_type"] == "audio" ? "del audio" : "del vídeo",
                    containerDuration: format[double: "duration"])
            }

            if let chapters = chaptersSection(probe.json) { sections.append(chapters) }
            if let programs = programsSection(probe.json) { sections.append(programs) }
            if let tags = tagsSection(format[.init("tags")]?.objectValue, title: "Metadatos del contenedor") {
                sections.append(tags)
            }
        }

        sections.append(contentsOf: native.sections)
        sections.append(contentsOf: fileSections)
        sections.append(engineSection())

        report.sections = sections.filter { !$0.isEmpty }
        return report
    }

    /// Slow pass: reads every packet of the chosen stream to build the bitrate curve.
    /// Returns the report unchanged if there is nothing to measure.
    static func attachBitrateCurve(to report: MediaReport) async -> MediaReport {
        guard let pending = report.pendingBitrate,
              let packets = try? FFProbe.packets(
                  url: report.url, streamSpecifier: "\(pending.streamIndex)"),
              let analysis = BitrateAnalyzer.analyze(
                  packets: packets, duration: pending.containerDuration)
        else {
            var cleared = report
            cleared.pendingBitrate = nil
            return cleared
        }

        var updated = report
        updated.bitrateSamples = analysis.samples
        updated.bitrateStats = analysis.stats
        updated.bitrateStreamLabel = pending.label
        updated.pendingBitrate = nil
        let section = bitrateSection(analysis, label: pending.label, streamIndex: pending.streamIndex)
        // Sits next to the other stream-level analysis rather than at the end of the report.
        let anchor = updated.sections.firstIndex { $0.title == "Análisis de frames" }
            ?? updated.sections.firstIndex { $0.title == "Pistas" }
        updated.sections.insert(section, at: anchor.map { $0 + 1 } ?? updated.sections.count)
        return updated
    }

    // MARK: - Summary

    private static func hasVideoStream(_ root: [String: JSONValue]) -> Bool {
        root["streams"]?.arrayValue?.contains {
            // Cover art is stored as a still "video" stream; it is not a frame to grab.
            guard let stream = $0.objectValue, stream[string: "codec_type"] == "video" else { return false }
            return stream["disposition"]?.objectValue?[int: "attached_pic"] != 1
        } ?? false
    }

    private static func summarize(format: [String: JSONValue],
                                  streams: [[String: JSONValue]],
                                  url: URL) -> MediaReport.Summary {
        var summary = MediaReport.Summary()
        summary.container = format[string: "format_long_name"] ?? format[string: "format_name"]
        summary.duration = format[double: "duration"]
        summary.fileSize = format[int: "size"]
        summary.overallBitrate = format[double: "bit_rate"]

        if let video = streams.first(where: { $0[string: "codec_type"] == "video" }) {
            summary.videoCodec = video[string: "codec_name"]?.uppercased()
            if let width = video[int: "width"], let height = video[int: "height"] {
                summary.resolution = "\(width) × \(height)"
            }
            summary.frameRate = Fmt.frameRateValue(video[string: "avg_frame_rate"])
                ?? Fmt.frameRateValue(video[string: "r_frame_rate"])
        }
        if let audio = streams.first(where: { $0[string: "codec_type"] == "audio" }) {
            summary.audioCodec = audio[string: "codec_name"]?.uppercased()
            summary.channels = audio[string: "channel_layout"]
                ?? audio[int: "channels"].map { "\($0) canales" }
        }
        return summary
    }

    private static func overviewSection(_ summary: MediaReport.Summary,
                                        streams: [[String: JSONValue]]) -> InfoSection {
        var rows: [InfoRow] = []
        rows.append(contentsOf: [
            InfoRow("Contenedor", optional: summary.container, highlighted: true),
            summary.duration.map { InfoRow("Duración", Fmt.duration($0), highlighted: true) },
            summary.fileSize.map { InfoRow("Tamaño", Fmt.bytes($0), highlighted: true) },
            summary.overallBitrate.map { InfoRow("Tasa de bits total", Fmt.bitrate($0), highlighted: true) },
            InfoRow("Vídeo", optional: summary.videoCodec, highlighted: true),
            InfoRow("Resolución", optional: summary.resolution, highlighted: true),
            summary.frameRate.map { fps in
                InfoRow("Frame rate", FieldCatalog.frameRateStandard(fps)
                        ?? "\(Fmt.decimal(fps, fractionDigits: 3)) fps", highlighted: true)
            },
            InfoRow("Audio", optional: summary.audioCodec, highlighted: true),
            InfoRow("Canales", optional: summary.channels, highlighted: true),
        ].compactMap { $0 })

        let counts = Dictionary(grouping: streams, by: { $0[string: "codec_type"] ?? "otro" })
            .map { "\($0.value.count) × \(friendlyStreamType($0.key))" }
            .sorted()
        if !counts.isEmpty {
            rows.append(InfoRow("Composición", counts.joined(separator: ", ")))
        }

        // Sanity check that catches remuxes with a wrong container duration.
        if let duration = summary.duration, let size = summary.fileSize, duration > 0 {
            let effective = Double(size) * 8 / duration
            rows.append(InfoRow("Tasa de bits real del fichero", Fmt.bitrate(effective),
                                note: "Tamaño total ÷ duración. Incluye la sobrecarga del contenedor."))
        }
        return InfoSection("Resumen", symbol: "info.circle", rows: rows)
    }

    // MARK: - Container

    private static func containerSection(_ format: [String: JSONValue]) -> InfoSection {
        InfoSection(
            "Contenedor",
            subtitle: format[string: "format_long_name"],
            symbol: "shippingbox",
            rows: rows(from: format)
        )
    }

    // MARK: - Streams

    private static func streamSection(_ stream: [String: JSONValue]) -> InfoSection {
        let type = stream[string: "codec_type"] ?? "data"
        let index = stream[int: "index"] ?? 0
        let codec = stream[string: "codec_name"] ?? "desconocido"

        var rows = self.rows(from: stream)
        rows.append(contentsOf: derivedStreamRows(stream, type: type))

        var subsections: [InfoSection] = []
        if let disposition = stream["disposition"]?.objectValue,
           let section = dispositionSection(disposition) {
            subsections.append(section)
        }
        if let tags = tagsSection(stream["tags"]?.objectValue, title: "Etiquetas de la pista") {
            subsections.append(tags)
        }
        if let sideData = sideDataSection(stream["side_data_list"]?.arrayValue) {
            subsections.append(sideData)
        }

        var title = "\(friendlyStreamType(type).capitalized) #\(index) · \(codec.uppercased())"
        if let language = stream["tags"]?.objectValue?[string: "language"], language != "und" {
            title += " · \(language)"
        }

        return InfoSection(title,
                           subtitle: stream[string: "codec_long_name"],
                           symbol: symbol(forStreamType: type),
                           rows: rows,
                           subsections: subsections)
    }

    /// Values ffprobe does not report but that follow from the ones it does.
    private static func derivedStreamRows(_ stream: [String: JSONValue], type: String) -> [InfoRow] {
        var rows: [InfoRow] = []

        if type == "video", let width = stream[int: "width"], let height = stream[int: "height"] {
            if let ratio = Fmt.aspectRatio(width: width, height: height) {
                rows.append(InfoRow("Relación de aspecto (calculada)", ratio,
                                    note: "Derivada de las dimensiones en píxeles, sin tener en cuenta el SAR."))
            }
            if let label = Fmt.resolutionClass(width: width, height: height) {
                rows.append(InfoRow("Categoría de resolución", label, highlighted: true))
            }
            rows.append(InfoRow("Megapíxeles", Fmt.megapixels(width: width, height: height)))

            let fps = Fmt.frameRateValue(stream[string: "avg_frame_rate"]) ?? 0
            if let standard = FieldCatalog.frameRateStandard(fps) {
                rows.append(InfoRow("Estándar de cadencia", standard))
            }
            if let bitrate = stream[double: "bit_rate"],
               let bpp = Fmt.bitsPerPixel(bitrate: bitrate, width: width, height: height, fps: fps) {
                rows.append(InfoRow("Bits por píxel", bpp,
                                    note: "Bits de vídeo por píxel y frame. Por debajo de ~0,05 suelen verse artefactos."))
            }
            if let uncompressed = uncompressedRate(stream, width: width, height: height, fps: fps),
               let bitrate = stream[double: "bit_rate"], bitrate > 0 {
                rows.append(InfoRow("Ratio de compresión", "≈ \(Fmt.decimal(uncompressed / bitrate, fractionDigits: 0)) : 1",
                                    note: "Frente al mismo vídeo sin comprimir."))
            }
        }

        if let pixelFormat = stream[string: "pix_fmt"],
           let explanation = FieldCatalog.explainPixelFormat(pixelFormat) {
            rows.append(InfoRow("Formato de píxel (interpretado)", explanation, rawKey: "pix_fmt"))
        }
        if let level = stream[int: "level"], level > 0 {
            rows.append(InfoRow("Nivel (interpretado)",
                                FieldCatalog.explainLevel(level, codec: stream[string: "codec_name"]),
                                rawKey: "level",
                                note: "Limita resolución, cadencia y tasa de bits máximas del perfil."))
        }
        if type == "video", let fieldOrder = stream[string: "field_order"], fieldOrder != "progressive" {
            rows.append(InfoRow("Entrelazado", "Sí — \(fieldOrder)", rawKey: "field_order",
                                note: "Requiere desentrelazado para verse correctamente en pantallas modernas.",
                                highlighted: true))
        }
        if type == "audio", let channels = stream[int: "channels"] {
            rows.append(InfoRow("Configuración", describeChannels(channels), rawKey: "channels"))
            if let rate = stream[double: "sample_rate"], let bits = stream[int: "bits_per_sample"], bits > 0 {
                let uncompressed = rate * Double(bits) * Double(channels)
                rows.append(InfoRow("Equivalente sin comprimir", Fmt.bitrate(uncompressed)))
            }
        }
        return rows
    }

    private static func uncompressedRate(_ stream: [String: JSONValue],
                                         width: Int, height: Int, fps: Double) -> Double? {
        guard fps > 0 else { return nil }
        let depth = Double(stream[int: "bits_per_raw_sample"] ?? 8)
        let pixelFormat = stream[string: "pix_fmt"] ?? "yuv420p"
        // Average bits per pixel across all three planes for the given chroma subsampling.
        let chromaFactor: Double
        switch true {
        case pixelFormat.contains("444"): chromaFactor = 3
        case pixelFormat.contains("422"): chromaFactor = 2
        case pixelFormat.contains("420"): chromaFactor = 1.5
        default: chromaFactor = 1.5
        }
        return Double(width) * Double(height) * fps * depth * chromaFactor
    }

    private static func describeChannels(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Estéreo"
        case 3: return "2.1"
        case 6: return "5.1 envolvente"
        case 8: return "7.1 envolvente"
        case 12: return "7.1.4 (con canales de altura)"
        case 16: return "Ambisónico de 3.er orden o 9.1.6"
        default: return "\(count) canales"
        }
    }

    // MARK: - Sub-sections

    private static func dispositionSection(_ disposition: [String: JSONValue]) -> InfoSection? {
        let active = disposition.filter { $0.value.intValue == 1 }
        guard !active.isEmpty else { return nil }
        let rows = active.keys.sorted().map { key in
            InfoRow(FieldCatalog.dispositionLabels[key] ?? FieldCatalog.prettify(key), "Sí", rawKey: key)
        }
        return InfoSection("Indicadores (disposition)",
                           subtitle: "\(rows.count) activos",
                           symbol: "flag",
                           rows: rows)
    }

    private static func tagsSection(_ tags: [String: JSONValue]?, title: String) -> InfoSection? {
        guard let tags, !tags.isEmpty else { return nil }
        let rows = tags.keys.sorted().compactMap { key -> InfoRow? in
            guard let value = tags[key]?.stringValue, !value.isEmpty else { return nil }
            return InfoRow(FieldCatalog.tagLabels[key] ?? FieldCatalog.prettify(key), value, rawKey: key)
        }
        return rows.isEmpty ? nil : InfoSection(title, subtitle: "\(rows.count) etiquetas",
                                                symbol: "tag", rows: rows)
    }

    private static func sideDataSection(_ sideData: [JSONValue]?) -> InfoSection? {
        guard let sideData, !sideData.isEmpty else { return nil }
        let subsections = sideData.compactMap { entry -> InfoSection? in
            guard let object = entry.objectValue else { return nil }
            let type = object[string: "side_data_type"] ?? "Datos adicionales"
            var fields = object
            fields.removeValue(forKey: "side_data_type")
            return InfoSection(type, symbol: "sidebar.squares.left", rows: rows(from: fields))
        }
        guard !subsections.isEmpty else { return nil }
        return InfoSection("Datos adicionales del flujo (side data)",
                           subtitle: "\(subsections.count) bloques",
                           symbol: "sidebar.squares.left",
                           subsections: subsections)
    }

    private static func chaptersSection(_ root: [String: JSONValue]) -> InfoSection? {
        guard let chapters = root["chapters"]?.arrayValue?.compactMap(\.objectValue), !chapters.isEmpty else {
            return nil
        }
        let rows = chapters.enumerated().map { index, chapter -> InfoRow in
            let title = chapter["tags"]?.objectValue?[string: "title"] ?? "Capítulo \(index + 1)"
            let start = chapter[double: "start_time"] ?? 0
            let end = chapter[double: "end_time"] ?? 0
            return InfoRow(title, "\(Fmt.timecode(start)) → \(Fmt.timecode(end))  ·  \(Fmt.decimal(end - start)) s",
                           rawKey: "chapter[\(index)]")
        }
        return InfoSection("Capítulos (contenedor)", subtitle: "\(rows.count) capítulos",
                           symbol: "list.number", rows: rows)
    }

    private static func programsSection(_ root: [String: JSONValue]) -> InfoSection? {
        var subsections: [InfoSection] = []
        if let programs = root["programs"]?.arrayValue?.compactMap(\.objectValue), !programs.isEmpty {
            for program in programs {
                var fields = program
                fields.removeValue(forKey: "streams")
                let identifier = program[int: "program_id"] ?? 0
                subsections.append(InfoSection("Programa \(identifier)", symbol: "tv", rows: rows(from: fields)))
            }
        }
        if let groups = root["stream_groups"]?.arrayValue?.compactMap(\.objectValue), !groups.isEmpty {
            for (index, group) in groups.enumerated() {
                var fields = group
                fields.removeValue(forKey: "streams")
                subsections.append(InfoSection("Grupo de pistas \(index)", symbol: "rectangle.3.group",
                                               rows: rows(from: fields)))
            }
        }
        guard !subsections.isEmpty else { return nil }
        return InfoSection("Programas y grupos", symbol: "tv", subsections: subsections)
    }

    // MARK: - Frame analysis

    private static func frameAnalysisSection(_ frames: [[String: JSONValue]]) -> InfoSection? {
        guard !frames.isEmpty else { return nil }
        var rows: [InfoRow] = []

        rows.append(InfoRow("Frames analizados", "\(frames.count)",
                            note: "Se decodifica sólo el principio del fichero; el análisis completo sería muy lento."))

        let pictureTypes = frames.compactMap { $0[string: "pict_type"] }
        if !pictureTypes.isEmpty {
            let counts = Dictionary(grouping: pictureTypes, by: { $0 }).mapValues(\.count)
            let summary = counts.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "   ")
            rows.append(InfoRow("Tipos de frame", summary, rawKey: "pict_type",
                                note: "I = intra (completo), P = predicho, B = bidireccional."))
            if let firstIntra = pictureTypes.firstIndex(of: "I") {
                rows.append(InfoRow("Primer frame intra", "posición \(firstIntra)", rawKey: "pict_type"))
            }
        }

        if let interlaced = frames.first?["interlaced_frame"]?.boolValue {
            rows.append(InfoRow("Frame entrelazado", interlaced ? "Sí" : "No", rawKey: "interlaced_frame"))
        }
        if let topFirst = frames.first?["top_field_first"]?.boolValue, topFirst {
            rows.append(InfoRow("Campo superior primero", "Sí", rawKey: "top_field_first"))
        }
        if let repeatPict = frames.first?[int: "repeat_pict"], repeatPict != 0 {
            rows.append(InfoRow("Repetición de campos (pulldown)", "\(repeatPict)", rawKey: "repeat_pict",
                                note: "Indica telecine 3:2 u otro pulldown aplicado en el contenedor."))
        }
        if let lossless = frames.first?["lossless"]?.boolValue, lossless {
            rows.append(InfoRow("Codificación sin pérdidas", "Sí", rawKey: "lossless", highlighted: true))
        }

        let crops = ["crop_top", "crop_bottom", "crop_left", "crop_right"]
            .compactMap { key -> String? in
                guard let value = frames.first?[int: key], value != 0 else { return nil }
                return "\(key.replacingOccurrences(of: "crop_", with: "")): \(value) px"
            }
        if !crops.isEmpty {
            rows.append(InfoRow("Recorte del contenedor", crops.joined(separator: ", "),
                                note: "Píxeles codificados que el decodificador debe descartar."))
        }

        if let sizes = optionalSizes(frames) {
            rows.append(InfoRow("Tamaño de frame (muestra)",
                                "mín \(Fmt.bytesShort(sizes.min)) · medio \(Fmt.bytesShort(sizes.average)) · máx \(Fmt.bytesShort(sizes.max))",
                                rawKey: "pkt_size"))
        }

        return InfoSection("Análisis de frames", subtitle: "Primeros \(frames.count) frames",
                           symbol: "film.stack", rows: rows)
    }

    private static func optionalSizes(_ frames: [[String: JSONValue]]) -> (min: Int, max: Int, average: Int)? {
        let sizes = frames.compactMap { $0[int: "pkt_size"] }
        guard !sizes.isEmpty else { return nil }
        return (sizes.min()!, sizes.max()!, sizes.reduce(0, +) / sizes.count)
    }

    // MARK: - HDR

    /// HDR identification pulls from three places: the stream colour tags, the stream
    /// side data (Dolby Vision configuration) and the first frames' SEI messages.
    private static func hdrSection(streams: [[String: JSONValue]],
                                   frames: [[String: JSONValue]]) -> InfoSection? {
        guard let video = streams.first(where: { $0[string: "codec_type"] == "video" }) else { return nil }

        let transfer = video[string: "color_transfer"]
        let primaries = video[string: "color_primaries"]
        var formats: [String] = []
        var rows: [InfoRow] = []

        switch transfer {
        case "smpte2084":
            formats.append("HDR10 (PQ)")
            rows.append(InfoRow("Curva", "SMPTE ST 2084 (Perceptual Quantizer)", rawKey: "color_transfer",
                                highlighted: true))
        case "arib-std-b67":
            formats.append("HLG")
            rows.append(InfoRow("Curva", "ARIB STD-B67 (Hybrid Log-Gamma)", rawKey: "color_transfer",
                                highlighted: true))
        default:
            break
        }
        if primaries == "bt2020" {
            rows.append(InfoRow("Gamut", "BT.2020 — gamut amplio", rawKey: "color_primaries"))
        }
        let depth = video[int: "bits_per_raw_sample"]
            ?? video[string: "pix_fmt"].flatMap(bitDepth(fromPixelFormat:))
        if let depth, depth >= 10 {
            rows.append(InfoRow("Profundidad", "\(depth) bits por componente",
                                rawKey: "bits_per_raw_sample",
                                note: "HDR necesita 10 bits o más para evitar bandas en los degradados."))
        }

        // Side data from both the stream and the sampled frames. HDR SEI messages repeat
        // on every keyframe, so only the first block of each type is kept.
        let allSideData = (video["side_data_list"]?.arrayValue ?? [])
            + frames.flatMap { $0["side_data_list"]?.arrayValue ?? [] }

        var seenTypes: Set<String> = []
        for entry in allSideData {
            guard let object = entry.objectValue,
                  let type = object[string: "side_data_type"],
                  seenTypes.insert(type).inserted else { continue }
            switch type {
            case "Mastering display metadata":
                formats.append("metadatos de masterizado")
                rows.append(contentsOf: masteringRows(object))
            case "Content light level metadata":
                if let maxContent = object[int: "max_content"] {
                    rows.append(InfoRow("MaxCLL", "\(Fmt.integer(maxContent)) nits", rawKey: "max_content",
                                        note: "Brillo máximo de un solo píxel en todo el contenido."))
                }
                if let maxAverage = object[int: "max_average"] {
                    rows.append(InfoRow("MaxFALL", "\(Fmt.integer(maxAverage)) nits", rawKey: "max_average",
                                        note: "Media máxima de brillo de un frame completo."))
                }
            case "DOVI configuration record":
                formats.append("Dolby Vision")
                rows.append(contentsOf: ReportBuilder.rows(from: object.filter { $0.key != "side_data_type" }))
            case "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)":
                formats.append("HDR10+")
                rows.append(InfoRow("Metadatos dinámicos", "SMPTE ST 2094-40 (HDR10+)", highlighted: true))
            default:
                continue
            }
        }

        guard !formats.isEmpty else { return nil }
        return InfoSection("HDR", subtitle: formats.joined(separator: " + "),
                           symbol: "sun.max", rows: rows)
    }

    private static func masteringRows(_ object: [String: JSONValue]) -> [InfoRow] {
        var rows: [InfoRow] = []
        func chromaticity(_ name: String, _ xKey: String, _ yKey: String) {
            guard let x = rational(object[string: xKey]), let y = rational(object[string: yKey]) else { return }
            rows.append(InfoRow(name, "x \(Fmt.decimal(x, fractionDigits: 4)), y \(Fmt.decimal(y, fractionDigits: 4))",
                                rawKey: xKey))
        }
        chromaticity("Primario rojo", "red_x", "red_y")
        chromaticity("Primario verde", "green_x", "green_y")
        chromaticity("Primario azul", "blue_x", "blue_y")
        chromaticity("Punto blanco", "white_point_x", "white_point_y")

        if let maximum = rational(object[string: "max_luminance"]) {
            rows.append(InfoRow("Luminancia máxima del monitor de masterizado",
                                "\(Fmt.decimal(maximum, fractionDigits: 0)) nits", rawKey: "max_luminance",
                                highlighted: true))
        }
        if let minimum = rational(object[string: "min_luminance"]) {
            rows.append(InfoRow("Luminancia mínima del monitor de masterizado",
                                "\(Fmt.decimal(minimum, fractionDigits: 4)) nits", rawKey: "min_luminance"))
        }
        return rows
    }

    /// `yuv420p10le` -> 10. Falls back to 8 for formats with no explicit depth.
    private static func bitDepth(fromPixelFormat value: String) -> Int? {
        if let range = value.range(of: "\\d{1,2}(?=le|be)", options: .regularExpression) {
            return Int(value[range])
        }
        return value.contains("le") || value.contains("be") ? nil : 8
    }

    private static func rational(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] != 0 { return parts[0] / parts[1] }
        return Double(text)
    }

    // MARK: - Bitrate

    private static func bitrateSection(_ analysis: BitrateAnalyzer.Result,
                                      label: String, streamIndex: Int) -> InfoSection {
        let stats = analysis.stats
        var rows: [InfoRow] = [
            InfoRow("Tasa media \(label)", Fmt.bitrate(stats.average),
                    note: "Calculada sumando el tamaño real de todos los paquetes.", highlighted: true),
            InfoRow("Pico", "\(Fmt.bitrate(stats.peak))  en \(Fmt.timecode(stats.peakTime))", highlighted: true),
            InfoRow("Mínimo", Fmt.bitrate(stats.minimum)),
            InfoRow("Variabilidad (pico ÷ media)", "\(Fmt.decimal(stats.variability))×",
                    note: "Cerca de 1 indica tasa constante (CBR). Valores altos indican VBR agresivo."),
            InfoRow("Ventana de medición", "\(Fmt.decimal(analysis.windowSeconds)) s"),
            InfoRow("Paquetes analizados", Fmt.integer(stats.frameCount)),
            InfoRow("Frames clave", Fmt.integer(stats.keyframeCount)),
            InfoRow("Paquete mayor", Fmt.bytes(stats.largestFrameBytes)),
            InfoRow("Paquete menor", Fmt.bytes(stats.smallestFrameBytes)),
        ]
        if let gop = stats.averageGOPSeconds {
            rows.insert(InfoRow("Intervalo medio entre frames clave (GOP)",
                                "\(Fmt.decimal(gop)) s",
                                note: "Determina la granularidad del avance rápido y del troceado para streaming."),
                        at: 6)
        }
        return InfoSection("Tasa de bits en el tiempo",
                           subtitle: "Medida paquete a paquete sobre la pista #\(streamIndex)",
                           symbol: "chart.xyaxis.line",
                           rows: rows)
    }

    // MARK: - Engine

    private static func engineSection() -> InfoSection {
        var rows: [InfoRow] = []
        if let executable = FFProbe.executableURL {
            rows.append(InfoRow("Ruta de ffprobe", executable.path,
                                note: FFProbe.isBundled
                                    ? "Copia incluida dentro de la app."
                                    : "ffprobe del sistema (no se encontró la copia incluida)."))
        }
        if let versions = FFProbe.versions(),
           let program = versions["program_version"]?.objectValue {
            if let row = InfoRow("Versión de FFmpeg", optional: program[string: "version"], highlighted: true) {
                rows.append(row)
            }
            if let row = InfoRow("Compilador", optional: program[string: "compiler_ident"]) {
                rows.append(row)
            }
            if let configuration = program[string: "configuration"] {
                rows.append(InfoRow("Configuración de compilación", configuration,
                                    note: "Opciones con las que se compiló FFmpeg; determinan qué códecs reconoce."))
            }
        }
        rows.append(InfoRow("Análisis nativo", "AVFoundation · CoreMedia · Spotlight",
                            note: "Complementa a ffprobe con lo que sólo exponen los frameworks de Apple."))
        return InfoSection("Motor de análisis", symbol: "gearshape.2", rows: rows)
    }

    // MARK: - Generic key/value rendering

    /// Renders an ffprobe object as ordered, labelled rows without losing unknown keys.
    private static func rows(from object: [String: JSONValue]) -> [InfoRow] {
        let keys = object.keys.filter { !FieldCatalog.handledSeparately.contains($0) }
        let ordered = FieldCatalog.order.filter(keys.contains)
        let remainder = keys.filter { !FieldCatalog.order.contains($0) }.sorted()

        return (ordered + remainder).compactMap { key -> InfoRow? in
            guard let value = object[key] else { return nil }
            let field = FieldCatalog.field(for: key)
            // A field with its own formatter that returns nil is one the formatter judged
            // meaningless for this stream — an audio track's "0/0" frame rate, say.
            let text: String
            if let format = field.format {
                guard let formatted = format(value) else { return nil }
                text = formatted
            } else {
                text = value.displayString
            }
            guard !text.isEmpty, text != "—", text != "N/A", text != "unknown" else { return nil }
            return InfoRow(field.label, text, rawKey: key, note: field.note, highlighted: field.highlighted)
        }
    }

    private static func friendlyStreamType(_ type: String) -> String {
        switch type {
        case "video": return "vídeo"
        case "audio": return "audio"
        case "subtitle": return "subtítulos"
        case "data": return "datos"
        case "attachment": return "adjunto"
        default: return type
        }
    }

    private static func symbol(forStreamType type: String) -> String {
        switch type {
        case "video": return "video"
        case "audio": return "waveform"
        case "subtitle": return "captions.bubble"
        case "attachment": return "paperclip"
        default: return "square.stack"
        }
    }
}
