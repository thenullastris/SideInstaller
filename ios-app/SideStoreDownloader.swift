import Foundation

/// Downloads the latest SideStore release IPA from GitHub into Documents.
enum SideStoreDownloader {

    struct GHAsset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int
    }
    struct GHRelease: Decodable {
        let tag_name: String
        let assets: [GHAsset]
    }

    enum DownloadError: Error, CustomStringConvertible {
        case noIPAAsset
        case badURL
        var description: String {
            switch self {
            case .noIPAAsset: return "no .ipa asset in the latest SideStore release"
            case .badURL: return "bad asset URL"
            }
        }
    }

    /// Returns the local path of the downloaded IPA. `log` receives progress.
    static func downloadLatest(log: @escaping (String) -> Void) async throws -> String {
        let api = URL(string: "https://api.github.com/repos/SideStore/SideStore/releases/latest")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SideInstaller", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: req)
        let release = try JSONDecoder().decode(GHRelease.self, from: data)
        log("Latest SideStore release: \(release.tag_name) with \(release.assets.count) assets")

        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".ipa") }) else {
            throw DownloadError.noIPAAsset
        }
        guard let assetURL = URL(string: asset.browser_download_url) else {
            throw DownloadError.badURL
        }
        log("Downloading \(asset.name) (\(asset.size) bytes) …")

        let (tmp, response) = try await URLSession.shared.download(from: assetURL)
        if let http = response as? HTTPURLResponse {
            log("HTTP \(http.statusCode) for \(asset.name)")
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent("SideStore.ipa")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest.path
    }
}
