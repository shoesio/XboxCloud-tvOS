import Foundation
import Observation

@MainActor
@Observable
final class XCloudLibraryStore {
    private(set) var games: [XCloudGame] = []
    private(set) var homePlaylists: XCloudHomePlaylists = .empty
    private(set) var recentGames: [XCloudGame] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private static var cacheDirectory: URL? {
        // tvOS permits cache writes, but not a persistent Application Support tree.
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CloudNow", isDirectory: true)
            .appendingPathComponent("XCloud", isDirectory: true)
    }

    private static var gamesCacheURL: URL? {
        cacheDirectory?.appendingPathComponent("entitled-library-v2.json")
    }

    private static var playlistsCacheURL: URL? {
        cacheDirectory?.appendingPathComponent("home-playlists-v2.json")
    }
    private static var recentCacheURL: URL? { cacheDirectory?.appendingPathComponent("recent-games-v1.json") }

    init() {
        if let url = Self.recentCacheURL, let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode([XCloudGame].self, from: data) {
            recentGames = cached.map(Self.normalizedGame)
        }
        if let url = Self.gamesCacheURL,
           let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode([XCloudGame].self, from: data) {
            games = cached.map { game in
                Self.normalizedGame(game)
            }
        }
        if let url = Self.playlistsCacheURL,
           let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(XCloudHomePlaylists.self, from: data) {
            homePlaylists = XCloudHomePlaylists(
                newOnXCloud: cached.newOnXCloud.map(Self.normalizedGame),
                mostPopular: cached.mostPopular.map(Self.normalizedGame)
            )
        }
        if DirectGameConfiguration.isRecentGamesLauncher {
            for game in recentGames where !games.contains(where: { $0.id == game.id }) { games.append(game) }
        }
    }

    var gameInfos: [GameInfo] { games.map(\.gameInfo) }
    var newOnXCloudGameInfos: [GameInfo] { homePlaylists.newOnXCloud.map(\.gameInfo) }
    var mostPopularGameInfos: [GameInfo] { homePlaylists.mostPopular.map(\.gameInfo) }

    func game(titleID: String) -> XCloudGame? {
        games.first { $0.id == titleID }
    }

    func load(auth: XCloudAuthManager, force: Bool = false) async {
        guard auth.isSignedIn else { return }
        guard force || games.isEmpty else { return }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let credentials = try await auth.resolvedCredentials()
            let client = XCloudClient(credentials: credentials)
            games = try await client.games()
            homePlaylists = await client.homePlaylists(from: games)
            persistCaches()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        games = []
        homePlaylists = .empty
        recentGames = []
        if let url = Self.recentCacheURL { try? FileManager.default.removeItem(at: url) }
        errorMessage = nil
        if let url = Self.gamesCacheURL { try? FileManager.default.removeItem(at: url) }
        if let url = Self.playlistsCacheURL { try? FileManager.default.removeItem(at: url) }
    }

    func refreshRecentGames(auth: XCloudAuthManager) async {
        guard DirectGameConfiguration.isRecentGamesLauncher, auth.isSignedIn else { return }
        do {
            let client = XCloudClient(credentials: try await auth.resolvedCredentials())
            let recent = try await client.recentGames(from: games)
            try Task.checkCancellation()
            recentGames = recent
            // MRU can contain owned cloud titles absent from the main catalogue.
            for game in recent {
                if let index = games.firstIndex(where: { $0.id == game.id }) { games[index] = game }
                else { games.append(game) }
            }
            TopShelfHeroStore.saveHeroes(recent.map(\.gameInfo))
            if let directory = Self.cacheDirectory, let url = Self.recentCacheURL {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(recent) { try? data.write(to: url, options: .atomic) }
            }
            FortniteDiagnostics.record("recent games: refreshed count=\(recent.count)")
        } catch {
            // Keep the last usable carousel during a temporary network failure.
            FortniteDiagnostics.record("recent games: refresh failed \(FortniteDiagnostics.errorCode(error))")
            if !recentGames.isEmpty { TopShelfHeroStore.saveHeroes(recentGames.map(\.gameInfo)) }
        }
    }

    private func persistCaches() {
        guard let directory = Self.cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let url = Self.gamesCacheURL,
           let data = try? JSONEncoder().encode(games) {
            try? data.write(to: url, options: .atomic)
        }
        if let url = Self.playlistsCacheURL,
           let data = try? JSONEncoder().encode(homePlaylists) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func normalizedGame(_ game: XCloudGame) -> XCloudGame {
        XCloudGame(
            id: game.id,
            productID: game.productID,
            title: XCloudTitleFormatter.displayTitle(game.title),
            supportsController: game.supportsController,
            hasEntitlement: game.hasEntitlement,
            boxArtURL: game.boxArtURL,
            heroArtURL: game.heroArtURL,
            providerMetadata: game.providerMetadata
        )
    }
}
