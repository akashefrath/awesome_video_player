import AVFoundation
import UIKit

/// A custom UIView subclass that is backed by an AVPlayerLayer to display video content.
public final class BetterPlayerView: UIView {

    // MARK: - Properties

    /// The AVPlayer instance whose content is displayed by the view's layer.
    ///
    /// This is a computed property that safely gets and sets the player on the underlying AVPlayerLayer.
    /// The setter ensures that the player is always assigned on the main thread, which is a requirement for UI updates.
    public var player: AVPlayer? {
        get {
            return playerLayer.player
        }
        set {
            // UI-related properties should always be set on the main thread.
            if Thread.isMainThread {
                playerLayer.player = newValue
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.playerLayer.player = newValue
                }
            }
        }
    }

    /// A type-safe, computed property to access the view's backing layer as an AVPlayerLayer.
    var playerLayer: AVPlayerLayer {
        // The force cast (as!) is safe here because we have overridden the `layerClass`
        // to guarantee that this view's backing layer is always an AVPlayerLayer.
        return self.layer as! AVPlayerLayer
    }

    // MARK: - UIView Overrides

    /// Overridden to specify that the backing layer for this view should be an AVPlayerLayer.
    /// This is the standard and most efficient way to create a player view.
    override public static var layerClass: AnyClass {
        return AVPlayerLayer.self
    }
}