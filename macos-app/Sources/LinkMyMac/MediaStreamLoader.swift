@preconcurrency import AVFoundation
import UniformTypeIdentifiers

/// What the phone sends back for one byte-range request.
enum MediaRangeEvent {
    case data(Data)
    case done(error: String?)
}

/**
 * Feeds AVPlayer from the phone in byte ranges, so a video starts after the first few
 * hundred KB instead of after the whole file has downloaded.
 *
 * AVPlayer asks for ranges as it needs them, often the end of the file first, since phone
 * cameras write the MP4 index last. Each range becomes one request to the phone; a seek
 * or closing the player cancels the ranges it no longer needs.
 */
@MainActor
final class MediaStreamLoader: NSObject, AVAssetResourceLoaderDelegate {
    typealias RequestRange = (_ id: String, _ offset: Int64, _ length: Int64,
                              _ sink: @escaping (MediaRangeEvent) -> Void) -> Void
    typealias CancelRange = (_ id: String) -> Void

    private let contentType: String
    private let contentLength: Int64
    private let requestRange: RequestRange
    private let cancelRange: CancelRange
    private var pending: [String: AVAssetResourceLoadingRequest] = [:]

    init(mimeType: String, size: Int64, requestRange: @escaping RequestRange, cancelRange: @escaping CancelRange) {
        contentType = UTType(mimeType: mimeType)?.identifier ?? UTType.mpeg4Movie.identifier
        contentLength = size
        self.requestRange = requestRange
        self.cancelRange = cancelRange
    }

    /// A player streaming through this loader. AVFoundation holds the delegate weakly,
    /// so keep the loader alive as long as the player.
    func makePlayer() -> AVPlayer {
        let asset = AVURLAsset(url: URL(string: "linkmymac-media://stream")!)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    /// Player closed: stop every range the phone is still sending.
    func stopAll() {
        pending.keys.forEach(cancelRange)
        pending.removeAll()
    }

    // The delegate queue is .main, so these hop onto the main actor synchronously.
    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated { start(loadingRequest) }
        return true
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                    didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated { cancel(loadingRequest) }
    }

    private func start(_ request: AVAssetResourceLoadingRequest) {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = contentLength
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }
        let offset = dataRequest.requestedOffset
        let length = dataRequest.requestsAllDataToEndOfResource
            ? contentLength - offset
            : Int64(dataRequest.requestedLength)
        let id = UUID().uuidString
        pending[id] = request
        // ponytail: an open-ended range streams as fast as the link allows; window it if multi-GB videos strain memory.
        requestRange(id, offset, length) { [weak self] event in
            self?.receive(id, event)
        }
    }

    private func receive(_ id: String, _ event: MediaRangeEvent) {
        guard let request = pending[id] else { return } // cancelled meanwhile
        switch event {
        case .data(let data):
            request.dataRequest?.respond(with: data)
        case .done(let error):
            pending[id] = nil
            if let error {
                request.finishLoading(with: NSError(domain: "LinkMyMac", code: 1,
                                                    userInfo: [NSLocalizedDescriptionKey: error]))
            } else {
                request.finishLoading()
            }
        }
    }

    private func cancel(_ request: AVAssetResourceLoadingRequest) {
        guard let id = pending.first(where: { $0.value === request })?.key else { return }
        pending[id] = nil
        cancelRange(id)
    }
}
