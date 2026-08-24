import AVFoundation
import AppKit
import CoreMedia

/// Data that only Apple's own frameworks expose: the decoded format-description
/// extensions, Apple/iTunes metadata atoms, spatial-video flags and the preview frame.
/// This complements ffprobe rather than duplicating it.
enum NativeProbe {
    struct Result {
        var sections: [InfoSection] = []
        var thumbnail: NSImage?
        var warnings: [String] = []
    }

    static func analyze(url: URL) async -> Result {
        var result = Result()
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        guard let tracks = try? await asset.load(.tracks) else {
            result.warnings.append("AVFoundation no pudo abrir el fichero; solo se muestran los datos de ffprobe.")
            return result
        }

        if let assetSection = await assetSection(asset: asset, trackCount: tracks.count) {
            result.sections.append(assetSection)
        }
        if let metadataSection = await metadataSection(asset: asset) {
            result.sections.append(metadataSection)
        }
        if let chapters = await chapterSection(asset: asset) {
            result.sections.append(chapters)
        }

        var trackSections: [InfoSection] = []
        for track in tracks {
            if let section = await trackSection(track) { trackSections.append(section) }
        }
        if !trackSections.isEmpty {
            result.sections.append(InfoSection(
                "Pistas según AVFoundation",
                subtitle: "Vista de las pistas tal y como las interpreta macOS",
                symbol: "square.stack.3d.up",
                subsections: trackSections
            ))
        }

        result.thumbnail = await thumbnail(asset: asset)
        return result
    }

    // MARK: - Asset level

    private static func assetSection(asset: AVURLAsset, trackCount: Int) async -> InfoSection? {
        var rows: [InfoRow] = []

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            rows.append(InfoRow("Duración exacta", Fmt.duration(duration.seconds),
                                rawKey: "AVAsset.duration",
                                note: "Duración calculada leyendo la tabla de tiempos completa."))
            rows.append(InfoRow("Escala de tiempo", "\(duration.timescale) ticks/s",
                                rawKey: "CMTime.timescale",
                                note: "Resolución del reloj del contenedor. 600 y 90000 son los valores habituales."))
            rows.append(InfoRow("Duración en ticks", Fmt.integer(Int(duration.value)),
                                rawKey: "CMTime.value"))
        }
        if let rate = try? await asset.load(.preferredRate), rate != 1 {
            rows.append(InfoRow("Velocidad preferida", "\(Fmt.decimal(Double(rate)))×", rawKey: "AVAsset.preferredRate"))
        }
        if let volume = try? await asset.load(.preferredVolume), volume != 1 {
            rows.append(InfoRow("Volumen preferido", "\(Fmt.decimal(Double(volume)))", rawKey: "AVAsset.preferredVolume"))
        }
        if let transform = try? await asset.load(.preferredTransform) {
            rows.append(InfoRow("Matriz de transformación", describe(transform),
                                rawKey: "AVAsset.preferredTransform",
                                note: "Rotación/espejado que el reproductor debe aplicar al mostrar el vídeo."))
            if let rotation = rotationDegrees(from: transform) {
                rows.append(InfoRow("Rotación", "\(rotation)°", rawKey: "preferredTransform",
                                    highlighted: rotation != 0))
            }
        }

        let playable = (try? await asset.load(.isPlayable)) ?? false
        let readable = (try? await asset.load(.isReadable)) ?? false
        let exportable = (try? await asset.load(.isExportable)) ?? false
        let composable = (try? await asset.load(.isComposable)) ?? false
        rows.append(InfoRow("Reproducible en macOS", playable ? "Sí" : "No",
                            rawKey: "AVAsset.isPlayable",
                            note: "Si es «No», QuickTime y Final Cut no abrirán este fichero aunque ffprobe sí lo lea."))
        rows.append(InfoRow("Legible", readable ? "Sí" : "No", rawKey: "AVAsset.isReadable"))
        rows.append(InfoRow("Exportable", exportable ? "Sí" : "No", rawKey: "AVAsset.isExportable"))
        rows.append(InfoRow("Componible en montaje", composable ? "Sí" : "No", rawKey: "AVAsset.isComposable"))

        if let fragmented = try? await asset.load(.canContainFragments) {
            rows.append(InfoRow("Admite fragmentos", fragmented ? "Sí" : "No",
                                rawKey: "AVAsset.canContainFragments",
                                note: "Propio de MP4 fragmentado (fMP4), el formato base de HLS y DASH."))
        }
        if let lyrics = try? await asset.load(.lyrics), !lyrics.isEmpty {
            rows.append(InfoRow("Letra incrustada", "\(lyrics.count) caracteres", rawKey: "AVAsset.lyrics"))
        }

        rows.append(InfoRow("Pistas detectadas", "\(trackCount)", rawKey: "AVAsset.tracks"))
        return rows.isEmpty ? nil : InfoSection(
            "Contenedor según macOS",
            subtitle: "Lo que AVFoundation entiende del fichero",
            symbol: "apple.logo",
            rows: rows
        )
    }

    // MARK: - Metadata

    private static func metadataSection(asset: AVURLAsset) async -> InfoSection? {
        guard let formats = try? await asset.load(.availableMetadataFormats), !formats.isEmpty else {
            return nil
        }

        var subsections: [InfoSection] = []
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format), !items.isEmpty else { continue }
            var rows: [InfoRow] = []
            for item in items {
                let key = item.identifier?.rawValue ?? item.keySpace?.rawValue ?? "desconocido"
                let value = await describe(metadataItem: item)
                guard let value, !value.isEmpty else { continue }
                let label = item.commonKey?.rawValue ?? friendlyMetadataName(key)
                rows.append(InfoRow(label, value, rawKey: item.identifier?.rawValue ?? key))
            }
            if !rows.isEmpty {
                subsections.append(InfoSection(
                    friendlyFormatName(format.rawValue),
                    subtitle: format.rawValue,
                    symbol: "tag",
                    rows: rows.sorted { $0.label < $1.label }
                ))
            }
        }
        guard !subsections.isEmpty else { return nil }
        return InfoSection(
            "Metadatos incrustados",
            subtitle: "Etiquetas leídas por macOS (iTunes, QuickTime, ID3…)",
            symbol: "text.badge.star",
            subsections: subsections
        )
    }

    private static func describe(metadataItem item: AVMetadataItem) async -> String? {
        if let string = try? await item.load(.stringValue) {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = try? await item.load(.numberValue) {
            return number.stringValue
        }
        if let date = try? await item.load(.dateValue) {
            return Fmt.date(date)
        }
        if let data = try? await item.load(.dataValue) {
            return "\(Fmt.bytesShort(data.count)) de datos binarios"
        }
        return nil
    }

    private static func chapterSection(asset: AVURLAsset) async -> InfoSection? {
        guard let locales = try? await asset.load(.availableChapterLocales), !locales.isEmpty else {
            return nil
        }
        var rows: [InfoRow] = []
        for locale in locales {
            guard let groups = try? await asset.loadChapterMetadataGroups(
                withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyArtwork])
            else { continue }
            for (index, group) in groups.enumerated() {
                let titleItem = group.items.first { $0.commonKey == .commonKeyTitle }
                var name = "Capítulo \(index + 1)"
                if let titleItem, let loaded = try? await titleItem.load(.stringValue) {
                    name = loaded
                }
                let range = group.timeRange
                rows.append(InfoRow(
                    "\(index + 1). \(name)",
                    "\(Fmt.timecode(range.start.seconds)) → \(Fmt.timecode(range.end.seconds))",
                    rawKey: "chapter[\(index)]"
                ))
            }
        }
        return rows.isEmpty ? nil : InfoSection(
            "Capítulos", subtitle: "\(rows.count) capítulos", symbol: "list.bullet.indent", rows: rows)
    }

    // MARK: - Tracks

    private static func trackSection(_ track: AVAssetTrack) async -> InfoSection? {
        var rows: [InfoRow] = []
        let mediaType = track.mediaType.rawValue

        rows.append(InfoRow("Identificador de pista", "\(track.trackID)", rawKey: "AVAssetTrack.trackID"))
        rows.append(InfoRow("Tipo de medio", friendlyMediaType(track.mediaType), rawKey: "mediaType"))

        if let enabled = try? await track.load(.isEnabled) {
            rows.append(InfoRow("Activada", enabled ? "Sí" : "No", rawKey: "isEnabled"))
        }
        if let selfContained = try? await track.load(.isSelfContained) {
            rows.append(InfoRow("Datos autocontenidos", selfContained ? "Sí" : "No",
                                rawKey: "isSelfContained",
                                note: "«No» indica que la pista referencia datos de otro fichero."))
        }
        if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            rows.append(InfoRow("Tasa de datos estimada", Fmt.bitrate(Double(rate)), rawKey: "estimatedDataRate"))
        }
        if let language = try? await track.load(.languageCode), language != "und" {
            rows.append(InfoRow("Idioma", localizedLanguage(language), rawKey: "languageCode"))
        }
        if let tag = try? await track.load(.extendedLanguageTag) {
            rows.append(InfoRow("Etiqueta BCP-47", tag, rawKey: "extendedLanguageTag"))
        }
        if let size = try? await track.load(.naturalSize), size != .zero {
            rows.append(InfoRow("Tamaño natural", "\(Int(size.width)) × \(Int(size.height)) px",
                                rawKey: "naturalSize",
                                note: "Tamaño antes de aplicar la matriz de transformación."))
        }
        if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
            rows.append(InfoRow("Frame rate nominal", "\(Fmt.decimal(Double(fps), fractionDigits: 3)) fps",
                                rawKey: "nominalFrameRate"))
        }
        if let minDuration = try? await track.load(.minFrameDuration), minDuration.isNumeric, minDuration.seconds > 0 {
            rows.append(InfoRow("Duración mínima de frame",
                                "\(Fmt.decimal(minDuration.seconds * 1000, fractionDigits: 3)) ms",
                                rawKey: "minFrameDuration"))
        }
        if let segments = try? await track.load(.segments), segments.count > 1 {
            rows.append(InfoRow("Segmentos de edición", "\(segments.count)",
                                rawKey: "segments",
                                note: "Más de un segmento significa que la pista tiene cortes o huecos internos."))
        }
        if let characteristics = try? await track.load(.mediaCharacteristics), !characteristics.isEmpty {
            rows.append(InfoRow("Características",
                                characteristics.map { friendlyCharacteristic($0) }.joined(separator: ", "),
                                rawKey: "mediaCharacteristics"))
        }

        // Format descriptions carry the decoder configuration verbatim: SPS/PPS for H.264,
        // channel layouts for audio, colour tags, and the Apple stereo/spatial atoms.
        if let descriptions = try? await track.load(.formatDescriptions) {
            for (index, description) in descriptions.enumerated() {
                let subtype = CMFormatDescriptionGetMediaSubType(description)
                rows.append(InfoRow(descriptions.count > 1 ? "Formato \(index + 1)" : "Código de formato",
                                    fourCharCode(subtype),
                                    rawKey: "CMFormatDescription.mediaSubType",
                                    highlighted: true))
                if let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] {
                    rows.append(contentsOf: flatten(extensions, prefix: ""))
                }
            }
        }

        let title = "\(friendlyMediaType(track.mediaType)) · pista \(track.trackID)"
        return InfoSection(title, subtitle: mediaType, symbol: symbol(for: track.mediaType), rows: rows)
    }

    // MARK: - Thumbnail

    private static func thumbnail(asset: AVURLAsset) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        // A frame ~10% in avoids black leaders and fade-ins.
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let target = duration > 1 ? min(duration * 0.1, 30) : 0
        let time = CMTime(seconds: target, preferredTimescale: 600)

        guard let (image, _) = try? await generator.image(at: time) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: - Helpers

    /// Recursively turns a CoreMedia extensions dictionary into flat labelled rows.
    private static func flatten(_ dictionary: [String: Any], prefix: String) -> [InfoRow] {
        var rows: [InfoRow] = []
        for key in dictionary.keys.sorted() {
            let value = dictionary[key]!
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            switch value {
            case let nested as [String: Any]:
                rows.append(contentsOf: flatten(nested, prefix: path))
            case let array as [Any]:
                if let dictionaries = array as? [[String: Any]] {
                    for (index, item) in dictionaries.enumerated() {
                        rows.append(contentsOf: flatten(item, prefix: "\(path)[\(index)]"))
                    }
                } else {
                    rows.append(InfoRow(friendlyMetadataName(path),
                                        array.map { String(describing: $0) }.joined(separator: ", "),
                                        rawKey: path))
                }
            case let data as Data:
                rows.append(InfoRow(friendlyMetadataName(path),
                                    "\(Fmt.bytesShort(data.count)) · \(hexPreview(data))",
                                    rawKey: path,
                                    note: "Datos binarios de configuración del decodificador."))
            case let number as NSNumber:
                rows.append(InfoRow(friendlyMetadataName(path), number.stringValue, rawKey: path))
            default:
                let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                rows.append(InfoRow(friendlyMetadataName(path), text, rawKey: path))
            }
        }
        return rows
    }

    private static func hexPreview(_ data: Data, limit: Int = 16) -> String {
        let hex = data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > limit ? "\(hex)…" : hex
    }

    static func fourCharCode(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        let text = String(bytes: bytes, encoding: .macOSRoman) ?? "????"
        return "'\(text)'  (0x\(String(format: "%08X", code)))"
    }

    private static func describe(_ transform: CGAffineTransform) -> String {
        "[a \(Fmt.decimal(transform.a))  b \(Fmt.decimal(transform.b))  "
            + "c \(Fmt.decimal(transform.c))  d \(Fmt.decimal(transform.d))  "
            + "tx \(Fmt.decimal(transform.tx))  ty \(Fmt.decimal(transform.ty))]"
    }

    private static func rotationDegrees(from transform: CGAffineTransform) -> Int? {
        let radians = atan2(transform.b, transform.a)
        let degrees = Int((radians * 180 / .pi).rounded())
        return (degrees + 360) % 360
    }

    private static func localizedLanguage(_ code: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: code)
        return name.map { "\($0) (\(code))" } ?? code
    }

    private static func symbol(for mediaType: AVMediaType) -> String {
        switch mediaType {
        case .video: return "video"
        case .audio: return "waveform"
        case .subtitle, .closedCaption, .text: return "captions.bubble"
        case .timecode: return "clock"
        case .metadata: return "tag"
        default: return "square.stack"
        }
    }

    private static func friendlyMediaType(_ mediaType: AVMediaType) -> String {
        switch mediaType {
        case .video: return "Vídeo"
        case .audio: return "Audio"
        case .subtitle: return "Subtítulos"
        case .closedCaption: return "Subtítulos cerrados"
        case .text: return "Texto"
        case .timecode: return "Código de tiempo"
        case .metadata: return "Metadatos"
        case .muxed: return "Multiplexada"
        default: return mediaType.rawValue
        }
    }

    private static func friendlyCharacteristic(_ characteristic: AVMediaCharacteristic) -> String {
        switch characteristic {
        case .visual: return "visual"
        case .audible: return "audible"
        case .legible: return "legible"
        case .frameBased: return "basada en frames"
        case .containsAlphaChannel: return "canal alfa"
        case .containsOnlyForcedSubtitles: return "subtítulos forzados"
        case .describesMusicAndSoundForAccessibility: return "descripción sonora"
        case .describesVideoForAccessibility: return "audiodescripción"
        case .isOriginalContent: return "contenido original"
        case .dubbedTranslation: return "doblaje"
        case .languageTranslation: return "traducción"
        default: return characteristic.rawValue.replacingOccurrences(
            of: "public.", with: "")
        }
    }

    private static func friendlyFormatName(_ raw: String) -> String {
        switch raw {
        case "com.apple.itunes": return "iTunes / MP4"
        case "com.apple.quicktime.mdta": return "QuickTime (metadatos)"
        case "com.apple.quicktime.udta": return "QuickTime (datos de usuario)"
        case "org.id3": return "ID3"
        case "org.mp4ra": return "MP4RA"
        case "org.matroska": return "Matroska"
        default: return raw
        }
    }

    /// Strips the long reverse-DNS prefixes Apple uses so labels stay readable.
    private static func friendlyMetadataName(_ key: String) -> String {
        var name = key
        for prefix in ["com.apple.quicktime.", "com.apple.itunes.", "org.id3.", "id3/", "mdta/"] {
            name = name.replacingOccurrences(of: prefix, with: "")
        }
        return name
    }
}
