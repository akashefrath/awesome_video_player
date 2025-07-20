import AVFoundation

// MARK: - BetterPlayerEzDrmAssetsLoaderDelegate

@available(iOS 9.0, *)
public final class BetterPlayerEzDrmAssetsLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

    // MARK: - Properties

    private let assetURL: URL
    private let licenseURL: URL
    private let certificateURL: URL

    // MARK: - Initialization

    /// Initializes the DRM assets loader delegate.
    ///
    /// - Parameters:
    ///   - assetURL: The URL of the video asset. Used to generate the content identifier.
    ///   - certificateURL: The URL to your FairPlay application certificate.
    ///   - licenseURL: The URL to your DRM license server.
    public init(assetURL: URL, certificateURL: URL, licenseURL: URL) {
        self.assetURL = assetURL
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        super.init()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    /// This is the core method where the DRM license exchange happens.
    /// It's called by the AVPlayer when it needs a key to decrypt the content.
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: DrmError.noRequestURL)
            return false
        }

        // The system asks for the key using a custom scheme, typically "skd".
        guard url.scheme == "skd" else {
            loadingRequest.finishLoading(with: DrmError.invalidScheme)
            return false
        }

        // 1. Get the Application Certificate from your server or local storage.
        guard let certificateData = fetchCertificate() else {
            loadingRequest.finishLoading(with: DrmError.noCertificateData)
            return false
        }
        
        // The asset ID is needed for the license request. Here we extract it from the skd:// URL.
        // This logic may need to be adapted based on your specific URL structure.
        let assetId = url.host ?? ""

        // 2. Request the Server Playback Context (SPC) from the system.
        // This is an encrypted payload that can only be decrypted by your license server.
        do {
            let spcData = try loadingRequest.streamingContentKeyRequestData(
                forApp: certificateData,
                contentIdentifier: assetId.data(using: .utf8)!,
                options: nil
            )

            // 3. Send the SPC to the license server to get the Content Key Context (CKC).
            fetchCkc(spc: spcData, for: loadingRequest)

        } catch {
            loadingRequest.finishLoading(with: error)
            return false
        }

        // Return true to indicate that we are handling this request asynchronously.
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest) -> Bool {
        // This delegate method is called for license renewals.
        // The process is the same as the initial request.
        return self.resourceLoader(resourceLoader, shouldWaitForLoadingOfRequestedResource: renewalRequest)
    }

    // MARK: - Private Helper Methods

    /// Fetches the FairPlay application certificate.
    private func fetchCertificate() -> Data? {
        do {
            return try Data(contentsOf: self.certificateURL)
        } catch {
            print("BetterPlayer DRM Error: Failed to fetch certificate data - \(error.localizedDescription)")
            return nil
        }
    }

    /// Makes an asynchronous network request to the license server.
    private func fetchCkc(spc: Data, for loadingRequest: AVAssetResourceLoadingRequest) {
        var request = URLRequest(url: self.licenseURL)
        request.httpMethod = "POST"
        request.httpBody = spc
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    loadingRequest.finishLoading(with: error)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    loadingRequest.finishLoading(with: DrmError.invalidServerResponse(response))
                    return
                }

                guard let ckcData = data else {
                    loadingRequest.finishLoading(with: DrmError.noCkcData)
                    return
                }

                // 4. Provide the CKC to the loading request to decrypt the content.
                loadingRequest.dataRequest?.respond(with: ckcData)
                loadingRequest.finishLoading()
            }
        }
        task.resume()
    }
}

// MARK: - Custom DRM Errors
extension BetterPlayerEzDrmAssetsLoaderDelegate {
    enum DrmError: Error, LocalizedError {
        case noRequestURL
        case invalidScheme
        case noCertificateData
        case invalidServerResponse(URLResponse?)
        case noCkcData

        var errorDescription: String? {
            switch self {
            case .noRequestURL:
                return "DRM key request had no URL."
            case .invalidScheme:
                return "DRM key request had an invalid scheme."
            case .noCertificateData:
                return "Failed to load the FairPlay application certificate."
            case .invalidServerResponse:
                return "License server returned an invalid response."
            case .noCkcData:
                return "License server returned no CKC data."
            }
        }
    }
}