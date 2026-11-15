// Headless check that MediaStreamLoader streams: AVPlayer must start playing long before
// the whole file has arrived. Uses a synthetic 10 s MP4 (index written last, like phone
// recordings) served over a fake ~2 MB/s link. No phone needed.
//
//   cd macos-app && swiftc -parse-as-library Sources/LinkMyMac/MediaStreamLoader.swift \
//       Checks/StreamLoaderCheck.swift -o .build/stream-check && .build/stream-check
@preconcurrency import AVFoundation

@main
struct StreamLoaderCheck {
    @MainActor
    static func main() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("linkmymac-stream-check.mp4")
        do { try await writeTestVideo(to: url) } catch { fail("could not write test video: \(error)") }
        let file = try! Data(contentsOf: url)
        print("test video: \(file.count / 1024) KB")

        var delivered = 0
        var cancelled = Set<String>()
        var ranges: [String] = []
        let loader = MediaStreamLoader(
            mimeType: "video/mp4",
            size: Int64(file.count),
            requestRange: { id, offset, length, sink in
                ranges.append("\(offset)+\(length)")
                var position = Int(offset)
                let end = min(Int(offset + length), file.count)
                func next() { // 256 KB every 125 ms ≈ 2 MB/s
                    guard !cancelled.contains(id) else { return }
                    guard position < end else { return sink(.done(error: nil)) }
                    let chunk = file.subdata(in: position..<min(position + 256 * 1024, end))
                    position += chunk.count
                    delivered += chunk.count
                    sink(.data(chunk))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.125) { MainActor.assumeIsolated { next() } }
                }
                next()
            },
            cancelRange: { cancelled.insert($0) }
        )
        let player = loader.makePlayer()
        player.isMuted = true
        player.play()

        var deliveredAtStart: Int?
        for _ in 0..<200 { // up to 20 s
            try? await Task.sleep(nanoseconds: 100_000_000)
            let t = player.currentTime().seconds
            if deliveredAtStart == nil, t > 0.1 { deliveredAtStart = delivered }
            if t >= 2 { break }
        }
        loader.stopAll()

        guard let atStart = deliveredAtStart, player.currentTime().seconds >= 2 else {
            fail("video never played (status \(player.currentItem?.status.rawValue ?? -1), " +
                 "error \(player.currentItem?.error?.localizedDescription ?? "none"), ranges \(ranges))")
        }
        let percent = atStart * 100 / file.count
        print("ranges requested: \(ranges.prefix(6).joined(separator: ", "))")
        print("playback started after \(atStart / 1024) KB = \(percent)% of the file")
        guard percent < 60 else { fail("playback waited for most of the file") }
        print("PASS  video plays while still streaming")
    }

    static func fail(_ message: String) -> Never {
        print("FAIL  \(message)")
        exit(1)
    }

    /// 10 s of 320×240 noise at 8 Mbit/s (~10 MB). Noise keeps the encoder from shrinking it.
    static func writeTestVideo(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<300 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            arc4random_buf(CVPixelBufferGetBaseAddress(buffer!), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
