import Foundation
import TVServices
import UIKit

struct TopShelfHeroSnapshot: Codable {
    let savedAt: Date
    let items: [TopShelfHeroItem]
}

struct TopShelfHeroItem: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let provider: String
    let imageURL: String?
    let fallbackImageURL: String?
    let playURL: String
    let displayURL: String
    var summary: String? = nil
    var genres: [String]? = nil
    var releaseDate: String? = nil
    var releaseYear: Int? = nil
    var developer: String? = nil
    var publisher: String? = nil
}

enum TopShelfHeroStore {
    static let appGroupIdentifier = DirectGameConfiguration.appGroup
    static let storageKey = "topShelf.heroSnapshot"
    static let artworkChanged = Notification.Name("FortniteArtworkChanged")

    static var firstRecentGameID: String? {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(TopShelfHeroSnapshot.self, from: data),
              let id = snapshot.items.first?.id, id.hasPrefix("xcloud:") else { return nil }
        return String(id.dropFirst(7))
    }

    static var cachedFortniteArtworkURL: URL? {
        guard let url = artworkFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static var artworkFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(DirectGameConfiguration.bannerFilename)
    }

    /// Revalidate even unchanged URLs: Xbox can replace the image at the same address.
    static func refreshFortniteArtwork(for game: GameInfo) async {
        guard !Task.isCancelled else { return }
        guard let remote = heroImageURL(for: game) else {
            FortniteDiagnostics.record("artwork: no hero URL in catalog")
            return
        }
        defaults.set(remote.absoluteString, forKey: "\(DirectGameConfiguration.cachePrefix).bannerSourceURL")
        await downloadFortniteArtwork(from: remote)
        if !DirectGameConfiguration.isRecentGamesLauncher { saveHeroes([game]) }
    }

    static func refreshSavedFortniteArtwork() async {
        guard !DirectGameConfiguration.isRecentGamesLauncher else { return }
        guard cachedFortniteArtworkURL == nil else { return }
        let snapshot = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode(TopShelfHeroSnapshot.self, from: $0)
        }
        guard let raw = defaults.string(forKey: "\(DirectGameConfiguration.cachePrefix).bannerSourceURL")
                ?? snapshot?.items.first(where: { $0.title.caseInsensitiveCompare(DirectGameConfiguration.title) == .orderedSame })?.imageURL,
              let remote = URL(string: raw), remote.scheme == "https" else { return }
        await downloadFortniteArtwork(from: remote)
    }

    private static func downloadFortniteArtwork(from remote: URL) async {
        guard let destination = artworkFileURL else {
            FortniteDiagnostics.record("artwork: shared container unavailable")
            return
        }
        do {
            FortniteDiagnostics.record("artwork: download started")
            let request = URLRequest(url: remote, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse else { return }
            FortniteDiagnostics.record("artwork: HTTP \(http.statusCode), bytes=\(data.count)")
            guard (200...299).contains(http.statusCode), UIImage(data: data) != nil else {
                FortniteDiagnostics.record("artwork: rejected response or undecodable image")
                return
            }
            if (try? Data(contentsOf: destination)) != data {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                FortniteDiagnostics.record("artwork: saved banner to shared Library/Caches")
                await MainActor.run {
                    NotificationCenter.default.post(name: artworkChanged, object: nil)
                    TVTopShelfContentProvider.topShelfContentDidChange()
                }
            } else {
                FortniteDiagnostics.record("artwork: cached banner unchanged")
            }
        } catch {
            FortniteDiagnostics.record("artwork: failed \(FortniteDiagnostics.errorCode(error))")
        }
    }

    static func saveHeroes(_ games: [GameInfo]) {
        let items = games.prefix(8).map { game in
            TopShelfHeroItem(
                id: game.id,
                title: game.title,
                provider: providerLabel(for: game),
                imageURL: (!DirectGameConfiguration.isRecentGamesLauncher && game.title.caseInsensitiveCompare(DirectGameConfiguration.title) == .orderedSame
                    ? cachedFortniteArtworkURL ?? heroImageURL(for: game)
                    : heroImageURL(for: game))?.absoluteString,
                fallbackImageURL: coverImageURL(for: game)?.absoluteString,
                playURL: actionURL(action: "play", gameID: game.id),
                displayURL: actionURL(action: DirectGameConfiguration.isRecentGamesLauncher ? "play" : "game", gameID: game.id),
                summary: game.providerMetadata?.summary.map { String($0.prefix(1200)) },
                genres: game.providerMetadata?.genres,
                releaseDate: game.providerMetadata?.releaseDate,
                releaseYear: game.providerMetadata?.releaseYear,
                developer: game.providerMetadata?.developer,
                publisher: game.providerMetadata?.publisher
            )
        }
        if let existingData = defaults.data(forKey: storageKey),
           let existingSnapshot = try? JSONDecoder().decode(TopShelfHeroSnapshot.self, from: existingData),
           existingSnapshot.items == items {
            return
        }

        let snapshot = TopShelfHeroSnapshot(savedAt: Date(), items: items)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private static func heroImageURL(for game: GameInfo) -> URL? {
        guard var raw = game.heroBannerUrl, !raw.isEmpty else { return nil }
        guard raw.contains("img.nvidiagrid.net") else { return URL(string: raw) }
        if let range = raw.range(of: ";w=") {
            raw = String(raw[..<range.lowerBound])
        }
        return URL(string: "\(raw);w=1920")
    }

    private static func coverImageURL(for game: GameInfo) -> URL? {
        guard let raw = game.boxArtUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private static func providerLabel(for game: GameInfo) -> String {
        if game.isXCloudGame { return "Xbox Cloud Gaming" }
        if game.isSunshineGame { return "Sunshine" }
        return "GeForce NOW"
    }

    private static func actionURL(action: String, gameID: String) -> String {
        var components = URLComponents()
        components.scheme = DirectGameConfiguration.urlScheme
        components.host = action
        components.queryItems = [URLQueryItem(name: "id", value: gameID)]
        return components.url?.absoluteString ?? "\(DirectGameConfiguration.urlScheme)://home"
    }
}
