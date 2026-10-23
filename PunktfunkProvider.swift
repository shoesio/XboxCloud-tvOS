import Foundation
import Observation
import PunktfunkKit
import CryptoKit
import UIKit

private extension UInt32 {
    var nonzero: UInt32? { self == 0 ? nil : self }
}

@MainActor
@Observable
final class PunktfunkProvider {
    static let shared = PunktfunkProvider()

    private(set) var hosts: [DiscoveredHost] = []
    private(set) var games: [GameInfo] = []

    var accessHost: DiscoveredHost?
    var isRequestingAccess = false
    var accessError: String?
    var accessApproved = false
    private(set) var isLoadingLibrary = false
    private(set) var libraryError: String?
    private(set) var isLaunching = false
    private(set) var launchError: String?
    private(set) var activeGame: GameInfo?

    var hostDisplayName: String { accessHost?.name ?? savedHost.name }
    var hasConnectionTarget: Bool { accessHost != nil || !savedHost.host.isEmpty }

    private let discovery = HostDiscovery()
    private var observationTask: Task<Void, Never>?
    private var didAttemptLibraryRestore = false

    // Keep the active native launch/session connection alive.
    private var connection: PunktfunkConnection?
    var activeConnection: PunktfunkConnection? { connection }

    private struct SavedHost: Codable, Sendable {
        var name: String
        var host: String
        var port: UInt16
        var fingerprintHex: String?
    }

    private static let savedHostKey = "punktfunk.lastVerifiedHost.v1"
    private var savedHost: SavedHost

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedHostKey),
           let saved = try? JSONDecoder().decode(SavedHost.self, from: data) {
            savedHost = saved
        } else {
            // Migration for the already-paired STREAM 2.0 development host. Future verified
            // pairings replace this value, so mDNS is no longer a prerequisite after pairing.
            savedHost = SavedHost(
                name: "BC-250",
                host: "192.168.0.125",
                port: 9777,
                fingerprintHex: "97493a7fd86b3ba1dbcf4d97e53da3f32fa21a03f402422c45aa0f2f477b18e5"
            )
        }
    }

    func start() {
        print("🎸 Starting Punktfunk discovery...")

        discovery.start()

        if !didAttemptLibraryRestore, hasConnectionTarget {
            didAttemptLibraryRestore = true
            refreshLibrary()
        }

        observationTask?.cancel()

        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let current = discovery.hosts

                if current != hosts {
                    hosts = current

                    print("🎸 PUNKTFUNK DISCOVERY: \(hosts.count) host(s)")

                    for host in hosts {
                        print("""
                        🎸 Host found:
                           name: \(host.name)
                           address: \(host.host):\(host.port)
                           pairing required: \(host.requiresPairing)
                           fingerprint: \(host.fingerprintHex ?? "none")
                        """)
                    }

                    if accessHost == nil, let first = hosts.first {
                        accessHost = first
                    }
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func refresh() {
        discovery.refresh()
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        discovery.stop()
    }

    func refreshLibrary() {
        guard !isLoadingLibrary, let host = connectionTarget else { return }
        isLoadingLibrary = true
        libraryError = nil
        let fingerprint = Self.fingerprintData(host.fingerprintHex)

        Task.detached(priority: .userInitiated) {
            do {
                let identity = try await PunktfunkIdentityStore.shared.loadForPairing()
                let entries = try await LibraryClient.fetch(
                    address: host.host,
                    certPEM: identity.certPEM,
                    keyPEM: identity.keyPEM,
                    hostFingerprint: fingerprint
                )
                let artwork = await Self.fetchHostArtwork(
                    for: entries,
                    hostAddress: host.host,
                    identity: identity,
                    fingerprint: fingerprint
                )
                await MainActor.run {
                    self.games = entries.launchersFirst.map { Self.gameInfo($0, artwork: artwork[$0.id]) }
                    self.isLoadingLibrary = false
                    self.accessApproved = true
                }
            } catch {
                await MainActor.run {
                    self.isLoadingLibrary = false
                    self.libraryError = error.localizedDescription
                }
            }
        }
    }

    func requestAccess() {
        guard
            !isRequestingAccess,
            let host = accessHost
        else {
            return
        }

        isRequestingAccess = true
        accessError = nil

        print("🎸 REQUESTING ACCESS TO \(host.name)")
        print("🎸 Approve Stream 2.0 in Punktfunk's host Pairing page")

        let advertisedPin = Self.fingerprintData(host.fingerprintHex)

        Task.detached(priority: .userInitiated) {
            do {
                // Request Access creates durable trust on the host, so our side
                // must use a durable identity as well.
                let identity = try await PunktfunkIdentityStore.shared.loadForPairing()

                let conn = try PunktfunkConnection(
                    host: host.host,
                    port: host.port,

                    width: 1920,
                    height: 1080,
                    refreshHz: 60,

                    // Pin the mDNS-advertised cert during the approval wait.
                    pinSHA256: advertisedPin,
                    identity: identity,

                    compositor: .auto,
                    gamepad: .auto,

                    bitrateKbps: 50_000,
                    videoCaps: 0,
                    audioChannels: 2,

                    // PyroWave is a real Punktfunk-native codec.
                    videoCodecs: PunktfunkConnection.codecPyroWave,
                    preferredCodec: PunktfunkConnection.codecPyroWave,

                    clientCaps: 0x02,
                    launchID: nil,

                    // Host may park this handshake for ~180 seconds.
                    timeoutMs: 185_000
                )

                let verifiedFingerprint = conn.hostFingerprint
                defer { conn.close() }

                await MainActor.run {
                    self.saveVerifiedHost(host, fingerprint: verifiedFingerprint)
                    self.isRequestingAccess = false
                    self.accessApproved = true

                    print("🎸 ACCESS APPROVED!")
                    print(
                        "🎸 Verified host fingerprint: "
                        + verifiedFingerprint
                            .map { String(format: "%02x", $0) }
                            .joined()
                    )
                }

                // Approval has now added THIS client identity to the host's
                // paired-client store, so its management API should accept
                // the same identity over mTLS.
                let games = try await LibraryClient.fetch(
                    address: host.host,
                    certPEM: identity.certPEM,
                    keyPEM: identity.keyPEM,
                    hostFingerprint: verifiedFingerprint
                )
                let artwork = await Self.fetchHostArtwork(
                    for: games,
                    hostAddress: host.host,
                    identity: identity,
                    fingerprint: verifiedFingerprint
                )

                await MainActor.run {
                    self.games = games.launchersFirst.map { Self.gameInfo($0, artwork: artwork[$0.id]) }

                    print("🎸 LIBRARY RECEIVED: \(games.count) entries")

                    for game in games.launchersFirst {
                        print("🎮 \(game.title) [\(game.storeLabel)]")
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRequestingAccess = false
                    self.accessError = error.localizedDescription
                    print("🎸 REQUEST ACCESS FAILED: \(error)")
                }
            }
        }
    }

    func launch(_ game: GameInfo) {
        guard !isLaunching, let host = connectionTarget, let launchID = game.punktfunkLaunchID else {
            launchError = "This Punktfunk library entry has no launch identity."
            return
        }

        stopSession()
        isLaunching = true
        launchError = nil
        activeGame = game
        let fingerprint = Self.fingerprintData(host.fingerprintHex)
        let defaults = UserDefaults.standard
        let width = UInt32(defaults.integer(forKey: "punktfunk.stream.width")).nonzero ?? 1920
        let height = UInt32(defaults.integer(forKey: "punktfunk.stream.height")).nonzero ?? 1080
        let bitrate = UInt32(defaults.integer(forKey: "punktfunk.stream.bitrateKbps")).nonzero ?? 200_000

        Task.detached(priority: .userInitiated) {
            do {
                let identity = try await PunktfunkIdentityStore.shared.loadForPairing()
                let conn = try PunktfunkConnection(
                    host: host.host, port: host.port,
                    width: width, height: height, refreshHz: 60,
                    pinSHA256: fingerprint, identity: identity,
                    compositor: .auto, gamepad: .auto,
                    bitrateKbps: bitrate, videoCaps: 0, audioChannels: 2,
                    videoCodecs: PunktfunkConnection.codecPyroWave,
                    preferredCodec: PunktfunkConnection.codecPyroWave,
                    // CloudNow presents efficiently, but does not yet report Punktfunk's
                    // display-latch phase grid. Do not advertise CLIENT_CAP_PHASE_LOCK (0x02)
                    // until that feedback loop is actually connected.
                    clientCaps: 0, launchID: launchID, timeoutMs: 15_000
                )
                conn.setVideoDropped(false)
                conn.requestKeyframe()
                let mode = conn.currentMode()
                print("🎸 PUNKTFUNK SESSION: video enabled mode=\(mode.width)x\(mode.height)@\(mode.refreshHz) codec=\(conn.resolvedCodec)")
                await MainActor.run {
                    self.connection = conn
                    self.isLaunching = false
                }
            } catch {
                await MainActor.run {
                    self.isLaunching = false
                    self.launchError = error.localizedDescription
                }
            }
        }
    }

    func stopSession() {
        connection?.close()
        connection = nil
        activeGame = nil
        isLaunching = false
    }


    nonisolated private struct LocalArtwork: Sendable {
        var poster: String?
        var hero: String?
    }

    private static func gameInfo(_ entry: GameEntry, artwork: LocalArtwork?) -> GameInfo {
        GameInfo(
            id: "punktfunk:\(entry.id)", title: entry.title,
            boxArtUrl: artwork?.poster ?? safePublicArtwork(entry.art.posterCandidates.first),
            heroBannerUrl: artwork?.hero ?? safePublicArtwork(
                [entry.art.hero, entry.art.header].compactMap { $0 }.first.flatMap(URL.init(string:))
            ),
            isInLibrary: true,
            variants: [GameVariant(
                id: "punktfunk:\(entry.id)",
                appStore: "PUNKTFUNK_\(entry.store.uppercased())",
                appId: entry.id,
                isOwned: true
            )],
            canonicalId: "punktfunk:\(entry.id)",
            matchConfidence: 1,
            matchSource: "punktfunkLibrary"
        )
    }

    private var connectionTarget: SavedHost? {
        if let host = accessHost {
            return SavedHost(
                name: host.name,
                host: host.host,
                port: host.port,
                fingerprintHex: host.fingerprintHex ?? savedHost.fingerprintHex
            )
        }
        return savedHost.host.isEmpty ? nil : savedHost
    }

    private func saveVerifiedHost(_ host: DiscoveredHost, fingerprint: Data) {
        savedHost = SavedHost(
            name: host.name,
            host: host.host,
            port: host.port,
            fingerprintHex: fingerprint.map { String(format: "%02x", $0) }.joined()
        )
        if let data = try? JSONEncoder().encode(savedHost) {
            UserDefaults.standard.set(data, forKey: Self.savedHostKey)
        }
    }

    nonisolated private static func fetchHostArtwork(
        for entries: [GameEntry],
        hostAddress: String,
        identity: ClientIdentity,
        fingerprint: Data?
    ) async -> [String: LocalArtwork] {
        guard let loader = try? LibraryArtLoader(
            address: hostAddress,
            certPEM: identity.certPEM,
            keyPEM: identity.keyPEM,
            hostFingerprint: fingerprint
        ) else { return [:] }
        guard let artworkDirectory = makeArtworkDirectory() else {
            print("🎨 PUNKTFUNK ARTWORK: no writable cache directory")
            return [:]
        }
        return await withTaskGroup(of: (String, LocalArtwork).self) { group in
            for entry in entries {
                group.addTask {
                    var local = LocalArtwork()
                    for poster in entry.art.posterCandidates where local.poster == nil {
                        local.poster = await cacheArtwork(
                            poster, entryID: entry.id, role: "poster",
                            loader: loader, directory: artworkDirectory)
                    }
                    for heroString in [entry.art.hero, entry.art.header].compactMap({ $0 })
                    where local.hero == nil {
                        if let hero = URL(string: heroString) {
                            local.hero = await cacheArtwork(
                                hero, entryID: entry.id, role: "hero",
                                loader: loader, directory: artworkDirectory)
                        }
                    }
                    return (entry.id, local)
                }
            }
            var result: [String: LocalArtwork] = [:]
            for await (id, artwork) in group { result[id] = artwork }
            let posters = result.values.filter { $0.poster != nil }.count
            let heroes = result.values.filter { $0.hero != nil }.count
            print("🎨 PUNKTFUNK ARTWORK: posters=\(posters)/\(entries.count) heroes=\(heroes)/\(entries.count)")
            return result
        }
    }

    nonisolated private static func cacheArtwork(
        _ url: URL,
        entryID: String,
        role: String,
        loader: LibraryArtLoader,
        directory: URL
    ) async -> String? {
        guard url.host != nil else { return url.absoluteString }
        // Public CDN artwork already works through CloudNow's ordinary remote-image cache.
        guard url.path.hasPrefix("/api/v1/library/art/") else { return url.absoluteString }
        do {
            let digest = SHA256.hash(data: Data("\(entryID):\(role)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            let file = directory.appendingPathComponent("\(digest).img")
            if let existing = try? Data(contentsOf: file), UIImage(data: existing) != nil {
                return file.absoluteString
            }
            let data = try await loader.data(for: url)
            guard UIImage(data: data) != nil else {
                print("🎨 Punktfunk artwork was not a supported image: \(url.absoluteString) bytes=\(data.count)")
                return nil
            }
            try data.write(to: file, options: .atomic)
            return file.absoluteString
        } catch {
            print("🎨 Punktfunk artwork fetch failed: \(url.absoluteString) error=\(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func makeArtworkDirectory() -> URL? {
        let candidates = [
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.temporaryDirectory
        ].compactMap { $0 }

        for base in candidates {
            let directory = base
                .appendingPathComponent("CloudNowPunktfunk", isDirectory: true)
                .appendingPathComponent("Artwork", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                return directory
            } catch {
                continue
            }
        }
        return nil
    }

    private static func safePublicArtwork(_ url: URL?) -> String? {
        guard let url else { return nil }
        return url.path.hasPrefix("/api/v1/library/art/") ? nil : url.absoluteString
    }

    private static func fingerprintData(_ hex: String?) -> Data? {
        guard let hex, hex.count == 64 else { return nil }

        var data = Data(capacity: 32)
        var index = hex.startIndex

        for _ in 0..<32 {
            let next = hex.index(index, offsetBy: 2)

            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }

            data.append(byte)
            index = next
        }

        return data.count == 32 ? data : nil
    }
}

extension GameInfo {
    var isPunktfunkGame: Bool {
        id.hasPrefix("punktfunk:") || variants.contains { $0.appStore.hasPrefix("PUNKTFUNK_") }
    }

    var punktfunkLaunchID: String? {
        if id.hasPrefix("punktfunk:") { return String(id.dropFirst("punktfunk:".count)) }
        return variants.first { $0.appStore.hasPrefix("PUNKTFUNK_") }?.appId
    }
}
