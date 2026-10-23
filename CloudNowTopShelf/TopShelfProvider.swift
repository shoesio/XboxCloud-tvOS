import Foundation
import TVServices

final class TopShelfProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let snapshot = TopShelfHeroStore.loadSnapshot()
        let carouselItems = snapshot.items.compactMap(makeCarouselItem)
        guard !carouselItems.isEmpty else { return nil }
        return TVTopShelfCarouselContent(style: .details, items: carouselItems)
    }

    private func makeCarouselItem(_ hero: TopShelfHeroItem) -> TVTopShelfCarouselItem? {
        let artworkURL = hero.imageURL.flatMap(URL.init(string:)) ?? hero.fallbackImageURL.flatMap(URL.init(string:))
        guard artworkURL != nil else { return nil }

        let item = TVTopShelfCarouselItem(identifier: hero.id)
        item.title = hero.title
        item.contextTitle = hero.provider
        let isRecentGames = Bundle.main.object(forInfoDictionaryKey: "XCloudRecentGamesLauncher") as? Bool ?? false
        item.summary = isRecentGames ? hero.summary : "Ready to launch from \(hero.provider)."
        if isRecentGames {
            item.genre = hero.genres?.prefix(2).joined(separator: " · ")
            if let date = hero.releaseDate {
                let formatter = ISO8601DateFormatter()
                item.creationDate = formatter.date(from: date)
            }
            var attributes: [TVTopShelfNamedAttribute] = []
            if let year = hero.releaseYear { attributes.append(TVTopShelfNamedAttribute(name: "Released", values: [String(year)])) }
            if let developer = hero.developer, !developer.isEmpty { attributes.append(TVTopShelfNamedAttribute(name: "Developer", values: [developer])) }
            if let publisher = hero.publisher, !publisher.isEmpty { attributes.append(TVTopShelfNamedAttribute(name: "Publisher", values: [publisher])) }
            item.namedAttributes = attributes
        } else {
            item.mediaOptions = .videoResolutionHD
        }
        item.setImageURL(artworkURL, for: [.screenScale1x, .screenScale2x])

        if let playURL = URL(string: hero.playURL) {
            item.playAction = TVTopShelfAction(url: playURL)
        }
        if let displayURL = URL(string: isRecentGames ? hero.playURL : hero.displayURL) {
            item.displayAction = TVTopShelfAction(url: displayURL)
        }

        return item
    }
}

private struct TopShelfHeroSnapshot: Codable {
    let savedAt: Date
    let items: [TopShelfHeroItem]
}

private struct TopShelfHeroItem: Codable, Identifiable {
    let id: String
    let title: String
    let provider: String
    let imageURL: String?
    let fallbackImageURL: String?
    let playURL: String
    let displayURL: String
    let summary: String?
    let genres: [String]?
    let releaseDate: String?
    let releaseYear: Int?
    let developer: String?
    let publisher: String?
}

private enum TopShelfHeroStore {
    static let appGroupIdentifier = Bundle.main.object(forInfoDictionaryKey: "DirectGameAppGroup") as? String
        ?? "group.com.josephhewes.CloudNowAppTV"
    static let storageKey = "topShelf.heroSnapshot"

    static func loadSnapshot() -> TopShelfHeroSnapshot {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(TopShelfHeroSnapshot.self, from: data) else {
            return TopShelfHeroSnapshot(savedAt: Date.distantPast, items: [])
        }
        return snapshot
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}
