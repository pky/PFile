import SwiftUI
import AVFoundation
import UIKit

/// AVPlayerLayer をそのまま backing layer に持つ UIView。
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
}

/// AVPlayer を AVPlayerLayer で描画する SwiftUI ラッパー。
/// VLCPlayerView と同じく、描画 View が用意できたら一度だけ onReady を呼ぶ。
struct AVPlayerLayerView: UIViewRepresentable {

    let player: AVPlayer
    let onReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.player = player
        notifyReady(context: context)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
        notifyReady(context: context)
    }

    static func dismantleUIView(_ uiView: PlayerLayerUIView, coordinator: Coordinator) {
        uiView.player = nil
    }

    private func notifyReady(context: Context) {
        guard !context.coordinator.didNotifyReady else { return }
        context.coordinator.didNotifyReady = true
        onReady()
    }

    final class Coordinator {
        var didNotifyReady = false
    }
}
