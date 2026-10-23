import Foundation
import Observation

/// Top Shelf routes survive sign-in and process restarts. Both actions play.
@MainActor @Observable
final class XCloudLaunchSelection {
    private(set) var requestedGameID: String?
    private(set) var hasExplicitRequest = false

    init() {
        // Saved IDs identify artwork; they aren't a new request to launch a game.
        requestedGameID = nil
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard DirectGameConfiguration.isRecentGamesLauncher,
              url.scheme?.lowercased() == DirectGameConfiguration.urlScheme.lowercased(),
              ["play", "game"].contains(url.host?.lowercased() ?? ""),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawID = components.queryItems?.first(where: { $0.name == "id" })?.value else { return false }
        let id = rawID.hasPrefix("xcloud:") ? String(rawID.dropFirst(7)) : rawID
        guard !id.isEmpty, id.count <= 200,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else { return false }
        hasExplicitRequest = true
        select(id)
        return true
    }

    func select(_ id: String) {
        requestedGameID = id
        UserDefaults.standard.set(id, forKey: "xcloud.selectedTitleID")
    }

    func gameIDForActivation(activeGameID: String?, hasCloudSession: Bool, firstRecentGameID: String?) -> String? {
        if hasExplicitRequest { return requestedGameID }
        if hasCloudSession, let activeGameID { return activeGameID }
        return firstRecentGameID
    }

    func markRequestHandled() { hasExplicitRequest = false }
}
