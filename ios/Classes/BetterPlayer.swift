import AVFoundation
import AVKit
import Flutter
import GLKit

// MARK: - BetterPlayer Class Definition

// FIX: Removed redundant 'FlutterPlatformView' conformance here.
// The conformance is correctly handled in the extension at the bottom of the file.
public final class BetterPlayer: NSObject {
    // MARK: - Properties

    // Core Player
    let player: AVPlayer
    private var isInitialized = false
    public var isLooping = false
    private(set) var disposed = false
    public var playerRate: Float = 1.0

    private var overriddenDuration: Int = 0
    public var isPlaying: Bool {
        return player.rate != 0 && player.error == nil
    }

    // State & Identifiers
    private(set) var key: String?
    private var observersAdded = false

    // Data Handling
    private(set) var loaderDelegate: BetterPlayerEzDrmAssetsLoaderDelegate?
    private var cacheManager: CacheManager?

    // Communication
    var eventChannel: FlutterEventChannel?
    var eventSink: FlutterEventSink?

    // Picture-in-Picture (PiP)
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var restoreUserInterfaceForPIPStopCompletionHandler: ((Bool) -> Void)?
    private var pictureInPicture = false

    // Stall Detection
    private var stalledCount = 0
    private var isStalledCheckStarted = false

    // View
    private let betterPlayerView: BetterPlayerView

    // MARK: - Lifecycle

    public init(frame: CGRect) {
        self.player = AVPlayer()
        self.betterPlayerView = BetterPlayerView(frame: frame)
        super.init()

        betterPlayerView.player = player
        player.actionAtItemEnd = .none
        if #available(iOS 10.0, *) {
            player.automaticallyWaitsToMinimizeStalling = false
        }
    }

    public func dispose() {
        pause()
        disposeSansEventChannel()
        eventChannel?.setStreamHandler(nil)
        disablePictureInPicture()
        disposed = true
    }

    public func disposeSansEventChannel() {
        do {
            try clear()
        } catch {
            print("BetterPlayer Error: Failed to clear player on dispose - \(error.localizedDescription)")
        }
    }

    private func clear() throws {
        isInitialized = false
        stalledCount = 0
        isStalledCheckStarted = false
        key = nil

        if let currentItem = player.currentItem {
            removeObservers(from: currentItem)
            currentItem.asset.cancelLoading()
        }
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Data Source Management

    public func setDataSourceAsset(
        asset: String,
        key: String,
        certificateUrl: String?,
        licenseUrl: String?,
        cacheKey: String?,
        cacheManager: CacheManager,
        overriddenDuration: Int,
        allowedScreenSleep: Bool
    ) {
        guard let path = Bundle.main.path(forResource: asset, ofType: nil) else {
            eventSink?(FlutterError(code: "AssetNotFound", message: "Asset '\(asset)' not found in app bundle.", details: nil))
            return
        }
        let url = URL(fileURLWithPath: path)
        setDataSourceURL(
            url: url,
            key: key,
            certificateUrl: certificateUrl,
            licenseUrl: licenseUrl,
            headers: [:],
            useCache: false,
            cacheKey: cacheKey,
            cacheManager: cacheManager,
            overriddenDuration: overriddenDuration,
            videoExtension: nil,
            allowedScreenSleep: allowedScreenSleep
        )
    }

    public func setDataSourceURL(
        url: URL,
        key: String,
        certificateUrl: String?,
        licenseUrl: String?,
        headers: [String: String],
        useCache: Bool,
        cacheKey: String?,
        cacheManager: CacheManager,
        overriddenDuration: Int,
        videoExtension: String?,
        allowedScreenSleep: Bool
    ) {
        self.overriddenDuration = 0
        self.cacheManager = cacheManager

        if #available(iOS 12.0, *) {
            player.preventsDisplaySleepDuringVideoPlayback = !allowedScreenSleep
        }

        let playerItem: AVPlayerItem?
        if useCache, let manager = self.cacheManager {
            playerItem = manager.getCachingPlayerItemForNormalPlayback(
                url,
                cacheKey: cacheKey,
                videoExtension: videoExtension,
                headers: headers as [NSObject: AnyObject]
            )
        } else {
            let assetOptions: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
            let asset = AVURLAsset(url: url, options: assetOptions)
            
            if let certURLString = certificateUrl, !certURLString.isEmpty,
               let licURLString = licenseUrl, !licURLString.isEmpty,
               let certificateURL = URL(string: certURLString),
               let licenseURL = URL(string: licURLString) {
                loaderDelegate = BetterPlayerEzDrmAssetsLoaderDelegate(assetURL: url, certificateURL: certificateURL, licenseURL: licenseURL)
                asset.resourceLoader.setDelegate(loaderDelegate, queue: .main)
            }
            playerItem = AVPlayerItem(asset: asset)
        }

        if overriddenDuration > 0 {
            self.overriddenDuration = overriddenDuration
        }

        guard let item = playerItem else {
             eventSink?(FlutterError(code: "PlayerItemError", message: "Failed to create AVPlayerItem.", details: nil))
            return
        }
        setDataSource(playerItem: item, withKey: key)
    }

    private func setDataSource(playerItem: AVPlayerItem, withKey newKey: String) {
        self.key = newKey
        self.stalledCount = 0
        self.isStalledCheckStarted = false
        self.playerRate = 1.0

        if let currentItem = player.currentItem {
            removeObservers(from: currentItem)
        }
        player.replaceCurrentItem(with: playerItem)
        addObservers(to: playerItem)
    }

    // MARK: - Playback Controls

    public func play() {
        stalledCount = 0
        isStalledCheckStarted = false
        updatePlayingState(isPlaying: true)
    }

    public func pause() {
        updatePlayingState(isPlaying: false)
    }

    public func setVolume(_ volume: Double) {
        player.volume = Float(max(0.0, min(1.0, volume)))
    }

    public func seek(to location: Int) {
        let wasPlaying = self.isPlaying
        if wasPlaying {
            player.pause()
        }
        let targetTime = CMTimeMake(value: Int64(location), timescale: 1000)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self = self, finished, wasPlaying else { return }
            self.player.rate = self.playerRate
        }
    }

    public func setSpeed(_ speed: Double, result: FlutterResult) {
        guard let currentItem = player.currentItem else {
            result(FlutterError(code: "no_player_item", message: "Cannot set speed without a player item.", details: nil))
            return
        }

        guard speed >= 0.0 && speed <= 2.0 else {
            result(FlutterError(code: "unsupported_speed", message: "Speed must be between 0.0 and 2.0.", details: nil))
            return
        }

        let isSupportedRate = (speed > 1.0 && currentItem.canPlayFastForward) ||
                              (speed < 1.0 && currentItem.canPlaySlowForward) ||
                              speed == 1.0 || speed == 0.0

        if isSupportedRate {
            playerRate = Float(speed)
            if self.isPlaying {
                player.rate = playerRate
            }
            result(nil)
        } else {
            result(FlutterError(code: "unsupported_rate", message: "The current video does not support the selected playback rate.", details: nil))
        }
    }

    private func updatePlayingState(isPlaying: Bool) {
        guard isInitialized else {
            player.pause()
            return
        }

        if isPlaying {
            if #available(iOS 10.0, *) {
                player.playImmediately(atRate: playerRate)
            } else {
                player.rate = playerRate
            }
        } else {
            player.pause()
        }
    }

    // MARK: - Getters

    public func getPosition() -> Int64 {
        return BetterPlayerTimeUtils.fltCMTimeToMillis(player.currentTime())
    }

    public func getDuration() -> Int64 {
        guard let currentItem = player.currentItem else { return 0 }
        let duration = !CMTIME_IS_INVALID(currentItem.forwardPlaybackEndTime)
            ? currentItem.forwardPlaybackEndTime
            : currentItem.asset.duration
        return BetterPlayerTimeUtils.fltCMTimeToMillis(duration)
    }

    public func getAbsolutePosition() -> Int64 {
        guard let currentDate = player.currentItem?.currentDate() else { return 0 }
        return BetterPlayerTimeUtils.fltNSTimeIntervalToMillis(currentDate.timeIntervalSince1970)
    }

    private func getAvailableDuration() -> TimeInterval {
        guard let timeRange = player.currentItem?.loadedTimeRanges.first?.timeRangeValue else { return 0 }
        return CMTimeGetSeconds(timeRange.start) + CMTimeGetSeconds(timeRange.duration)
    }

    // MARK: - Track & Audio Management

    public func setTrackParameters(width: Int, height: Int, bitrate: Int) {
        guard let currentItem = player.currentItem else { return }
        currentItem.preferredPeakBitRate = Double(bitrate)
        if #available(iOS 11.0, *) {
            let newSize = (width == 0 && height == 0) ? .zero : CGSize(width: width, height: height)
            currentItem.preferredMaximumResolution = newSize
        }
    }

    public func setAudioTrack(name: String, index: Int) {
        guard let audioGroup = player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return }

        let optionToSelect = audioGroup.options.first { option in
            guard let title = option.commonMetadata.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue else { return false }
            return title == name
        }

        if let option = optionToSelect {
            player.currentItem?.select(option, in: audioGroup)
        }
    }

    public func setMixWithOthers(_ mixWithOthers: Bool) {
        let category: AVAudioSession.Category = .playback
        let options: AVAudioSession.CategoryOptions = mixWithOthers ? .mixWithOthers : []
        do {
            try AVAudioSession.sharedInstance().setCategory(category, options: options)
        } catch {
            print("BetterPlayer Error: Failed to set audio session category - \(error.localizedDescription)")
        }
    }

    // MARK: - Stall Recovery

    private func handleStalled() {
        if isStalledCheckStarted { return }
        isStalledCheckStarted = true
        startStalledCheck()
    }

    private func startStalledCheck() {
        guard let currentItem = player.currentItem, isStalledCheckStarted else { return }

        let available = getAvailableDuration()
        let current = CMTimeGetSeconds(currentItem.currentTime())

        if currentItem.isPlaybackLikelyToKeepUp || (available - current > 10.0) {
            isStalledCheckStarted = false
            stalledCount = 0
            play()
        } else {
            stalledCount += 1
            if stalledCount > 60 {
                eventSink?(FlutterError(code: "VideoError", message: "Playback stalled for over a minute.", details: nil))
                isStalledCheckStarted = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startStalledCheck()
            }
        }
    }
}

// MARK: - FlutterPlatformView & StreamHandler
extension BetterPlayer: FlutterPlatformView, FlutterStreamHandler {
    public func view() -> UIView {
        return betterPlayerView
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        if isInitialized {
            sendInitializedEvent()
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}

// MARK: - Key-Value Observing (KVO)
extension BetterPlayer {
    private func addObservers(to item: AVPlayerItem) {
        guard !observersAdded else { return }
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.rate), options: [], context: nil)
        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [], context: nil)
        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.loadedTimeRanges), options: [], context: nil)
        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.presentationSize), options: [], context: nil)
        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.isPlaybackLikelyToKeepUp), options: [], context: nil)
        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.isPlaybackBufferEmpty), options: [], context: nil)
        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.isPlaybackBufferFull), options: [], context: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(itemDidPlayToEndTime), name: .AVPlayerItemDidPlayToEndTime, object: item)
        observersAdded = true
    }

    private func removeObservers(from item: AVPlayerItem) {
        guard observersAdded else { return }
        player.removeObserver(self, forKeyPath: #keyPath(AVPlayer.rate))
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.loadedTimeRanges))
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.presentationSize))
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.isPlaybackLikelyToKeepUp))
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.isPlaybackBufferEmpty))
        item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.isPlaybackBufferFull))

        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
        observersAdded = false
    }

    @objc private func itemDidPlayToEndTime(notification: Notification) {
        if isLooping {
            player.seek(to: .zero)
            player.play()
        } else {
            eventSink?(["event": "completed", "key": key as Any])
        }
    }

    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let item = player.currentItem else { return }

        switch keyPath {
        case #keyPath(AVPlayer.rate):
            if player.rate == 0 && self.isPlaying {
                let currentTime = player.currentTime()
                let duration = item.duration
                
                if currentTime > .zero && currentTime < duration {
                    handleStalled()
                }
            }

        case #keyPath(AVPlayerItem.status):
            if item.status == .readyToPlay {
                if !isInitialized {
                    sendInitializedEvent()
                }
            } else if item.status == .failed {
                let errorMessage = "Failed to load video: \(item.error?.localizedDescription ?? "Unknown error")"
                eventSink?(FlutterError(code: "VideoError", message: errorMessage, details: nil))
            }

        case #keyPath(AVPlayerItem.loadedTimeRanges):
            let ranges = item.loadedTimeRanges.map { value -> [Int64] in
                let range = value.timeRangeValue
                let start = BetterPlayerTimeUtils.fltCMTimeToMillis(range.start)
                var end = start + BetterPlayerTimeUtils.fltCMTimeToMillis(range.duration)
                if !CMTIME_IS_INVALID(item.forwardPlaybackEndTime) {
                    let endTime = BetterPlayerTimeUtils.fltCMTimeToMillis(item.forwardPlaybackEndTime)
                    if end > endTime { end = endTime }
                }
                return [start, end]
            }
            eventSink?(["event": "bufferingUpdate", "values": ranges, "key": key as Any])

        case #keyPath(AVPlayerItem.presentationSize):
            if !isInitialized {
                sendInitializedEvent()
            }

        case #keyPath(AVPlayerItem.isPlaybackBufferEmpty):
            eventSink?(["event": "bufferingStart", "key": key as Any])

        case #keyPath(AVPlayerItem.isPlaybackLikelyToKeepUp), #keyPath(AVPlayerItem.isPlaybackBufferFull):
            if item.isPlaybackLikelyToKeepUp {
                updatePlayingState(isPlaying: self.isPlaying)
                eventSink?(["event": "bufferingEnd", "key": key as Any])
            }

        default:
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func sendInitializedEvent() {
        guard !isInitialized, let key = self.key, let item = player.currentItem, player.status == .readyToPlay else {
            return
        }

        guard let track = item.asset.tracks(withMediaType: .video).first,
              track.naturalSize.width > 0, track.naturalSize.height > 0 else {
            return
        }

        let size = track.naturalSize.applying(track.preferredTransform)
        let width = abs(size.width)
        let height = abs(size.height)

        let durationMillis = getDuration()
        if overriddenDuration > 0 && durationMillis > Int64(overriddenDuration) {
            item.forwardPlaybackEndTime = CMTimeMake(value: Int64(overriddenDuration), timescale: 1000)
        }
        
        isInitialized = true
        updatePlayingState(isPlaying: self.isPlaying)

        eventSink?([
            "event": "initialized",
            "key": key,
            "duration": getDuration(),
            "width": width,
            "height": height,
        ])
    }
}
// MARK: - Picture-in-Picture (PiP) Delegate
@available(iOS 9.0, *)
extension BetterPlayer: AVPictureInPictureControllerDelegate {
    public func enablePictureInPicture(frame: CGRect) {
        disablePictureInPicture()
        usePlayerLayer(frame: frame)
    }

    public func disablePictureInPicture() {
        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        if playerLayer != nil {
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            eventSink?(["event": "pipStop"])
        }
    }

    public func setPictureInPicture(enabled: Bool) {
        self.pictureInPicture = enabled
        guard let pip = pipController else { return }

        DispatchQueue.main.async {
            if enabled && !pip.isPictureInPictureActive {
                pip.startPictureInPicture()
            } else if !enabled && pip.isPictureInPictureActive {
                pip.stopPictureInPicture()
            }
        }
    }

    private func usePlayerLayer(frame: CGRect) {
        guard let rootVC = UIApplication.shared.keyWindow?.rootViewController else { return }
        playerLayer = AVPlayerLayer(player: player)
        playerLayer!.frame = frame
        rootVC.view.layer.addSublayer(playerLayer!)
        setupPipController()

        // Delay to ensure the layer is ready before starting PiP.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.setPictureInPicture(enabled: true)
        }
    }

    private func setupPipController() {
        guard AVPictureInPictureController.isPictureInPictureSupported(), let layer = playerLayer else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("BetterPlayer Error: Failed to set audio session active for PiP - \(error.localizedDescription)")
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()

        pipController = AVPictureInPictureController(playerLayer: layer)
        pipController?.delegate = self
    }

    // Delegate Callbacks
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        eventSink?(["event": "pipStart"])
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        disablePictureInPicture()
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // This handler should be used to restore the UI when PiP stops.
        restoreUserInterfaceForPIPStopCompletionHandler?(true)
        restoreUserInterfaceForPIPStopCompletionHandler = nil
        completionHandler(true)
    }
}