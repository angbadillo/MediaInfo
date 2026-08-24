import Foundation

/// Headless mode, so the same analysis can be scripted:
///
///     MediaInfo.app/Contents/MacOS/MediaInfo --print vídeo.mp4 --formato markdown
///
/// Without `--print` the binary starts the normal windowed app.
enum CommandLineMode {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(where: { $0 == "--print" || $0 == "--imprimir" })
        else { return }

        guard flagIndex + 1 < arguments.count else {
            fail("uso: MediaInfo --print <fichero> [--formato texto|markdown|json|json-ffprobe|csv] [--sin-bitrate]")
        }

        let path = arguments[flagIndex + 1]
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("no existe el fichero: \(url.path)")
        }

        var format = ReportExporter.Format.text
        if let index = arguments.firstIndex(where: { $0 == "--formato" || $0 == "--format" }),
           index + 1 < arguments.count {
            switch arguments[index + 1].lowercased() {
            case "texto", "text", "txt": format = .text
            case "markdown", "md": format = .markdown
            case "json": format = .json
            case "json-ffprobe", "raw": format = .rawJSON
            case "csv": format = .csv
            default: fail("formato desconocido: \(arguments[index + 1])")
            }
        }

        let includeBitrate = !arguments.contains("--sin-bitrate") && !arguments.contains("--no-bitrate")

        // The App has not started, so drive the async analyser from a semaphore.
        let semaphore = DispatchSemaphore(value: 0)
        var result: MediaReport?
        Task {
            var report = await ReportBuilder.build(url: url)
            if includeBitrate {
                report = await ReportBuilder.attachBitrateCurve(to: report)
            }
            result = report
            semaphore.signal()
        }
        semaphore.wait()

        guard let report = result else { fail("no se pudo analizar el fichero") }

        for warning in report.warnings {
            FileHandle.standardError.write(Data("aviso: \(warning)\n".utf8))
        }
        print(ReportExporter.export(report, as: format))
        exit(report.sections.isEmpty ? 1 : 0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("MediaInfo: \(message)\n".utf8))
        exit(2)
    }
}
