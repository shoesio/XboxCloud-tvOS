import Foundation

/// Per-app identity; both launchers compile the same streaming implementation.
/// Defaults preserve the original Fortnite build and its existing saved data.
enum DirectGameConfiguration {
    static let isRecentGamesLauncher = Bundle.main.object(forInfoDictionaryKey: "XCloudRecentGamesLauncher") as? Bool ?? false
    static let title = Bundle.main.object(forInfoDictionaryKey: "DirectGameTitle") as? String ?? "Fortnite"
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? title
    static let productID = Bundle.main.object(forInfoDictionaryKey: "DirectGameProductID") as? String
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "DirectGameAppGroup") as? String
        ?? "group.com.josephhewes.CloudNowAppTV"
    static let urlScheme = Bundle.main.object(forInfoDictionaryKey: "DirectGameURLScheme") as? String ?? "cloudnow"
    static let fallbackArtwork = Bundle.main.object(forInfoDictionaryKey: "DirectGameFallbackArtwork") as? String
    static let cachePrefix = Bundle.main.object(forInfoDictionaryKey: "DirectGameCachePrefix") as? String ?? "fortnite"
    static var bannerFilename: String {
        if isRecentGamesLauncher {
            let id = UserDefaults.standard.string(forKey: "xcloud.selectedTitleID") ?? "default"
            let safeID = id.utf8.map { String(format: "%02x", $0) }.joined()
            return "xcloud-\(safeID).jpg"
        }
        return cachePrefix == "fortnite" ? "FortniteBanner.jpg" : "\(cachePrefix)Banner.jpg"
    }

    static func matches(_ game: XCloudGame) -> Bool {
        if let productID, game.productID.caseInsensitiveCompare(productID) == .orderedSame { return true }
        return game.title.caseInsensitiveCompare(title) == .orderedSame
    }
}
