import Foundation

/// Labels, explanations and per-key formatting for the fields ffprobe emits.
///
/// Unknown keys are never dropped — they fall through to the raw key as label, so a
/// newer ffmpeg that adds a field still shows it.
enum FieldCatalog {
    struct Field {
        let label: String
        let note: String?
        let highlighted: Bool
        let format: ((JSONValue) -> String?)?

        init(_ label: String, note: String? = nil, highlighted: Bool = false,
             format: ((JSONValue) -> String?)? = nil) {
            self.label = label
            self.note = note
            self.highlighted = highlighted
            self.format = format
        }
    }

    /// Keys handled elsewhere (as nested sections or derived rows) so they are not
    /// repeated in the generic key/value dump.
    static let handledSeparately: Set<String> = [
        "disposition", "tags", "side_data_list", "streams", "chapters",
        "programs", "stream_groups", "index", "codec_type",
    ]

    static func field(for key: String) -> Field {
        catalog[key] ?? Field(prettify(key))
    }

    /// Preferred display order; anything not listed follows, alphabetically.
    static let order: [String] = [
        "codec_name", "codec_long_name", "profile", "level", "codec_tag_string", "codec_tag",
        "mime_codec_string", "width", "height", "coded_width", "coded_height",
        "sample_aspect_ratio", "display_aspect_ratio", "pix_fmt", "bits_per_raw_sample",
        "color_range", "color_space", "color_transfer", "color_primaries", "chroma_location",
        "field_order", "refs", "has_b_frames", "closed_captions", "film_grain",
        "r_frame_rate", "avg_frame_rate", "bit_rate", "max_bit_rate", "nb_frames",
        "sample_fmt", "sample_rate", "channels", "channel_layout", "bits_per_sample",
        "initial_padding", "duration", "duration_ts", "start_time", "start_pts", "time_base",
        "id", "is_avc", "nal_length_size", "extradata_size",
        "format_name", "format_long_name", "size", "probe_score", "nb_streams", "nb_programs",
    ]

    private static let catalog: [String: Field] = [
        // MARK: Container
        "filename": Field("Fichero"),
        "format_name": Field("Formato del contenedor", note: "Identificadores cortos que ffmpeg asocia al contenedor.", highlighted: true),
        "format_long_name": Field("Contenedor", highlighted: true),
        "nb_streams": Field("Número de pistas"),
        "nb_programs": Field("Número de programas", note: "Relevante en flujos de transporte (TS) con varios canales."),
        "nb_stream_groups": Field("Grupos de pistas"),
        "probe_score": Field("Fiabilidad de la detección", note: "0–100. Por debajo de 100 ffmpeg ha tenido que adivinar el formato.") { value in
            guard let score = value.intValue else { return nil }
            return "\(score) / 100"
        },
        "size": Field("Tamaño", highlighted: true) { $0.intValue.map(Fmt.bytes) },
        "start_time": Field("Inicio", note: "Desplazamiento del primer instante presentable respecto a cero.") { $0.doubleValue.map { "\(Fmt.decimal($0, fractionDigits: 6)) s" } },

        // MARK: Codec identity
        "codec_name": Field("Códec", highlighted: true),
        "codec_long_name": Field("Códec (nombre completo)"),
        "profile": Field("Perfil", note: "Conjunto de herramientas de compresión permitidas. Afecta a la compatibilidad con dispositivos.", highlighted: true),
        "codec_tag_string": Field("Etiqueta en el contenedor", note: "FourCC almacenado en el fichero, p. ej. «avc1» o «hvc1»."),
        "codec_tag": Field("Etiqueta (hex)"),
        "mime_codec_string": Field("Cadena MIME (RFC 6381)", note: "Lo que se pone en el atributo codecs= de HTML5 y HLS."),

        // MARK: Video geometry
        "width": Field("Anchura", highlighted: true) { $0.intValue.map { "\(Fmt.integer($0)) px" } },
        "height": Field("Altura", highlighted: true) { $0.intValue.map { "\(Fmt.integer($0)) px" } },
        "coded_width": Field("Anchura codificada", note: "Múltiplo del tamaño de macrobloque; puede superar la anchura visible.") { $0.intValue.map { "\(Fmt.integer($0)) px" } },
        "coded_height": Field("Altura codificada", note: "Múltiplo del tamaño de macrobloque; puede superar la altura visible.") { $0.intValue.map { "\(Fmt.integer($0)) px" } },
        "sample_aspect_ratio": Field("Relación de aspecto del píxel (SAR)", note: "Distinta de 1:1 significa píxeles no cuadrados."),
        "display_aspect_ratio": Field("Relación de aspecto en pantalla (DAR)"),
        "closed_captions": Field("Subtítulos incrustados (EIA-608/708)") { $0.boolValue.map { $0 ? "Sí" : "No" } },
        "film_grain": Field("Síntesis de grano", note: "Grano de película generado en el decodificador (AV1, AV1/HEVC con SEI).") { $0.boolValue.map { $0 ? "Sí" : "No" } },

        // MARK: Colour
        "pix_fmt": Field("Formato de píxel", note: "Submuestreo de croma, profundidad de bits y disposición en memoria.", highlighted: true),
        "bits_per_raw_sample": Field("Profundidad de bits", highlighted: true) { $0.intValue.map { "\($0) bits por componente" } },
        "color_range": Field("Rango de color", note: "«tv»/limited usa 16–235; «pc»/full usa 0–255. Un desajuste aquí lava o quema la imagen.") { value in
            switch value.stringValue {
            case "tv": return "Limitado (TV, 16–235)"
            case "pc": return "Completo (PC, 0–255)"
            default: return value.stringValue
            }
        },
        "color_space": Field("Matriz de color", note: "Cómo se convierte entre YCbCr y RGB."),
        "color_transfer": Field("Función de transferencia", note: "La curva gamma. smpte2084 (PQ) y arib-std-b67 (HLG) indican HDR.", highlighted: true),
        "color_primaries": Field("Primarios de color", note: "El gamut. bt709 es HD; bt2020 es ultra amplio (HDR)."),
        "chroma_location": Field("Posición del croma", note: "Alineación de las muestras de croma respecto a las de luma."),
        "field_order": Field("Orden de campos", note: "«progressive» es imagen completa; el resto indica entrelazado."),

        // MARK: Motion / structure
        "r_frame_rate": Field("Frame rate base", note: "La menor tasa que representa todos los tiempos sin pérdida.", highlighted: true) { $0.stringValue.flatMap(Fmt.frameRate) },
        "avg_frame_rate": Field("Frame rate medio", highlighted: true) { $0.stringValue.flatMap(Fmt.frameRate) },
        "has_b_frames": Field("Profundidad de reordenación", note: "Número máximo de frames que el decodificador debe retener para reordenar. >0 implica frames B."),
        "refs": Field("Frames de referencia"),
        "nb_frames": Field("Número de frames") { $0.intValue.map(Fmt.integer) },
        "nb_read_frames": Field("Frames leídos") { $0.intValue.map(Fmt.integer) },
        "nb_read_packets": Field("Paquetes leídos") { $0.intValue.map(Fmt.integer) },

        // MARK: Audio
        "sample_fmt": Field("Formato de muestra", note: "Representación interna tras decodificar (p. ej. fltp = float planar)."),
        "sample_rate": Field("Frecuencia de muestreo", highlighted: true) { $0.doubleValue.map(Fmt.sampleRate) },
        "channels": Field("Canales", highlighted: true),
        "channel_layout": Field("Disposición de canales", highlighted: true),
        "bits_per_sample": Field("Bits por muestra") { value in
            guard let bits = value.intValue, bits > 0 else { return nil }
            return "\(bits) bits"
        },
        "initial_padding": Field("Relleno inicial", note: "Muestras que el decodificador debe descartar al inicio (encoder delay).") { $0.intValue.map { "\(Fmt.integer($0)) muestras" } },

        // MARK: Rates and timing
        "bit_rate": Field("Tasa de bits", highlighted: true) { $0.doubleValue.map(Fmt.bitrate) },
        "max_bit_rate": Field("Tasa de bits máxima") { $0.doubleValue.map(Fmt.bitrate) },
        "duration": Field("Duración", highlighted: true) { $0.doubleValue.map(Fmt.duration) },
        "duration_ts": Field("Duración en unidades de time base") { $0.intValue.map(Fmt.integer) },
        "start_pts": Field("PTS inicial"),
        "time_base": Field("Base de tiempo", note: "Unidad mínima de tiempo del contenedor para esta pista."),
        "id": Field("ID de pista en el contenedor"),

        // MARK: Bitstream detail
        "is_avc": Field("Formato AVC (longitud)", note: "«true» = paquetes con prefijo de longitud (MP4). «false» = flujo Annex-B (TS).") { $0.boolValue.map { $0 ? "Sí (MP4/ISOBMFF)" : "No (Annex-B)" } },
        "nal_length_size": Field("Tamaño del prefijo NAL") { $0.intValue.map { "\($0) bytes" } },
        "extradata_size": Field("Tamaño de extradata", note: "Cabeceras del decodificador (SPS/PPS/VPS) guardadas en el contenedor.") { $0.intValue.map { "\(Fmt.integer($0)) bytes" } },
        "level": Field("Nivel"),
        "divx_packed": Field("DivX packed bitstream"),
    ]

    // MARK: - Derived readings

    /// Expands `yuv420p10le` into something a human can act on.
    static func explainPixelFormat(_ value: String) -> String? {
        var parts: [String] = []

        if value.hasPrefix("yuvj") {
            parts.append("YCbCr con rango completo")
        } else if value.hasPrefix("yuva") {
            parts.append("YCbCr con canal alfa")
        } else if value.hasPrefix("yuv") {
            parts.append("YCbCr")
        } else if value.hasPrefix("gbrp") || value.hasPrefix("rgb") || value.hasPrefix("bgr") {
            parts.append("RGB")
        } else if value.hasPrefix("gray") {
            parts.append("Escala de grises")
        } else if value.hasPrefix("p0") || value.hasPrefix("nv") {
            parts.append("YCbCr semiplanar")
        }

        for (needle, description) in [
            ("444", "sin submuestreo de croma (4:4:4)"),
            ("422", "submuestreo 4:2:2"),
            ("440", "submuestreo 4:4:0"),
            ("420", "submuestreo 4:2:0"),
            ("411", "submuestreo 4:1:1"),
            ("410", "submuestreo 4:1:0"),
        ] where value.contains(needle) {
            parts.append(description)
            break
        }

        if let match = value.range(of: "\\d{1,2}(?=le|be)", options: .regularExpression) {
            parts.append("\(value[match]) bits por componente")
        } else if !value.contains("le"), !value.contains("be"), value.contains("p") || value.hasPrefix("yuv") {
            parts.append("8 bits por componente")
        }

        if value.hasSuffix("le") { parts.append("little-endian") }
        if value.hasSuffix("be") { parts.append("big-endian") }
        if value.contains("a") && value.hasPrefix("yuva") { parts.append("con transparencia") }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// H.264 encodes level as level×10, HEVC as level×30.
    static func explainLevel(_ level: Int, codec: String?) -> String {
        switch codec {
        case "hevc", "h265":
            let value = Double(level) / 30
            return "\(Fmt.decimal(value, fractionDigits: 1))  (valor bruto \(level))"
        case "h264", "avc":
            let value = Double(level) / 10
            return "\(Fmt.decimal(value, fractionDigits: 1))  (valor bruto \(level))"
        default:
            return "\(level)"
        }
    }

    /// Turns `avg_frame_rate` values into the broadcast standard they correspond to.
    static func frameRateStandard(_ fps: Double) -> String? {
        let standards: [(Double, String)] = [
            (23.976, "23,976 fps — cine transferido a NTSC"),
            (24, "24 fps — cine"),
            (25, "25 fps — PAL"),
            (29.97, "29,97 fps — NTSC"),
            (30, "30 fps"),
            (48, "48 fps — alta cadencia"),
            (50, "50 fps — PAL de alta cadencia"),
            (59.94, "59,94 fps — NTSC de alta cadencia"),
            (60, "60 fps"),
            (120, "120 fps — alta velocidad"),
        ]
        return standards.first { abs($0.0 - fps) < 0.02 }?.1
    }

    static func prettify(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
            .prefix(1).uppercased() + key.replacingOccurrences(of: "_", with: " ").dropFirst()
    }

    // MARK: Disposition flags

    static let dispositionLabels: [String: String] = [
        "default": "Por omisión",
        "dub": "Doblaje",
        "original": "Pista original",
        "comment": "Comentario",
        "lyrics": "Letra",
        "karaoke": "Karaoke",
        "forced": "Forzada",
        "hearing_impaired": "Para personas sordas",
        "visual_impaired": "Audiodescripción",
        "clean_effects": "Efectos limpios",
        "attached_pic": "Imagen adjunta (carátula)",
        "timed_thumbnails": "Miniaturas temporizadas",
        "non_diegetic": "Sonido no diegético",
        "captions": "Subtítulos",
        "descriptions": "Descripciones",
        "metadata": "Metadatos",
        "dependent": "Pista dependiente",
        "still_image": "Imagen fija",
        "multilayer": "Multicapa",
    ]

    static let tagLabels: [String: String] = [
        "title": "Título",
        "artist": "Artista",
        "album": "Álbum",
        "album_artist": "Artista del álbum",
        "composer": "Compositor",
        "date": "Fecha",
        "creation_time": "Fecha de creación",
        "comment": "Comentario",
        "encoder": "Codificado con",
        "handler_name": "Nombre del manejador",
        "vendor_id": "Identificador del fabricante",
        "language": "Idioma",
        "major_brand": "Marca principal (brand)",
        "minor_version": "Versión menor",
        "compatible_brands": "Marcas compatibles",
        "genre": "Género",
        "track": "Pista",
        "copyright": "Copyright",
        "description": "Descripción",
        "synopsis": "Sinopsis",
        "show": "Serie",
        "episode_id": "Identificador de episodio",
        "media_type": "Tipo de medio",
        "purchase_date": "Fecha de compra",
        "encoder_options": "Opciones del codificador",
        "com.android.version": "Versión de Android",
        "com.apple.quicktime.make": "Fabricante del dispositivo",
        "com.apple.quicktime.model": "Modelo del dispositivo",
        "com.apple.quicktime.software": "Software",
        "com.apple.quicktime.location.ISO6709": "Ubicación (ISO 6709)",
        "com.apple.quicktime.creationdate": "Fecha de grabación",
    ]
}
