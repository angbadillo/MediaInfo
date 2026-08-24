import AppKit
import Foundation

/// Frame grabber for the containers AVFoundation refuses to open — Matroska, WebM,
/// transport streams. Uses the bundled ffmpeg, which shares the libraries ffprobe
/// already brings along.
enum FFmpegThumbnail {
    static let executableURL: URL? = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }()

    /// Decodes a single frame around `seconds` and returns it as an image.
    static func image(for url: URL, at seconds: Double) -> NSImage? {
        guard let executableURL else { return nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-hide_banner", "-v", "error",
            // Seeking before -i is the fast path: ffmpeg jumps to the nearest keyframe
            // instead of decoding from the start.
            "-ss", String(format: "%.3f", max(0, seconds)),
            "-i", url.path,
            "-frames:v", "1",
            "-vf", "scale='min(960,iw)':-2",
            "-f", "image2pipe", "-c:v", "png", "-",
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }
}
