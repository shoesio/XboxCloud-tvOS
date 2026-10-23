import SwiftUI
import LiveKitWebRTC
import GameController

/// A root-level game surface: Back bubbles to tvOS Home, never to an empty cover.
struct FortniteLauncherView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(XCloudAuthManager.self) private var auth
    @Environment(XCloudLibraryStore.self) private var library
    @Environment(XCloudLaunchSelection.self) private var selection
    @State private var controller = XCloudStreamController()
    @State private var lifecycleTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var artworkTask: Task<Void, Never>?
    @State private var hasShownGame = false
    @State private var activeGameID: String?

    var body: some View {
        ZStack {
            FortniteStartupArtwork()
            if controller.state == .streaming, !controller.isRecovering,
               !DirectGameConfiguration.isRecentGamesLauncher || selection.requestedGameID == nil || selection.requestedGameID == activeGameID {
                FortniteVideoSurface(stream: controller).ignoresSafeArea()
                    .onAppear { hasShownGame = true }
            } else if !hasShownGame, errorMessage == nil {
                VStack {
                    Spacer()
                    Text("Loading")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 4, y: 2)
                        .padding(.bottom, 60)
                }
            }
            if let message = errorMessage {
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text(message)
                        Text("Play/Pause to retry · Back to go Home")
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 60)
                }
            }
        }
        .onAppear { if scenePhase == .active { transition(toBackground: false) } }
        .onChange(of: selection.requestedGameID) { _, _ in
            if DirectGameConfiguration.isRecentGamesLauncher, scenePhase == .active {
                if selection.requestedGameID != activeGameID {
                    hasShownGame = false
                    loadError = nil
                    controller.suspendForHome()
                }
                transition(toBackground: false)
            }
        }
        .onChange(of: scenePhase) { old, phase in
            if phase == .background {
                transition(toBackground: true)
            } else if phase == .active, old != .active {
                transition(toBackground: false)
            }
        }
        .onPlayPauseCommand {
            if errorMessage != nil { transition(toBackground: false) }
        }
        .onDisappear { transition(toBackground: true) }
        .preventsTVOSScreenSaverDuringStream()
    }

    private var errorMessage: String? {
        guard !controller.isRecovering else { return nil }
        if let loadError { return loadError }
        if case .failed = controller.state { return "\(DirectGameConfiguration.displayName) couldn’t reconnect. Please try again." }
        return nil
    }

    private func transition(toBackground: Bool) {
        FortniteDiagnostics.record("lifecycle: scene=\(String(describing: scenePhase)) backgroundTransition=\(toBackground)")
        controller.preservesCloudSession = true
        if toBackground {
            lifecycleTask?.cancel()
            artworkTask?.cancel()
            controller.suspendForHome()
            return
        }
        let previous = lifecycleTask
        previous?.cancel()
        lifecycleTask = Task { @MainActor in
            // Finish a cancelled connection without deleting the cloud console.
            await previous?.value
            guard !Task.isCancelled else { return }
            // Allow a cold-launch Top Shelf URL to arrive before choosing a default.
            if DirectGameConfiguration.isRecentGamesLauncher {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            loadError = nil
            let iconFirstCard = TopShelfHeroStore.firstRecentGameID
            var refreshedRecents = false
            if library.games.isEmpty, DirectGameConfiguration.isRecentGamesLauncher {
                // The carousel needs a small MRU list, not the whole catalogue.
                await library.refreshRecentGames(auth: auth)
                refreshedRecents = true
            }
            if library.games.isEmpty { await library.load(auth: auth) }
            guard !Task.isCancelled else { return }
            var requestedID = selection.requestedGameID
            if DirectGameConfiguration.isRecentGamesLauncher {
                if iconFirstCard == nil, library.recentGames.isEmpty,
                   !selection.hasExplicitRequest, !controller.hasRetainedCloudSession, !refreshedRecents {
                    await library.refreshRecentGames(auth: auth)
                }
                guard !Task.isCancelled else { return }
                requestedID = selection.gameIDForActivation(
                    activeGameID: activeGameID,
                    hasCloudSession: controller.hasRetainedCloudSession,
                    firstRecentGameID: iconFirstCard ?? library.recentGames.first?.id
                )
                if let requestedID, selection.requestedGameID != requestedID {
                    // Avoid starting another lifecycle task for our own default selection.
                    selection.select(requestedID)
                    return
                }
            }
            if DirectGameConfiguration.isRecentGamesLauncher, let requestedID,
               !library.games.contains(where: { $0.id == requestedID }) {
                await library.load(auth: auth, force: true)
                await library.refreshRecentGames(auth: auth)
            }
            guard !Task.isCancelled else { return }
            let chosen = DirectGameConfiguration.isRecentGamesLauncher
                ? (requestedID.flatMap { id in library.games.first { $0.id == id } }
                    ?? (requestedID == nil ? library.games.first(where: DirectGameConfiguration.matches) : nil))
                : library.games.first(where: DirectGameConfiguration.matches)
            guard let game = chosen else {
                selection.markRequestHandled()
                loadError = "\(DirectGameConfiguration.displayName) isn’t available right now. Please try again."
                return
            }
            if let activeGameID, activeGameID != game.id {
                artworkTask?.cancel()
                await artworkTask?.value
                await controller.endSession()
                guard !Task.isCancelled else { return }
                hasShownGame = false
            }
            activeGameID = game.id
            selection.markRequestHandled()
            if !DirectGameConfiguration.isRecentGamesLauncher { TopShelfHeroStore.saveHeroes([game.gameInfo]) }
            artworkTask?.cancel()
            artworkTask = Task {
                await TopShelfHeroStore.refreshFortniteArtwork(for: game.gameInfo)
                guard !Task.isCancelled else { return }
                if DirectGameConfiguration.isRecentGamesLauncher { await library.refreshRecentGames(auth: auth) }
                guard !Task.isCancelled else { return }
                if !DirectGameConfiguration.isRecentGamesLauncher { await library.load(auth: auth, force: true) }
                guard !Task.isCancelled,
                      let updated = library.games.first(where: { $0.id == game.id }),
                      updated.heroArtURL != game.heroArtURL else { return }
                await TopShelfHeroStore.refreshFortniteArtwork(for: updated.gameInfo)
            }
            await controller.resumeFromHome(game: game, auth: auth)
        }
    }
}

struct FortniteStartupArtwork: View {
    @Environment(XCloudLaunchSelection.self) private var selection
    @State private var banner = TopShelfHeroStore.cachedFortniteArtworkURL
        .flatMap { UIImage(contentsOfFile: $0.path) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.01, green: 0.15, blue: 0.4)
                if let banner {
                    Image(uiImage: banner)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if let fallback = DirectGameConfiguration.fallbackArtwork {
                    Image(fallback)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
        }
        .ignoresSafeArea()
        .task {
            await TopShelfHeroStore.refreshSavedFortniteArtwork()
            banner = TopShelfHeroStore.cachedFortniteArtworkURL.flatMap { UIImage(contentsOfFile: $0.path) }
            FortniteDiagnostics.record("artwork: loading view hasBanner=\(banner != nil)")
        }
        .onReceive(NotificationCenter.default.publisher(for: TopShelfHeroStore.artworkChanged)) { _ in
            banner = TopShelfHeroStore.cachedFortniteArtworkURL.flatMap { UIImage(contentsOfFile: $0.path) }
        }
        .onChange(of: selection.requestedGameID) { _, _ in
            if DirectGameConfiguration.isRecentGamesLauncher {
                banner = TopShelfHeroStore.cachedFortniteArtworkURL.flatMap { UIImage(contentsOfFile: $0.path) }
            }
        }
    }
}

private struct FortniteVideoSurface: UIViewControllerRepresentable {
    let stream: XCloudStreamController

    func makeCoordinator() -> Coordinator { Coordinator(stream: stream) }

    final class Coordinator: NSObject {
        let stream: XCloudStreamController
        init(stream: XCloudStreamController) { self.stream = stream }

        @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
            // Micro gamepads already report touch navigation continuously.
            guard !GCController.controllers().contains(where: {
                $0.extendedGamepad == nil && $0.microGamepad != nil
            }) else { return }
            let type: UIPress.PressType
            switch gesture.direction {
            case .up: type = .upArrow
            case .down: type = .downArrow
            case .left: type = .leftArrow
            default: type = .rightArrow
            }
            _ = stream.setRemotePress(type, pressed: true)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                _ = stream.setRemotePress(type, pressed: false)
            }
        }
    }

    func makeUIViewController(context: Context) -> StreamingViewController {
        let controller = StreamingViewController()
        controller.videoSurface.allowsSystemBack = true
        controller.videoSurface.remotePressHandler = { [weak stream] type, pressed in
            stream?.setRemotePress(type, pressed: pressed) ?? false
        }
        for direction: UISwipeGestureRecognizer.Direction in [.up, .down, .left, .right] {
            let gesture = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
            gesture.direction = direction
            gesture.cancelsTouchesInView = false
            controller.videoSurface.addGestureRecognizer(gesture)
        }
        return controller
    }

    func updateUIViewController(_ controller: StreamingViewController, context: Context) {
        controller.videoSurface.videoTrack = stream.videoTrack
    }

    static func dismantleUIViewController(_ controller: StreamingViewController, coordinator: Coordinator) {
        controller.videoSurface.videoTrack = nil
        controller.videoSurface.remotePressHandler = nil
    }
}
