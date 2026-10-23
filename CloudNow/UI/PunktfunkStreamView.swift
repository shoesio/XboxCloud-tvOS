import SwiftUI
import PunktfunkKit
import AVFoundation

private final class PunktfunkStreamEngine: @unchecked Sendable {
    private let connection: PunktfunkConnection
    private let decoder: CNMoonlightPyroWaveDecoder
    private weak var videoView: CNMoonlightVideoView?
    private var pump: Task<Void, Never>?
    private var audio: SessionAudio?
    @MainActor private var gamepad: GamepadCapture?

    init(connection: PunktfunkConnection, videoView: CNMoonlightVideoView) {
        self.connection = connection
        self.videoView = videoView
        let mode = connection.currentMode()
        decoder = CNMoonlightPyroWaveDecoder(width: Int32(mode.width), height: Int32(mode.height))
        videoView.configureVideoWidth(Int(mode.width), height: Int(mode.height))
        videoView.prepareForPyroWaveMetalRendering()
    }

    @MainActor func start(audioEnabled: Bool, controllerEnabled: Bool, onExit: @escaping () -> Void) {
        // Punktfunk's GamepadCapture owns the explicit stream escape chord. Do not
        // install CloudNow's Moonlight/UIKit exit handlers here: tvOS can surface a
        // controller's east/back face button as a Menu press, which would otherwise
        // close the Punktfunk session during ordinary gameplay.
        if audioEnabled {
            let sessionAudio = SessionAudio(connection: connection)
            sessionAudio.start(speakerUID: "", micUID: "", micChannel: 0, micEnabled: false, echoCancel: false)
            audio = sessionAudio
        }
        if controllerEnabled {
            let capture = GamepadCapture(connection: connection, manager: .shared)
            capture.onDisconnectRequest = onExit
            capture.start()
            gamepad = capture
        }
        let decoder = decoder
        let connection = connection
        let weakView = WeakVideoView(videoView)
        pump = Task.detached(priority: .userInitiated) {
            print("🎸 PUNKTFUNK VIDEO PUMP: started chunkWindow=\(connection.shardPayload)")
            var timeoutCount = 0
            var activeDecoder = decoder
            var decoderSize = (width: Int(connection.currentMode().width), height: Int(connection.currentMode().height))
            while !Task.isCancelled {
                do {
                    // This pump lives for the whole stream. PunktfunkKit bridges each AU
                    // through Objective-C, so give every poll its own pool instead of
                    // allowing autoreleased transport buffers to accumulate until the
                    // detached task exits (which can exceed tvOS's memory limit at 4K60).
                    guard let au = try autoreleasepool(invoking: {
                        try connection.nextAU(timeoutMs: 100)
                    }) else {
                        timeoutCount += 1
                        if timeoutCount == 50 || timeoutCount % 300 == 0 {
                            print("🎸 PUNKTFUNK VIDEO PUMP: no AU after \(timeoutCount) polls framesDropped=\(connection.framesDropped())")
                        }
                        continue
                    }
                    timeoutCount = 0
                    connection.noteFrameIndex(au.frameIndex)
                    let chunked = (au.flags & PunktfunkConnection.userFlagChunkAligned) != 0
                    // Gamescope attach streams the physical output's actual dimensions, which
                    // may differ from the requested/Welcome mode. PyroWave announces geometry in
                    // every frame's sequence header; rebuild before pushing it, matching
                    // Punktfunk's native pipeline rather than rejecting the SOF as a mismatch.
                    let dimensions = autoreleasepool {
                        punktfunkPyroWaveDimensions(
                            au.data, chunkAligned: chunked, windowSize: Int(connection.shardPayload)
                        )
                    }
                    if let dimensions, dimensions != decoderSize {
                        decoderSize = dimensions
                        activeDecoder = await MainActor.run {
                            if let view = weakView.value {
                                view.configureVideoWidth(dimensions.width, height: dimensions.height)
                                view.prepareForPyroWaveMetalRendering()
                            }
                            print("🎸 PUNKTFUNK VIDEO: decoder reconfigured to \(dimensions.width)x\(dimensions.height)")
                            return CNMoonlightPyroWaveDecoder(
                                width: Int32(dimensions.width), height: Int32(dimensions.height))
                        }
                    }
                    autoreleasepool {
                        activeDecoder.submitPunktfunkAccessUnit(
                            au.data, chunkAligned: chunked, windowSize: UInt(connection.shardPayload),
                            frameIndex: au.frameIndex, ptsNs: au.ptsNs
                        ) { frame, sample, error in
                            DispatchQueue.main.async {
                                guard let view = weakView.value else {
                                    frame?.markPresentationComplete(atTime: CACurrentMediaTime())
                                    return
                                }
                                if let frame {
                                    var displayError: NSString?
                                    if !view.display(frame, error: &displayError) {
                                        print("🎸 PyroWave presentation failed: \(displayError ?? "unknown")")
                                    }
                                } else if let sample {
                                    view.displayLayer.enqueue(sample)
                                } else if let error {
                                    print("🎸 PyroWave decode: \(error)")
                                }
                            }
                        }
                    }
                } catch {
                    print("🎸 PUNKTFUNK VIDEO PUMP: ended error=\(error)")
                    break
                }
            }
        }
    }

    @MainActor func stop() {
        pump?.cancel(); pump = nil
        gamepad?.stop(); gamepad = nil
        audio?.stop(); audio = nil
    }
}

/// Reads the first complete PyroWave START_OF_FRAME packet without decoding it. Punktfunk's
/// chunk-aligned transport can carry that eight-byte packet packed or fragmented across windows.
nonisolated private func punktfunkPyroWaveDimensions(
    _ data: Data, chunkAligned: Bool, windowSize: Int
) -> (width: Int, height: Int)? {
    func dimensions(_ bytes: Data) -> (width: Int, height: Int)? {
        guard bytes.count >= 8 else { return nil }
        let word0 = bytes.prefix(4).enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
        let word1 = bytes.dropFirst(4).prefix(4).enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
        guard word0 & 0x8000_0000 != 0, ((word1 >> 24) & 0x3) == 0 else { return nil }
        return (Int(word0 & 0x3fff) + 1, Int((word0 >> 14) & 0x3fff) + 1)
    }

    guard chunkAligned else { return dimensions(data) }
    guard windowSize >= 8, data.count % windowSize == 0 else { return nil }
    var fragment = Data()
    var fragmentLive = false
    var offset = 0
    while offset < data.count {
        let used = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        let kind = Int(data[offset + 2]) | (Int(data[offset + 3]) << 8)
        guard used > 0, used <= windowSize - 4 else {
            fragment.removeAll(keepingCapacity: true); fragmentLive = false
            offset += windowSize; continue
        }
        let body = data.subdata(in: (offset + 4)..<(offset + 4 + used))
        switch kind {
        case 0:
            if let found = dimensions(body) { return found }
            fragment.removeAll(keepingCapacity: true); fragmentLive = false
        case 1:
            fragment = body; fragmentLive = true
        case 2 where fragmentLive:
            fragment.append(body)
        case 3 where fragmentLive:
            fragment.append(body)
            if let found = dimensions(fragment) { return found }
            fragment.removeAll(keepingCapacity: true); fragmentLive = false
        default:
            fragment.removeAll(keepingCapacity: true); fragmentLive = false
        }
        offset += windowSize
    }
    return nil
}

private final class WeakVideoView: @unchecked Sendable {
    weak var value: CNMoonlightVideoView?
    init(_ value: CNMoonlightVideoView?) { self.value = value }
}

private struct PunktfunkVideoSurface: UIViewRepresentable {
    let connection: PunktfunkConnection
    let audioEnabled: Bool
    let controllerEnabled: Bool
    let onExit: () -> Void

    final class Coordinator {
        var engine: PunktfunkStreamEngine?
        deinit { Task { @MainActor [engine] in engine?.stop() } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> CNMoonlightVideoView {
        let view = CNMoonlightVideoView(frame: .zero)
        let engine = PunktfunkStreamEngine(connection: connection, videoView: view)
        context.coordinator.engine = engine
        engine.start(audioEnabled: audioEnabled, controllerEnabled: controllerEnabled, onExit: onExit)
        return view
    }
    func updateUIView(_ uiView: CNMoonlightVideoView, context: Context) {}
    static func dismantleUIView(_ uiView: CNMoonlightVideoView, coordinator: Coordinator) {
        coordinator.engine?.stop(); coordinator.engine = nil
    }
}

struct PunktfunkStreamView: View {
    let game: GameInfo
    let onDismiss: () -> Void
    @Environment(PunktfunkProvider.self) private var provider
    @AppStorage("punktfunk.stream.audioEnabled") private var audioEnabled = true
    @AppStorage("punktfunk.stream.controllerEnabled") private var controllerEnabled = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let connection = provider.activeConnection {
                PunktfunkVideoSurface(connection: connection, audioEnabled: audioEnabled,
                                      controllerEnabled: controllerEnabled, onExit: close)
                    .ignoresSafeArea()
            } else if provider.isLaunching {
                VStack(spacing: 24) {
                    ProgressView()
                        .tint(.white)
                    Text("Starting \(game.title)…")
                        .foregroundStyle(.white)
                }
            } else {
                VStack(spacing: 24) {
                    Text("Punktfunk session failed")
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text(provider.launchError ?? "The host closed the session.")
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 760)
                    Button("Close", action: close)
                        .buttonStyle(.borderedProminent)
                }
                .padding(60)
            }
        }
    }
    private func close() { provider.stopSession(); onDismiss() }
}
