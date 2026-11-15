import SwiftUI
import AVKit

/// Inline player for the Videos tab (Figma: Mac · Videos, "Now playing"). Streams the video from
/// the phone in byte ranges unless it's downloaded, and stops the stream when it goes away.
/// Give it `.id(item.id)` so picking another video builds a fresh player.
struct MediaPlayerPanel: View {
    let item: RemoteMediaItem
    @ObservedObject var client: MacP2PClient
    /// Built on first Play; making it in `body` would restart playback on every re-render.
    @State private var player: AVPlayer?
    @State private var streamLoader: MediaStreamLoader?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player) { titleOverlay }
            } else {
                if let data = item.thumbnailData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                }
                LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                titleOverlay
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .help("Play")
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDisappear {
            player?.pause()
            streamLoader?.stopAll() // tell the phone to stop sending
        }
    }

    private var titleOverlay: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(.lmHeadline).foregroundStyle(.white).lineLimit(1)
                    if !item.folderName.isEmpty {
                        Text(item.folderName).font(.lmCaption).foregroundStyle(.white.opacity(0.75))
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: isLocal ? "checkmark.circle" : "wifi").font(.system(size: 11, weight: .semibold))
                    Text(isLocal ? "Saved on this Mac" : "Streaming from \(client.connectedDeviceName ?? "your phone")").font(.lmCaption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.45)))
            }
            .padding(16)
            Spacer()
        }
    }

    private var isLocal: Bool { client.localFileURL(for: item.id) != nil }
    private var canPlay: Bool { client.isPaired || isLocal }

    private func play() {
        if player == nil {
            if let url = client.localFileURL(for: item.id) {
                player = AVPlayer(url: url)
            } else if let loader = client.makeStreamLoader(for: item) {
                streamLoader = loader
                player = loader.makePlayer()
            }
        }
        player?.play()
    }
}
