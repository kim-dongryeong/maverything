import AppKit
import Foundation

struct AppUpdateInfo: Equatable {
    var version: String
    var tag: String
    var title: String
    var releaseURL: URL
    var downloadURL: URL
    var publishedAt: String?
    var notes: String?
}

enum AppUpdateChecker {
    static let repository = "kim-dongryeong/maverything"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    static func fetchLatestRelease() async throws -> AppUpdateInfo {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("Maverything/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw UpdateError.noPublishedReleases
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let releaseURL = URL(string: release.htmlURL) else { throw UpdateError.badResponse }
        let dmg = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let downloadURL = dmg.flatMap { URL(string: $0.browserDownloadURL) } ?? releaseURL
        return AppUpdateInfo(
            version: normalizedVersion(release.tagName),
            tag: release.tagName,
            title: release.name ?? release.tagName,
            releaseURL: releaseURL,
            downloadURL: downloadURL,
            publishedAt: release.publishedAt,
            notes: release.body
        )
    }

    static func isNewer(_ latest: String, than current: String = currentVersion) -> Bool {
        let lhs = versionParts(latest)
        let rhs = versionParts(current)
        let n = max(lhs.count, rhs.count)
        for i in 0..<n {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func normalizedVersion(_ tagOrVersion: String) -> String {
        tagOrVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private static func versionParts(_ value: String) -> [Int] {
        let clean = normalizedVersion(value).split(separator: "-", maxSplits: 1).first ?? ""
        return clean.split(separator: ".").map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: String
        let body: String?
        let publishedAt: String?
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case body
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum UpdateError: LocalizedError {
        case noPublishedReleases
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noPublishedReleases:
                return "No GitHub Releases have been published yet."
            case .badResponse:
                return "GitHub returned an unexpected response."
            }
        }
    }
}
