import AVKit
import Cache
import GCDWebServer
import HLSCachingReverseProxyServer
import PINCache

@objc public class CacheManager: NSObject {
    // MARK: - Shared State (Thread-Safe)
    private let queue = DispatchQueue(
        label: "com.betterplayer.cachemanager", attributes: .concurrent)
    private var _preCachedURLs = [String: CachingPlayerItem]()
    private var _existsInStorage: Bool = false

    // Atomic access to `_preCachedURLs`
    private var preCachedURLs: [String: CachingPlayerItem] {
        get { queue.sync { _preCachedURLs } }
        set { queue.async(flags: .barrier) { self._preCachedURLs = newValue } }
    }

    // MARK: - Config
    var completionHandler: ((_ success: Bool) -> Void)?
    var diskConfig = DiskConfig(
        name: "BetterPlayerCache",
        expiry: .date(Date().addingTimeInterval(3600 * 24 * 30)),
        maxSize: 100 * 1024 * 1024
    )

    let memoryConfig = MemoryConfig(
        expiry: .never,
        countLimit: 0,
        totalCostLimit: 0
    )

    // MARK: - Server & Storage
    private var server: HLSCachingReverseProxyServer?
    private lazy var storage: Storage<String, Data>? = {
        try? Storage<String, Data>(
            diskConfig: diskConfig,
            memoryConfig: memoryConfig,
            transformer: TransformerFactory.forCodable(ofType: Data.self)
        )
    }()

    // MARK: - Setup (Thread-Safe)
    private static let setupOnce: Void = {
        GCDWebServer.setLogLevel(4)
    }()

    @objc public func setup() {
        let cache = PINCache(name: "BetterPlayerCache")
        do {
            _ = CacheManager.setupOnce  // Ensures setup runs only once
            let webServer = GCDWebServer()

            let urlSession = URLSession.shared
            server = HLSCachingReverseProxyServer(
                webServer: webServer, urlSession: urlSession, cache: cache)
            server?.start(port: 8080)
        } catch {
            print("Error setting up cache directory: \(error)")
            // You might want to handle this failure, e.g., by disabling caching
        }
    }

    // MARK: - Public Methods (Thread-Safe)
    @objc public func setMaxCacheSize(_ maxCacheSize: NSNumber?) {
        if let maxSize = maxCacheSize?.uintValue {
            diskConfig = DiskConfig(
                name: "BetterPlayerCache",
                expiry: .date(Date().addingTimeInterval(3600 * 24 * 30)),
                maxSize: maxSize
            )
        }
    }

    @objc public func preCacheURL(
        _ url: URL,
        cacheKey: String?,
        videoExtension: String?,
        withHeaders headers: [NSObject: AnyObject],
        completionHandler: ((_ success: Bool) -> Void)?
    ) {
        let key = cacheKey ?? url.absoluteString

        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            // Check if already downloading
            if self._preCachedURLs[key] == nil {
                if let item = self.getCachingPlayerItem(
                    url, cacheKey: key, videoExtension: videoExtension, headers: headers)
                {
                    if !self._existsInStorage {
                        self._preCachedURLs[key] = item
                        item.download()
                    } else {
                        DispatchQueue.main.async {
                            completionHandler?(true)
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        completionHandler?(false)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completionHandler?(true)
                }
            }
        }
    }

    @objc public func stopPreCache(
        _ url: URL,
        cacheKey: String?,
        completionHandler: ((_ success: Bool) -> Void)?
    ) {
        let key = cacheKey ?? url.absoluteString

        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            if let playerItem = self._preCachedURLs[key] {
                playerItem.stopDownload()
                self._preCachedURLs.removeValue(forKey: key)
                DispatchQueue.main.async {
                    completionHandler?(true)
                }
            } else {
                DispatchQueue.main.async {
                    completionHandler?(false)
                }
            }
        }
    }

    @objc public func getCachingPlayerItemForNormalPlayback(
        _ url: URL,
        cacheKey: String?,
        videoExtension: String?,
        headers: [NSObject: AnyObject]
    ) -> AVPlayerItem? {
        let mimeTypeResult = getMimeType(url: url, explicitVideoExtension: videoExtension)
        if mimeTypeResult.1 == "application/vnd.apple.mpegurl" {
            guard let reverseProxyURL = server?.reverseProxyURL(from: url) else { return nil }
            return AVPlayerItem(url: reverseProxyURL)
        } else {
            return getCachingPlayerItem(
                url, cacheKey: cacheKey, videoExtension: videoExtension, headers: headers)
        }
    }

    // MARK: - Private Methods
    private func getCachingPlayerItem(
        _ url: URL,
        cacheKey: String?,
        videoExtension: String?,
        headers: [NSObject: AnyObject]
    ) -> CachingPlayerItem? {
        let key = cacheKey ?? url.absoluteString
        let playerItem: CachingPlayerItem

        // Check pre-cached items first
        if let preCachedItem = queue.sync(execute: { _preCachedURLs[key] }) {
            queue.async(flags: .barrier) { [weak self] in
                self?._preCachedURLs.removeValue(forKey: key)
            }
            playerItem = preCachedItem
        } else {
            // Check storage
            let data = try? storage?.object(forKey: key)
            if let data = data {
                _existsInStorage = true
                let mimeTypeResult = getMimeType(url: url, explicitVideoExtension: videoExtension)
                if mimeTypeResult.1.isEmpty {
                    NSLog(
                        "Cache error: couldn't find mime type for url: \(url.absoluteURL). Video will play without cache."
                    )
                    playerItem = CachingPlayerItem(url: url, cacheKey: key, headers: headers)
                } else {
                    playerItem = CachingPlayerItem(
                        data: data, mimeType: mimeTypeResult.1, fileExtension: mimeTypeResult.0)
                }
            } else {
                _existsInStorage = false
                playerItem = CachingPlayerItem(url: url, cacheKey: key, headers: headers)
            }
        }

        playerItem.delegate = self
        return playerItem
    }

    @objc public func clearCache() {
        queue.async(flags: .barrier) { [weak self] in
            try? self?.storage?.removeAll()
            self?._preCachedURLs.removeAll()
        }
    }

    private func getMimeType(url: URL, explicitVideoExtension: String?) -> (String, String) {
        var videoExtension = url.pathExtension
        if explicitVideoExtension != nil {
            videoExtension = explicitVideoExtension!
        }
        var mimeType = ""
        switch videoExtension {
        case "m3u":
            mimeType = "application/vnd.apple.mpegurl"
        case "m3u8":
            mimeType = "application/vnd.apple.mpegurl"
        case "3gp":
            mimeType = "video/3gpp"
        case "mp4":
            mimeType = "video/mp4"
        case "m4a":
            mimeType = "video/mp4"
        case "m4p":
            mimeType = "video/mp4"
        case "m4b":
            mimeType = "video/mp4"
        case "m4r":
            mimeType = "video/mp4"
        case "m4v":
            mimeType = "video/mp4"
        case "m1v":
            mimeType = "video/mpeg"
        case "mpg":
            mimeType = "video/mpeg"
        case "mp2":
            mimeType = "video/mpeg"
        case "mpeg":
            mimeType = "video/mpeg"
        case "mpe":
            mimeType = "video/mpeg"
        case "mpv":
            mimeType = "video/mpeg"
        case "ogg":
            mimeType = "video/ogg"
        case "mov":
            mimeType = "video/quicktime"
        case "qt":
            mimeType = "video/quicktime"
        case "webm":
            mimeType = "video/webm"
        case "asf":
            mimeType = "video/ms-asf"
        case "wma":
            mimeType = "video/ms-asf"
        case "wmv":
            mimeType = "video/ms-asf"
        case "avi":
            mimeType = "video/x-msvideo"
        default:
            mimeType = ""
        }

        return (videoExtension, mimeType)
    }

    ///Checks wheter pre cache is supported for given url.
    @objc public func isPreCacheSupported(url: URL, videoExtension: String?) -> Bool {
        let mimeTypeResult = getMimeType(url: url, explicitVideoExtension: videoExtension)
        return !mimeTypeResult.1.isEmpty && mimeTypeResult.1 != "application/vnd.apple.mpegurl"
    }
}

// MARK: - CachingPlayerItemDelegate
extension CacheManager: CachingPlayerItemDelegate {
    public func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingData data: Data) {
        storage?.async.setObject(data, forKey: playerItem.cacheKey ?? playerItem.url.absoluteString)
        { _ in }
        DispatchQueue.main.async { [weak self] in
            self?.completionHandler?(true)
        }
    }

    public func playerItem(
        _ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int,
        outOf bytesExpected: Int
    ) {
        // Optional: Update progress on main thread if needed
    }

    public func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.completionHandler?(false)
        }
    }
}
