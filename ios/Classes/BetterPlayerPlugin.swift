import Flutter
import AVFoundation
import AVKit // <-- FIX 1: Added missing import for AVPictureInPictureController
import MediaPlayer

// MARK: - BetterPlayerPlugin

public final class BetterPlayerPlugin: NSObject, FlutterPlugin {

    // MARK: - Properties

    private let registrar: FlutterPluginRegistrar
    private let messenger: FlutterBinaryMessenger
    private var players: [Int64: BetterPlayer] = [:]
    private var dataSources: [Int64: [String: Any]] = [:]
    private var timeObserverIds: [Int64: Any] = [:]
    private var artworkImages: [Int64: MPMediaItemArtwork] = [:]
    private let cacheManager: CacheManager
    private var texturesCount: Int64 = -1
    private weak var notificationPlayer: BetterPlayer?
    private var remoteCommandsInitialized = false

    // MARK: - FlutterPlugin Conformance

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "better_player_channel", binaryMessenger: registrar.messenger())
        let instance = BetterPlayerPlugin(registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: channel)

        let viewFactory = BetterPlayerViewFactory(messenger: registrar.messenger(), players: instance.players)
        registrar.register(viewFactory, withId: "com.jhomlala/better_player")
    }

    public init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
        self.messenger = registrar.messenger()
        self.cacheManager = CacheManager()
        super.init()
        self.cacheManager.setup()
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        players.values.forEach { $0.disposeSansEventChannel() }
        players.removeAll()
    }

    // MARK: - Method Call Handling

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "init":
            players.values.forEach { $0.dispose() }
            players.removeAll()
            result(nil)

        case "create":
            let player = BetterPlayer(frame: .zero)
            onPlayerSetup(player: player, result: result)

        case "isPictureInPictureSupported":
            result(AVPictureInPictureController.isPictureInPictureSupported())

        default:
            guard let args = call.arguments as? [String: Any],
                  let textureId = args["textureId"] as? Int64,
                  let player = players[textureId] else {
                result(FlutterError(code: "PlayerNotFound", message: "Player for textureId not found", details: nil))
                return
            }
            handlePlayerMethodCall(call, player: player, args: args, result: result)
        }
    }

    private func handlePlayerMethodCall(_ call: FlutterMethodCall, player: BetterPlayer, args: [String: Any], result: @escaping FlutterResult) {
        switch call.method {
        case "setDataSource":
            handleSetDataSource(player: player, args: args, result: result)

        case "play":
            setupRemoteNotification(for: player)
            player.play()
            result(nil)

        case "pause":
            player.pause()
            result(nil)

        case "setLooping":
            let isLooping = args["looping"] as? Bool ?? false
            // FIX 2: Changed from method call to property assignment
            player.isLooping = isLooping
            result(nil)

        case "setVolume":
            let volume = args["volume"] as? Double ?? 1.0
            player.setVolume(volume)
            result(nil)

        case "seekTo":
            let location = args["location"] as? Int ?? 0
            player.seek(to: location)
            result(nil)

        case "position":
            result(player.getPosition())

        case "absolutePosition":
            result(player.getAbsolutePosition())
            
        case "setSpeed":
            let speed = args["speed"] as? Double ?? 1.0
            player.setSpeed(speed, result: result)

        case "setTrackParameters":
            let width = args["width"] as? Int ?? 0
            let height = args["height"] as? Int ?? 0
            let bitrate = args["bitrate"] as? Int ?? 0
            player.setTrackParameters(width: width, height: height, bitrate: bitrate)
            result(nil)

        case "enablePictureInPicture":
            let left = args["left"] as? Double ?? 0
            let top = args["top"] as? Double ?? 0
            let width = args["width"] as? Double ?? 1
            let height = args["height"] as? Double ?? 1
            player.enablePictureInPicture(frame: CGRect(x: left, y: top, width: width, height: height))
            result(nil)

        case "disablePictureInPicture":
            player.disablePictureInPicture()
            result(nil)

        case "setAudioTrack":
            if let name = args["name"] as? String, let index = args["index"] as? Int {
                player.setAudioTrack(name: name, index: index)
            }
            result(nil)

        case "setMixWithOthers":
            let mix = args["mixWithOthers"] as? Bool ?? false
            player.setMixWithOthers(mix)
            result(nil)

        case "preCache":
            handlePreCache(args: args, result: result)
            
        case "stopPreCache":
            handleStopPreCache(args: args, result: result)

        case "clearCache":
            cacheManager.clearCache()
            result(nil)
            
        case "dispose":
            handleDispose(player: player, textureId: args["textureId"] as! Int64, result: result)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Private Handler Implementations
    
    private func onPlayerSetup(player: BetterPlayer, result: FlutterResult) {
        texturesCount += 1
        let textureId = texturesCount
        
        let eventChannel = FlutterEventChannel(
            name: "better_player_channel/videoEvents\(textureId)",
            binaryMessenger: messenger
        )
        eventChannel.setStreamHandler(player)
        player.eventChannel = eventChannel
        
        players[textureId] = player
        result(["textureId": textureId])
    }

    private func handleSetDataSource(player: BetterPlayer, args: [String: Any], result: FlutterResult) {
        guard let dataSource = args["dataSource"] as? [String: Any] else {
            result(FlutterError(code: "InvalidDataSource", message: "Data source is not a valid map.", details: nil))
            return
        }

        let textureId = args["textureId"] as! Int64
        dataSources[textureId] = dataSource
        // FIX 3: Removed illegal call to private 'clear' method.
        // The `setDataSource` method on the player itself handles resetting state.
        
        let asset = dataSource["asset"] as? String
        let uri = dataSource["uri"] as? String
        let key = dataSource["key"] as? String ?? ""
        let certificateUrl = dataSource["certificateUrl"] as? String
        let licenseUrl = dataSource["licenseUrl"] as? String
        let headers = dataSource["headers"] as? [String: String] ?? [:]
        let useCache = dataSource["useCache"] as? Bool ?? false
        let maxCacheSize = dataSource["maxCacheSize"] as? NSNumber
        let cacheKey = dataSource["cacheKey"] as? String
        let videoExtension = dataSource["videoExtension"] as? String
        let overriddenDuration = dataSource["overriddenDuration"] as? Int ?? 0
        let allowedScreenSleep = dataSource["allowedScreenSleep"] as? Bool ?? true
        
        if useCache {
            cacheManager.setMaxCacheSize(maxCacheSize)
        }

        if let asset = asset {
            let assetPath: String
            if let package = dataSource["package"] as? String {
                assetPath = registrar.lookupKey(forAsset: asset, fromPackage: package)
            } else {
                assetPath = registrar.lookupKey(forAsset: asset)
            }
            player.setDataSourceAsset(
                asset: assetPath, key: key, certificateUrl: certificateUrl, licenseUrl: licenseUrl,
                cacheKey: cacheKey, cacheManager: cacheManager, overriddenDuration: overriddenDuration,
                allowedScreenSleep: allowedScreenSleep
            )
        } else if let uri = uri, let url = URL(string: uri) {
            player.setDataSourceURL(
                url: url, key: key, certificateUrl: certificateUrl, licenseUrl: licenseUrl,
                headers: headers, useCache: useCache, cacheKey: cacheKey,
                cacheManager: cacheManager, overriddenDuration: overriddenDuration,
                videoExtension: videoExtension, allowedScreenSleep: allowedScreenSleep
            )
        } else {
            result(FlutterError(code: "InvalidDataSource", message: "No valid asset or uri found in data source.", details: nil))
            return
        }
        result(nil)
    }
    
    private func handleDispose(player: BetterPlayer, textureId: Int64, result: FlutterResult) {
        disposeNotificationData(for: player)
        setRemoteCommandsNotification(active: false)
        
        players.removeValue(forKey: textureId)
        dataSources.removeValue(forKey: textureId)
        
        // Delay disposal to prevent crashes during texture unregistering.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !player.disposed {
                player.dispose()
            }
        }
        
        if players.isEmpty {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        result(nil)
    }

    private func handlePreCache(args: [String: Any], result: FlutterResult) {
        guard let dataSource = args["dataSource"] as? [String: Any],
              let urlString = dataSource["uri"] as? String,
              let url = URL(string: urlString) else {
            result(nil)
            return
        }
        
        let headers = dataSource["headers"] as? [String: String] ?? [:]
        let maxCacheSize = dataSource["maxCacheSize"] as? NSNumber
        let cacheKey = dataSource["cacheKey"] as? String
        let videoExtension = dataSource["videoExtension"] as? String

        if cacheManager.isPreCacheSupported(url: url, videoExtension: videoExtension) { // FIX 4: Corrected argument label
            cacheManager.setMaxCacheSize(maxCacheSize)
            // FIX 5: Corrected argument label & cast dictionary type
            cacheManager.preCacheURL(url, cacheKey: cacheKey, videoExtension: videoExtension, withHeaders: headers as [NSObject: AnyObject]) { _ in }
        } else {
            print("Pre-cache is not supported for the given data source.")
        }
        result(nil)
    }
    
    private func handleStopPreCache(args: [String: Any], result: FlutterResult) {
        guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
            result(nil)
            return
        }
        
        let cacheKey = args["cacheKey"] as? String
        let videoExtension = args["videoExtension"] as? String
        
        if cacheManager.isPreCacheSupported(url: url, videoExtension: videoExtension) { // FIX 6: Corrected argument label
            cacheManager.stopPreCache(url, cacheKey: cacheKey) { _ in }
        } else {
            print("Stop pre-cache is not supported for the given data source.")
        }
        result(nil)
    }

    // MARK: - Remote Notifications & Commands

    private func setupRemoteNotification(for player: BetterPlayer) {
        notificationPlayer = player
        stopOtherUpdateListeners(for: player)
        
        guard let textureId = getTextureId(for: player),
              let dataSource = dataSources[textureId],
              let showNotification = dataSource["showNotification"] as? Bool, showNotification else {
            return
        }
        
        let title = dataSource["title"] as? String
        let author = dataSource["author"] as? String
        let imageUrl = dataSource["imageUrl"] as? String
        
        setRemoteCommandsNotification(active: true)
        setupRemoteCommands()
        updateRemoteCommandNotification(for: player, title: title, author: author, imageUrl: imageUrl)
        setupUpdateListener(for: player, title: title, author: author, imageUrl: imageUrl)
    }
    
    private func setRemoteCommandsNotification(active: Bool) {
        do {
            try AVAudioSession.sharedInstance().setActive(active, options: [])
        } catch {
            print("Failed to set audio session active: \(error)")
        }

        if active {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } else if players.isEmpty {
            UIApplication.shared.endReceivingRemoteControlEvents()
        }
    }

    private func setupRemoteCommands() {
        if remoteCommandsInitialized { return }
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.notificationPlayer?.eventSink?(["event": "play"])
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.notificationPlayer?.eventSink?(["event": "pause"])
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            if self?.notificationPlayer?.isPlaying == true {
                self?.notificationPlayer?.eventSink?(["event": "pause"])
            } else {
                self?.notificationPlayer?.eventSink?(["event": "play"])
            }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let player = self.notificationPlayer,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let millis = Int(event.positionTime * 1000)
            player.seek(to: millis)
            player.eventSink?(["event": "seek", "position": millis])
            return .success
        }
        remoteCommandsInitialized = true
    }

    private func updateRemoteCommandNotification(for player: BetterPlayer, title: String?, author: String?, imageUrl: String?) {
        guard let textureId = getTextureId(for: player) else { return }
        
        let positionSeconds = Double(player.getPosition()) / 1000.0
        let durationSeconds = Double(player.getDuration()) / 1000.0

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyArtist: author ?? "",
            MPMediaItemPropertyTitle: title ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: positionSeconds,
            MPMediaItemPropertyPlaybackDuration: durationSeconds,
            // FIX 7: Made playerRate publicly readable
            MPNowPlayingInfoPropertyPlaybackRate: player.playerRate,
        ]

        if let imageUrl = imageUrl {
            if let artwork = artworkImages[textureId] {
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            } else {
                // Fetch image asynchronously
                DispatchQueue.global().async {
                    guard let url = URL(string: imageUrl), let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                        return
                    }
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    
                    DispatchQueue.main.async {
                        self.artworkImages[textureId] = artwork
                        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                    }
                }
            }
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }
    
    private func setupUpdateListener(for player: BetterPlayer, title: String?, author: String?, imageUrl: String?) {
        guard let textureId = getTextureId(for: player) else { return }

        let timeObserverId = player.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: nil) { [weak self] _ in
            self?.updateRemoteCommandNotification(for: player, title: title, author: author, imageUrl: imageUrl)
        }
        timeObserverIds[textureId] = timeObserverId
    }

    private func disposeNotificationData(for player: BetterPlayer) {
        if player === notificationPlayer {
            notificationPlayer = nil
        }
        guard let textureId = getTextureId(for: player) else { return }
        
        if let timeObserverId = timeObserverIds[textureId] {
            player.player.removeTimeObserver(timeObserverId)
            timeObserverIds.removeValue(forKey: textureId)
        }
        artworkImages.removeValue(forKey: textureId)
        
        // Clear now playing info if this was the notification player
        if notificationPlayer == nil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [:]
        }
    }
    
    private func stopOtherUpdateListeners(for player: BetterPlayer) {
        guard let currentPlayerId = getTextureId(for: player) else { return }
        
        let otherObserverIds = timeObserverIds.filter { $0.key != currentPlayerId }
        otherObserverIds.forEach { textureId, observerId in
            if let playerToStop = players[textureId] {
                playerToStop.player.removeTimeObserver(observerId)
            }
        }
        
        let newTimeObserverIds = timeObserverIds.filter { $0.key == currentPlayerId }
        self.timeObserverIds = newTimeObserverIds
    }
    
    private func getTextureId(for player: BetterPlayer) -> Int64? {
        return players.first(where: { $0.value === player })?.key
    }
}

// MARK: - BetterPlayerViewFactory

public final class BetterPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger
    private var players: [Int64: BetterPlayer]

    init(messenger: FlutterBinaryMessenger, players: [Int64: BetterPlayer]) {
        self.messenger = messenger
        self.players = players
        super.init()
    }
    
    public func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        guard let args = args as? [String: Any],
              let textureId = args["textureId"] as? Int64,
              let player = players[textureId] else {
            // Return a dummy view if the player isn't found, though this should not happen in a correct flow.
            return DummyPlatformView()
        }
        return player
    }

    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}


// A fallback view in case of an error during view creation.
fileprivate class DummyPlatformView: NSObject, FlutterPlatformView {
    func view() -> UIView {
        return UIView()
    }
}