import Foundation

/// Locates and drives the `ffprobe` binary shipped inside the app bundle.
enum FFProbe {
    enum Failure: LocalizedError {
        case notFound
        case launchFailed(String)
        case probeError(String)
        case badOutput

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No se encontró ffprobe. Debería estar en MediaInfo.app/Contents/Helpers/ffprobe."
            case .launchFailed(let message):
                return "No se pudo ejecutar ffprobe: \(message)"
            case .probeError(let message):
                return "ffprobe: \(message)"
            case .badOutput:
                return "ffprobe devolvió una respuesta que no se pudo interpretar."
            }
        }
    }

    /// Bundled helper first; a system install is accepted as a fallback so the app also
    /// works when run straight from `swift run` during development.
    static let executableURL: URL? = {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ffprobe")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }

        for candidate in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }()

    static var isBundled: Bool {
        executableURL?.path.contains("/Contents/Helpers/") ?? false
    }

    /// Runs ffprobe and returns stdout. `ffprobe` writes diagnostics to stderr and
    /// exits non-zero on unreadable input, so both are inspected.
    static func run(arguments: [String]) throws -> Data {
        guard let executableURL else { throw Failure.notFound }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently: a large -show_packets dump will fill the
        // 64 KB pipe buffer and deadlock if we wait for exit before reading.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ffprobe.io", attributes: .concurrent)
        group.enter()
        queue.async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        if process.terminationStatus != 0, outData.isEmpty {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.probeError(message.isEmpty ? "ffprobe terminó con código \(process.terminationStatus)." : message)
        }
        return outData
    }

    // MARK: - Queries

    /// Container, streams, chapters, programs and stream groups in one pass.
    static func inspect(url: URL) throws -> (json: [String: JSONValue], raw: String) {
        let data = try run(arguments: [
            "-hide_banner", "-v", "error",
            "-print_format", "json",
            "-show_format", "-show_streams", "-show_chapters",
            "-show_programs", "-show_stream_groups",
            "-show_private_data", "-show_error",
            url.path,
        ])
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw Failure.badOutput
        }
        if let error = root["error"]?.objectValue {
            throw Failure.probeError(error[string: "string"] ?? "Fichero no reconocido.")
        }
        let raw = prettyPrinted(data) ?? String(data: data, encoding: .utf8) ?? ""
        return (root, raw)
    }

    /// Decoded detail for the first `count` frames of a stream.
    ///
    /// HDR10 mastering-display and content-light-level metadata travel in-band as SEI,
    /// so they only show up in *frame* side data — never in `-show_streams`.
    static func frames(url: URL, streamSpecifier: String, count: Int) throws -> [[String: JSONValue]] {
        let data = try run(arguments: [
            "-hide_banner", "-v", "error",
            "-print_format", "json",
            "-select_streams", streamSpecifier,
            "-show_frames",
            "-read_intervals", "%+#\(count)",
            url.path,
        ])
        let root = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        return root?["frames"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    /// Packet sizes and timestamps for the whole stream, as CSV.
    ///
    /// CSV rather than JSON: a two-hour film has hundreds of thousands of packets and
    /// the JSON form is an order of magnitude more bytes to produce and parse.
    static func packets(url: URL, streamSpecifier: String) throws -> [Packet] {
        let data = try run(arguments: [
            "-hide_banner", "-v", "error",
            "-select_streams", streamSpecifier,
            "-show_entries", "packet=pts_time,dts_time,duration_time,size,flags",
            "-of", "csv=p=0",
            url.path,
        ])
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var packets: [Packet] = []
        packets.reserveCapacity(text.count / 32)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 5 else { continue }
            // pts_time can be "N/A" on streams without presentation timestamps.
            let pts = Double(fields[0]) ?? Double(fields[1]) ?? .nan
            guard let size = Int(fields[3]) else { continue }
            packets.append(Packet(
                time: pts,
                duration: Double(fields[2]) ?? 0,
                size: size,
                isKeyframe: fields[4].contains("K")
            ))
        }
        return packets
    }

    struct Packet {
        let time: Double
        let duration: Double
        let size: Int
        let isKeyframe: Bool
    }

    /// ffmpeg version and library build info, shown in the "engine" section.
    static func versions() -> [String: JSONValue]? {
        guard let data = try? run(arguments: ["-hide_banner", "-v", "quiet", "-print_format", "json", "-show_versions"]) else {
            return nil
        }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private static func prettyPrinted(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
