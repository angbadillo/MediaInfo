import Foundation

/// Turns raw packet sizes into a bitrate curve plus GOP/frame statistics.
enum BitrateAnalyzer {
    /// Aim for roughly this many points on the chart regardless of clip length, so a
    /// 10-second clip gets fine detail and a three-hour film stays responsive.
    private static let targetSampleCount = 600
    private static let minimumWindow = 0.5

    struct Result {
        let samples: [BitrateSample]
        let stats: MediaReport.BitrateStats
        let windowSeconds: Double
    }

    static func analyze(packets: [FFProbe.Packet], duration: Double?) -> Result? {
        let timed = packets.filter { $0.time.isFinite }
        guard !timed.isEmpty else { return nil }

        let start = timed.map(\.time).min() ?? 0
        let end = timed.map { $0.time + max($0.duration, 0) }.max() ?? start
        let span = max(end - start, duration ?? 0)
        guard span > 0 else { return nil }

        // Keyframes are much larger than the frames around them, so a window that is not a
        // whole number of GOPs alternates between buckets that contain one and buckets that
        // contain none — a sawtooth that says nothing about the content. Snapping the window
        // to a multiple of the GOP interval makes every bucket comparable.
        let keyframeTimes = timed.filter(\.isKeyframe).map(\.time).sorted()
        let gopSeconds: Double? = {
            guard keyframeTimes.count > 1 else { return nil }
            let gaps = zip(keyframeTimes.dropFirst(), keyframeTimes).map(-)
            return gaps.reduce(0, +) / Double(gaps.count)
        }()

        var window = max(minimumWindow, (span / Double(targetSampleCount)).rounded(.up))
        // Only worth snapping when the two are of comparable size. With a GOP far longer
        // than the window each keyframe is a single visible spike, which is real detail
        // rather than aliasing, and snapping would throw away resolution.
        if let gopSeconds, gopSeconds > 0.05, gopSeconds <= window * 4, gopSeconds < span / 4 {
            window = gopSeconds * max(1, (window / gopSeconds).rounded())
        }
        let bucketCount = max(1, Int((span / window).rounded(.up)))

        var bytesPerBucket = [Int](repeating: 0, count: bucketCount)
        var keyframesPerBucket = [Int](repeating: 0, count: bucketCount)

        for packet in timed {
            let index = min(bucketCount - 1, max(0, Int((packet.time - start) / window)))
            bytesPerBucket[index] += packet.size
            if packet.isKeyframe { keyframesPerBucket[index] += 1 }
        }

        var samples: [BitrateSample] = []
        samples.reserveCapacity(bucketCount)
        for index in 0..<bucketCount {
            samples.append(BitrateSample(
                time: start + Double(index) * window,
                bitsPerSecond: Double(bytesPerBucket[index]) * 8 / window,
                keyframes: keyframesPerBucket[index]
            ))
        }

        // The final bucket is usually partial, which shows up as a fake bitrate dip.
        if samples.count > 2, let last = samples.last, let previous = samples.dropLast().last,
           last.bitsPerSecond < previous.bitsPerSecond * 0.5 {
            samples.removeLast()
        }

        let totalBytes = timed.reduce(0) { $0 + $1.size }
        let average = Double(totalBytes) * 8 / span
        let peakSample = samples.max { $0.bitsPerSecond < $1.bitsPerSecond }
        let peak = peakSample?.bitsPerSecond ?? average
        let minimum = samples.map(\.bitsPerSecond).min() ?? average

        let stats = MediaReport.BitrateStats(
            average: average,
            peak: peak,
            minimum: minimum,
            peakTime: peakSample?.time ?? 0,
            variability: average > 0 ? peak / average : 0,
            keyframeCount: keyframeTimes.count,
            averageGOPSeconds: gopSeconds,
            frameCount: timed.count,
            largestFrameBytes: timed.map(\.size).max() ?? 0,
            smallestFrameBytes: timed.map(\.size).min() ?? 0
        )

        return Result(samples: samples, stats: stats, windowSeconds: window)
    }
}
