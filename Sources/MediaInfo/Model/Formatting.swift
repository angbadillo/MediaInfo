import Foundation

/// Unit-aware formatters shared by the report builder and the exporters.
enum Fmt {
    // MARK: Numbers

    static func decimal(_ value: Double, fractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = fractionDigits
        formatter.minimumFractionDigits = 0
        formatter.locale = .current
        return formatter.string(from: value as NSNumber) ?? String(value)
    }

    static func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        return formatter.string(from: value as NSNumber) ?? String(value)
    }

    // MARK: Sizes

    /// Both the decimal size (what Finder shows) and the exact byte count.
    static func bytes(_ value: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        let pretty = formatter.string(fromByteCount: Int64(value))
        return "\(pretty)  (\(integer(value)) bytes)"
    }

    static func bytesShort(_ value: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
    }

    // MARK: Rates

    static func bitrate(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond > 0 else { return "—" }
        if bitsPerSecond >= 1_000_000 {
            return "\(decimal(bitsPerSecond / 1_000_000)) Mb/s  (\(integer(Int(bitsPerSecond))) bit/s)"
        }
        if bitsPerSecond >= 1_000 {
            return "\(decimal(bitsPerSecond / 1_000)) kb/s  (\(integer(Int(bitsPerSecond))) bit/s)"
        }
        return "\(integer(Int(bitsPerSecond))) bit/s"
    }

    static func bitrateShort(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond > 0 else { return "—" }
        if bitsPerSecond >= 1_000_000 { return "\(decimal(bitsPerSecond / 1_000_000, fractionDigits: 1)) Mb/s" }
        return "\(decimal(bitsPerSecond / 1_000, fractionDigits: 0)) kb/s"
    }

    static func sampleRate(_ hertz: Double) -> String {
        guard hertz > 0 else { return "—" }
        return "\(decimal(hertz / 1_000, fractionDigits: 3)) kHz  (\(integer(Int(hertz))) Hz)"
    }

    // MARK: Time

    /// `1 h 23 min 45,678 s` alongside the raw seconds — both matter when checking sync.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = Double(total % 60) + seconds.truncatingRemainder(dividingBy: 1)
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) h") }
        if hours > 0 || minutes > 0 { parts.append("\(minutes) min") }
        parts.append("\(decimal(secs, fractionDigits: 3)) s")
        return "\(parts.joined(separator: " "))  (\(decimal(seconds, fractionDigits: 6)) s)"
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--:--" }
        let total = Int(seconds)
        let millis = Int((seconds - Double(total)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", total / 3600, (total % 3600) / 60, total % 60, millis)
    }

    static func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: value)
    }

    // MARK: Video specifics

    /// ffprobe reports frame rates as rationals such as `30000/1001`.
    static func frameRate(_ rational: String) -> String? {
        let parts = rational.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return nil }
        let value = parts[0] / parts[1]
        guard value > 0 else { return nil }
        return "\(decimal(value, fractionDigits: 3)) fps  (\(rational))"
    }

    static func frameRateValue(_ rational: String?) -> Double? {
        guard let rational else { return nil }
        let parts = rational.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0, parts[0] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    /// Greatest-common-divisor aspect ratio, e.g. `1920x1080` -> `16:9`.
    static func aspectRatio(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = gcd(width, height)
        return "\(width / divisor):\(height / divisor)"
    }

    /// Marketing-style label for a resolution, useful at a glance.
    static func resolutionClass(width: Int, height: Int) -> String? {
        let longest = max(width, height)
        let shortest = min(width, height)
        switch (longest, shortest) {
        case (7680..., _): return "8K UHD"
        case (3840..., _): return "4K UHD"
        case (2560..., _): return "1440p (QHD)"
        case (1920..., _): return "1080p (Full HD)"
        case (1280..., _): return "720p (HD)"
        case (720..., _): return "SD"
        default: return nil
        }
    }

    static func megapixels(width: Int, height: Int) -> String {
        decimal(Double(width * height) / 1_000_000, fractionDigits: 2) + " MP"
    }

    /// Bits per pixel per frame — the classic "is this over- or under-compressed?" ratio.
    static func bitsPerPixel(bitrate: Double, width: Int, height: Int, fps: Double) -> String? {
        guard bitrate > 0, width > 0, height > 0, fps > 0 else { return nil }
        return decimal(bitrate / (Double(width) * Double(height) * fps), fractionDigits: 4) + " bpp"
    }
}
