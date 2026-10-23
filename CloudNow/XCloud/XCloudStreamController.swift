import AVFoundation
import Foundation
import GameController
import LiveKitWebRTC
import Observation
import OSLog

/// Small, local-only diagnostic trail. Callers supply labels/counts, never tokens,
/// session URLs, SDP, response bodies, or account identifiers.
enum FortniteDiagnostics {
    private static let queue = DispatchQueue(label: "Fortnite.Diagnostics")
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.josephhewes.CloudNowAppTV", category: "FortniteDiagnostics")

    static func record(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        queue.async {
            do {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("FortniteDiagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("events.log")
                let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
                let data = Data(line.utf8)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if !FileManager.default.fileExists(atPath: file.path) || size > 524288 {
                    try data.write(to: file, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            } catch {
                logger.error("Could not save diagnostic trail")
            }
        }
    }

    static func errorCode(_ error: Error) -> String {
        if case XCloudError.server(let status, _) = error { return "HTTP \(status)" }
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}

private final class FortniteFrameProbe: NSObject, LKRTCVideoRenderer {
    private let lock = NSLock()
    private var frames: UInt64 = 0
    private var lastFrame: TimeInterval = 0
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        frames &+= 1
        lastFrame = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }
    func snapshot() -> (frames: UInt64, age: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, lastFrame == 0 ? -1 : ProcessInfo.processInfo.systemUptime - lastFrame)
    }
}

enum XCloudStreamState: Equatable {
    case idle
    case connecting(String)
    case streaming
    case failed(String)
}

@MainActor
@Observable
final class XCloudStreamController: NSObject {
    var hasRetainedCloudSession: Bool { session != nil }
    private(set) var state: XCloudStreamState = .idle
    private(set) var videoTrack: LKRTCVideoTrack? {
        didSet {
            guard oldValue !== videoTrack else { return }
            oldValue?.remove(frameProbe)
            videoTrack?.add(frameProbe)
            FortniteDiagnostics.record("video: track attached=\(videoTrack != nil)")
        }
    }
    private let frameProbe = FortniteFrameProbe()
    private var diagnosticTask: Task<Void, Never>?

    private func logConnection(_ label: String) {
        let sample = frameProbe.snapshot()
        FortniteDiagnostics.record("\(label): background=\(isBackgrounded) session=\(session != nil) ice=\(peerConnection.map { String(describing: $0.iceConnectionState) } ?? "none") input=\(channels["input"].map { String(describing: $0.readyState) } ?? "none") frames=\(sample.frames) lastFrameAge=\(Int(sample.age))s")
    }

    private func observeFramesAfterResume() {
        diagnosticTask?.cancel()
        let baseline = frameProbe.snapshot().frames
        diagnosticTask = Task { [weak self] in
            for delay in [1, 4, 5] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.logConnection("resume probe newFrames=\(self.frameProbe.snapshot().frames - baseline)")
            }
        }
    }
    var exitComboHandler: (() -> Void)?
    var preservesCloudSession = false
    private(set) var isRecovering = false
    private var isBackgrounded = false

    func setRemotePress(_ type: UIPress.PressType, pressed: Bool) -> Bool {
        let bit: Int
        switch type {
        case .upArrow: bit = 8
        case .downArrow: bit = 9
        case .leftArrow: bit = 10
        case .rightArrow: bit = 11
        case .select: bit = 4
        case .playPause: bit = 5
        default: return false // Back remains a system action.
        }
        inputSender?.setRemoteButton(bit, pressed: pressed)
        return true
    }

    func suspendForHome() {
        logConnection("leaving Home")
        diagnosticTask?.cancel()
        isBackgrounded = true
        inputSender?.stop()
        setAudioEnabled(false)
    }

    /// Owned by the launcher's lifecycle task. A cached ICE state is not proof
    /// of a live stream: require new decoded frames, then watch for later stalls.
    func resumeFromHome(game: XCloudGame, auth: XCloudAuthManager) async {
        logConnection("resume requested")
        observeFramesAfterResume()
        isBackgrounded = false
        isRecovering = true
        defer { isRecovering = false }
        var retries = 0
        while !Task.isCancelled, !isBackgrounded {
            let canReuse = mediaConnectionIsOpen
            let baseline = frameProbe.snapshot().frames
            if canReuse {
                FortniteDiagnostics.record("resume: verifying fresh frames on existing transport")
                if let channel = channels["control"] {
                    sendJSON(["message": "videoKeyframeRequested", "ifrRequested": true], on: channel)
                }
            } else {
                releaseTransport()
                FortniteDiagnostics.record("resume: rebuild transport, retain cloud session")
                state = .idle
                await connect(game: game, auth: auth, controllerDeadzone: Double(controllerDeadzone))
            }
            guard !Task.isCancelled, !isBackgrounded else { return }
            if await waitForFreshFrames(after: baseline, timeout: canReuse ? 2 : 15) {
                FortniteDiagnostics.record("resume: fresh video confirmed")
                configureAudio()
                setAudioEnabled(true)
                inputSender?.start()
                state = .streaming
                isRecovering = false
                let healthySince = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled, !isBackgrounded {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard !Task.isCancelled, !isBackgrounded else { return }
                    if !mediaConnectionIsOpen || frameProbe.snapshot().age > 3 { break }
                    // A long healthy run earns a fresh recovery budget.
                    if ProcessInfo.processInfo.systemUptime - healthySince > 30 { retries = 0 }
                }
            }
            guard !Task.isCancelled, !isBackgrounded else { return }
            isRecovering = true
            logConnection("recovery: stream stalled")
            inputSender?.stop()
            setAudioEnabled(false)
            releaseTransport()
            guard retries < 2 else {
                FortniteDiagnostics.record("recovery: automatic retries exhausted")
                state = .failed("\(DirectGameConfiguration.displayName) couldn’t reconnect. Please try again.")
                return
            }
            retries += 1
            FortniteDiagnostics.record("recovery: automatic retry \(retries), retaining session")
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
    }

    private var mediaConnectionIsOpen: Bool {
        guard let pc = peerConnection else { return false }
        return [.connected, .completed].contains(pc.iceConnectionState)
            && channels["input"]?.readyState == .open
    }

    private func waitForFreshFrames(after baseline: UInt64, timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled, !isBackgrounded else { return false }
            if case .failed = state { return false }
            let sample = frameProbe.snapshot()
            if mediaConnectionIsOpen, sample.frames >= baseline + 3, sample.age < 1 { return true }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }

    private func setAudioEnabled(_ enabled: Bool) {
        for receiver in peerConnection?.receivers ?? [] {
            (receiver.track as? LKRTCAudioTrack)?.isEnabled = enabled
        }
    }

    private var client: XCloudClient?
    private var session: XCloudSession?
    private var peerConnection: LKRTCPeerConnection?
    private var channels: [String: LKRTCDataChannel] = [:]
    private var localCandidates: [XCloudICECandidate] = []
    private var inputSender: XCloudInputSender?
    private var keepaliveTask: Task<Void, Never>?
    private var keyframeTask: Task<Void, Never>?
    private var messageHandshakeComplete = false
    private var controlStarted = false
    private var inputStarted = false
    private var controllerDeadzone: Float = 0.15

    private static let messageHandshakeID = "be0bfc6d-1e83-4c8a-90ed-fa8601c5a179"
    private static let clientAppInstallID = "c97d7ee0-73b2-4239-bf1d-9d805a338429"

    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory()
        )
    }()

    func connect(game: XCloudGame, auth: XCloudAuthManager, controllerDeadzone: Double) async {
        guard case .idle = state else { return }
        self.controllerDeadzone = Float(controllerDeadzone)
        do {
            FortniteDiagnostics.record("connect: begin")
            state = .connecting("Checking Xbox sign-in…")
            let credentials = try await auth.resolvedCredentials()
            try Task.checkCancellation()
            let client = XCloudClient(credentials: credentials)
            self.client = client

            state = .connecting("Finding an Xbox cloud console…")
            var reusable = preservesCloudSession ? self.session : nil
            if let existing = reusable {
                FortniteDiagnostics.record("connect: validating retained session")
                do {
                    try await client.keepalive(existing)
                } catch XCloudError.server(let status, _) where status == 404 || status == 410 {
                    FortniteDiagnostics.record("connect: retained session expired HTTP \(status)")
                    reusable = nil
                    self.session = nil
                }
            }
            let session: XCloudSession
            if let reusable { session = reusable }
            else {
                FortniteDiagnostics.record("connect: requesting new cloud session")
                session = try await client.start(titleID: game.id)
            }
            self.session = session
            try Task.checkCancellation()
            let readiness = try await client.waitUntilReady(session)
            FortniteDiagnostics.record("connect: session readiness=\(readiness)")
            try Task.checkCancellation()
            if readiness != "provisioned" {
                state = .connecting("Authorizing your cloud console…")
                let lpt = try await auth.longPlayToken()
                try await client.connect(session, longPlayToken: lpt)
                try Task.checkCancellation()
            }

            state = .connecting("Negotiating video and controller input…")
            configureAudio()
            let pc = try makePeerConnection()
            peerConnection = pc
            createDataChannels(on: pc)

            let constraints = LKRTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "true"],
                optionalConstraints: nil
            )
            let offer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
                pc.offer(for: constraints) { sdp, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let sdp { continuation.resume(returning: sdp) }
                    else { continuation.resume(throwing: XCloudError.invalidResponse("WebRTC did not create an offer.")) }
                }
            }
            let preferredOffer = Self.preferH264AndBandwidth(offer.sdp)
            try Task.checkCancellation()
            try await setLocal(LKRTCSessionDescription(type: .offer, sdp: preferredOffer), on: pc)
            let answer = try await client.exchangeSDP(session, offer: preferredOffer)
            try await setRemote(LKRTCSessionDescription(type: .answer, sdp: answer), on: pc)

            try await Task.sleep(for: .seconds(2))
            let iceUfrag = preferredOffer.components(separatedBy: CharacterSet.newlines)
                .first(where: { $0.hasPrefix("a=ice-ufrag:") })
                .map { String($0.dropFirst("a=ice-ufrag:".count)).trimmingCharacters(in: .whitespaces) }
            let candidatesWithCredentials = localCandidates.map {
                XCloudICECandidate(
                    candidate: $0.candidate,
                    mLineIndex: $0.mLineIndex,
                    mid: $0.mid,
                    usernameFragment: $0.usernameFragment ?? iceUfrag
                )
            }
            let remote = try await client.exchangeICE(session, candidates: candidatesWithCredentials)
            try Task.checkCancellation()
            try await applyRemoteCandidates(remote, remoteSDP: answer, to: pc)
            FortniteDiagnostics.record("connect: SDP and ICE exchange finished")
            try Task.checkCancellation()

            keepaliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, let self, let client = self.client, let session = self.session else { return }
                    do { try await client.keepalive(session) }
                    catch { FortniteDiagnostics.record("keepalive: failed \(FortniteDiagnostics.errorCode(error))") }
                }
            }
        } catch is CancellationError {
            FortniteDiagnostics.record("connect: cancelled")
            if preservesCloudSession { releaseTransport(); state = .idle }
            else { await stopSession() }
        } catch {
            FortniteDiagnostics.record("connect: failed \(FortniteDiagnostics.errorCode(error))")
            if preservesCloudSession { releaseTransport() }
            else { await stopSession() }
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        Task { await stopSession() }
    }

    private func stopSession() async {
        await endSession()
    }

    func endSession() async {
        FortniteDiagnostics.record("session: explicit end requested")
        releaseTransport()
        if let client, let session { await client.stop(session) }
        client = nil; session = nil
        state = .idle
    }

    private func releaseTransport() {
        logConnection("transport: releasing")
        keepaliveTask?.cancel(); keepaliveTask = nil
        keyframeTask?.cancel(); keyframeTask = nil
        inputSender?.stop(); inputSender = nil
        let oldConnection = peerConnection
        peerConnection = nil
        oldConnection?.close()
        channels.removeAll(); videoTrack = nil
        messageHandshakeComplete = false
        controlStarted = false
        inputStarted = false
        localCandidates.removeAll()
    }

    private func makePeerConnection() throws -> LKRTCPeerConnection {
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.iceServers = []
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw XCloudError.invalidResponse("Could not create WebRTC connection.")
        }
        return pc
    }

    private func createDataChannels(on pc: LKRTCPeerConnection) {
        for (label, protocolName) in [("control", "controlV1"), ("input", "1.0"), ("message", "messageV1"), ("chat", "chatV1")] {
            let config = LKRTCDataChannelConfiguration()
            config.isOrdered = true
            config.protocol = protocolName
            if let channel = pc.dataChannel(forLabel: label, configuration: config) {
                channel.delegate = self
                channels[label] = channel
            }
        }
    }

    private func setLocal(_ sdp: LKRTCSessionDescription, on pc: LKRTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func setRemote(_ sdp: LKRTCSessionDescription, on pc: LKRTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func applyRemoteCandidates(
        _ candidates: [XCloudICECandidate],
        remoteSDP: String,
        to peerConnection: LKRTCPeerConnection
    ) async throws {
        guard !candidates.isEmpty else {
            print("[XCloud] ICE response contained no remote candidates; continuing with SDP candidates")
            return
        }

        let mediaMids = Self.mediaMids(in: remoteSDP)
        var applied = 0
        var rejected = 0

        for candidate in candidates {
            guard let candidateLine = Self.normalizedCandidateLine(candidate.candidate) else {
                print("[XCloud] skipped ICE sentinel or malformed candidate")
                continue
            }

            let requestedIndex = candidate.mLineIndex
            let resolvedIndex = mediaMids.indices.contains(requestedIndex) ? requestedIndex : 0
            let resolvedMid = mediaMids.indices.contains(resolvedIndex)
                ? mediaMids[resolvedIndex]
                : (candidate.mid.isEmpty ? nil : candidate.mid)
            let rtcCandidate = LKRTCIceCandidate(
                sdp: candidateLine,
                sdpMLineIndex: Int32(resolvedIndex),
                sdpMid: resolvedMid
            )

            do {
                try await peerConnection.add(rtcCandidate)
                applied += 1
            } catch {
                rejected += 1
                print(
                    "[XCloud] rejected remote ICE candidate index=\(requestedIndex) " +
                    "resolvedIndex=\(resolvedIndex) mid=\(resolvedMid ?? "nil"): \(error.localizedDescription)"
                )
            }
        }

        print("[XCloud] remote ICE candidates applied=\(applied) rejected=\(rejected) received=\(candidates.count)")
        if applied == 0 {
            // The remote SDP can already contain a viable candidate. Let WebRTC's ICE
            // state make the final connection decision instead of aborting signaling here.
            print("[XCloud] no HTTP ICE candidates applied; continuing with remote SDP candidates")
        }
    }

    private static func normalizedCandidateLine(_ rawValue: String) -> String? {
        for rawLine in rawValue.components(separatedBy: CharacterSet.newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("a=") { line.removeFirst(2) }
            guard !line.isEmpty, line != "end-of-candidates" else { continue }
            if line.hasPrefix("candidate:") { return line }
        }
        return nil
    }

    private static func mediaMids(in sdp: String) -> [String] {
        var mids: [String] = []
        var isInMediaSection = false
        for rawLine in sdp.components(separatedBy: CharacterSet.newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                isInMediaSection = true
                mids.append(String(mids.count))
            } else if isInMediaSection, line.hasPrefix("a=mid:"), !mids.isEmpty {
                mids[mids.count - 1] = String(line.dropFirst("a=mid:".count))
            }
        }
        return mids
    }

    private func configureAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Some tvOS versions reject one of the category properties with OSStatus -50.
            // WebRTC can still configure and render its receive-only audio track, so this
            // must not abort an otherwise healthy cloud session.
            print("[XCloud] AVAudioSession setup failed (continuing): \(error.localizedDescription)")
        }
    }

    private func channelOpened(_ channel: LKRTCDataChannel) {
        print("[XCloud] data channel opened label=\(channel.label)")
        switch channel.label {
        case "control":
            startDeferredChannelsIfReady()
        case "input":
            startDeferredChannelsIfReady()
        case "message":
            sendJSON([
                "type": "Handshake",
                "version": "messageV1",
                "id": Self.messageHandshakeID,
                "cv": "0"
            ], on: channel)
        default: break
        }
    }

    private func handleMessage(_ buffer: LKRTCDataBuffer, channel: LKRTCDataChannel) {
        guard channel.label == "message", !buffer.isBinary,
              let text = String(data: buffer.data, encoding: .utf8),
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = json["type"] as? String
        if type == "HandshakeAck", !messageHandshakeComplete {
            for (target, content): (String, [String: Any]) in [
                ("/streaming/systemUi/configuration", ["version": [0, 2, 0], "systemUis": []]),
                ("/streaming/properties/clientappinstallidchanged", ["clientAppInstallId": Self.clientAppInstallID]),
                ("/streaming/characteristics/orientationchanged", ["orientation": 0]),
                ("/streaming/characteristics/touchinputenabledchanged", ["touchInputEnabled": false]),
                ("/streaming/characteristics/clientdevicecapabilities", [:]),
                ("/streaming/characteristics/dimensionschanged", [
                    "horizontal": 1920, "vertical": 1080, "preferredWidth": 1920, "preferredHeight": 1080,
                    "safeAreaLeft": 0, "safeAreaTop": 0, "safeAreaRight": 1920, "safeAreaBottom": 1080,
                    "supportsCustomResolution": true
                ])
            ] {
                guard let contentData = try? JSONSerialization.data(withJSONObject: content),
                      let contentText = String(data: contentData, encoding: .utf8) else { continue }
                sendJSON(["type": "Message", "content": contentText, "id": UUID().uuidString.lowercased(), "target": target, "cv": ""], on: channel)
            }
            messageHandshakeComplete = true
            print("[XCloud] message handshake complete; starting control and input channels")
            startDeferredChannelsIfReady()
        } else if type == "TransactionStart", let target = json["target"] as? String,
                  let id = json["id"] as? String {
            switch target {
            case "/streaming/sessionLifetimeManagement/serverInitiatedDisconnect":
                sendJSON(["type": "TransactionComplete", "content": "", "id": id, "cv": ""], on: channel)
            case "/streaming/systemUi/messages/ShowMessageDialog":
                let resultData = try? JSONSerialization.data(withJSONObject: ["Result": 0])
                let result = resultData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                sendJSON(["type": "TransactionComplete", "content": result, "id": id, "cv": ""], on: channel)
            default:
                break
            }
        }
    }

    private func startDeferredChannelsIfReady() {
        guard messageHandshakeComplete else { return }

        if !controlStarted, let control = channels["control"], control.readyState == .open {
            controlStarted = true
            sendJSON(["message": "authorizationRequest", "accessKey": "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"], on: control)
            // The Xbox protocol uses an add/remove pair as its initial capability probe.
            sendJSON(["message": "gamepadChanged", "gamepadIndex": 0, "wasAdded": true], on: control)
            sendJSON(["message": "gamepadChanged", "gamepadIndex": 0, "wasAdded": false], on: control)
            sendJSON(["message": "gamepadChanged", "gamepadIndex": 0, "wasAdded": true], on: control)
            sendJSON([
                "message": "VideoPreference", "type": "VideoPreference",
                "resolution": ["width": 1920, "height": 1080],
                "dimensions": ["width": 1920, "height": 1080], "maxFPS": 60
            ], on: control)
            keyframeTask = Task { [weak self, weak control] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self, let control else { return }
                    self.sendJSON(["message": "videoKeyframeRequested", "ifrRequested": true], on: control)
                }
            }
            print("[XCloud] control startup sequence sent")
        }

        if controlStarted, !inputStarted, let input = channels["input"], input.readyState == .open {
            inputStarted = true
            let sender = XCloudInputSender(channel: input, deadzone: controllerDeadzone)
            sender.exitComboHandler = { [weak self] in self?.exitComboHandler?() }
            if !isBackgrounded, !isRecovering { sender.start() }
            inputSender = sender
            print("[XCloud] input metadata sent; 125 Hz controller loop started")
        }
    }

    private func sendJSON(_ object: [String: Any], on channel: LKRTCDataChannel) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        channel.sendData(LKRTCDataBuffer(data: data, isBinary: false))
    }

    private static func preferH264AndBandwidth(_ sdp: String) -> String {
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: separator)
        let h264Payloads = Set(lines.compactMap { line -> String? in
            guard line.hasPrefix("a=rtpmap:"), line.localizedCaseInsensitiveContains(" H264/") else { return nil }
            return line.dropFirst("a=rtpmap:".count).split(separator: " ").first.map(String.init)
        })
        if !h264Payloads.isEmpty, let index = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) {
            let fields = lines[index].split(separator: " ").map(String.init)
            if fields.count > 3 {
                let payloads = Array(fields.dropFirst(3))
                lines[index] = (Array(fields.prefix(3)) + payloads.filter(h264Payloads.contains) + payloads.filter { !h264Payloads.contains($0) })
                    .joined(separator: " ")
            }
        }
        return SDPMunger.injectBandwidth(lines.joined(separator: separator), videoKbps: 25_000, audioKbps: 128)
    }
}

extension XCloudStreamController: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            FortniteDiagnostics.record("ICE: \(String(describing: newState)) background=\(self.isBackgrounded)")
            switch newState {
            case .connected, .completed: self.state = .streaming
            case .failed, .disconnected:
                if self.preservesCloudSession {
                    // The lifecycle watchdog owns recovery; don't flash a failure overlay.
                    self.isRecovering = true
                    self.state = .connecting("Reconnecting")
                } else {
                    self.state = .failed("The Xbox media connection was lost.")
                }
            default: break
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            self.localCandidates.append(.init(
                candidate: candidate.sdp,
                mLineIndex: Int(candidate.sdpMLineIndex),
                mid: candidate.sdpMid ?? "0",
                usernameFragment: nil
            ))
        }
    }
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        dataChannel.delegate = self
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            self.channels[dataChannel.label] = dataChannel
        }
    }
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams mediaStreams: [LKRTCMediaStream]) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            if let audio = rtpReceiver.track as? LKRTCAudioTrack {
                audio.isEnabled = !self.isBackgrounded && !self.isRecovering
            }
            if let video = rtpReceiver.track as? LKRTCVideoTrack { self.videoTrack = video }
        }
    }
}

extension XCloudStreamController: LKRTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        Task { @MainActor [weak self] in
            guard let self, self.channels[dataChannel.label] === dataChannel else { return }
            self.channelOpened(dataChannel)
        }
    }
    nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        Task { @MainActor [weak self] in
            guard let self, self.channels[dataChannel.label] === dataChannel else { return }
            self.handleMessage(buffer, channel: dataChannel)
        }
    }
}
