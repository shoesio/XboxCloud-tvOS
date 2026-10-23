import Foundation
import GameController
import LiveKitWebRTC

final class XCloudInputSender {
    private weak var channel: LKRTCDataChannel?
    private var timer: DispatchSourceTimer?
    private var sequence: UInt32 = 1
    private let queue = DispatchQueue(label: "CloudNow.XCloudInput", qos: .userInteractive)
    private let deadzone: Float
    var exitComboHandler: (() -> Void)?
    private var exitComboHeldSince: Date?
    private var didTriggerExitCombo = false
    private var remoteButtons: UInt16 = 0

    func setRemoteButton(_ bit: Int, pressed: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if pressed { self.remoteButtons |= UInt16(1 << bit) }
            else { self.remoteButtons &= ~UInt16(1 << bit) }
        }
    }

    init(channel: LKRTCDataChannel, deadzone: Float) {
        self.channel = channel
        self.deadzone = max(0, min(0.95, deadzone))
    }

    func start() {
        guard timer == nil else { return }
        sendClientMetadata()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sendFrame() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            remoteButtons = 0
            sendFrame(neutral: true)
        }
    }

    private func sendClientMetadata() {
        var data = header(type: 1 << 3, payloadBytes: 1)
        data[14] = 1
        send(data)
    }

    private func sendFrame(neutral: Bool = false) {
        let controllers = neutral ? [] : GCController.controllers()
        let controller = controllers.first { $0.extendedGamepad != nil }
        let gamepad = controller?.extendedGamepad

        var buttons: UInt16 = remoteButtons
        func flag(_ pressed: Bool, _ bit: Int) { if pressed { buttons |= UInt16(1 << bit) } }
        if let gamepad, let controller {
            flag(gamepad.buttonMenu.isPressed, 2)
            flag(gamepad.buttonOptions?.isPressed == true, 3)
            flag(gamepad.buttonA.isPressed, 4)
            flag(gamepad.buttonB.isPressed, 5)
            flag(gamepad.buttonX.isPressed, 6)
            flag(gamepad.buttonY.isPressed, 7)
            flag(gamepad.dpad.up.isPressed, 8)
            flag(gamepad.dpad.down.isPressed, 9)
            flag(gamepad.dpad.left.isPressed, 10)
            flag(gamepad.dpad.right.isPressed, 11)
            flag(gamepad.leftShoulder.isPressed, 12)
            flag(gamepad.rightShoulder.isPressed, 13)
            flag(gamepad.leftThumbstickButton?.isPressed == true, 14)
            flag(gamepad.rightThumbstickButton?.isPressed == true, 15)
            updateExitCombo(controller: controller, buttons: buttons)
        }
        // Older Siri Remotes expose a micro gamepad; newer clickpad remotes
        // also arrive through UIKit. Both merge into the same Xbox player.
        for remote in controllers where remote.extendedGamepad == nil {
            guard let micro = remote.microGamepad else { continue }
            flag(micro.buttonA.isPressed, 4)
            flag(micro.buttonX.isPressed, 5)
            flag(micro.dpad.yAxis.value > 0.5, 8)
            flag(micro.dpad.yAxis.value < -0.5, 9)
            flag(micro.dpad.xAxis.value < -0.5, 10)
            flag(micro.dpad.xAxis.value > 0.5, 11)
        }

        var data = header(type: 1 << 1, payloadBytes: 24)
        var offset = 14
        // Native GameController and Xbox wire axes both use positive Y for up.
        let leftStick = applyDeadzone(x: gamepad?.leftThumbstick.xAxis.value ?? 0, y: gamepad?.leftThumbstick.yAxis.value ?? 0)
        let rightStick = applyDeadzone(x: gamepad?.rightThumbstick.xAxis.value ?? 0, y: gamepad?.rightThumbstick.yAxis.value ?? 0)
        data[offset] = 1; offset += 1 // one gamepad
        data[offset] = 0; offset += 1 // index
        data.writeLE(buttons, at: offset); offset += 2
        data.writeLE(axis(leftStick.x), at: offset); offset += 2
        data.writeLE(axis(leftStick.y), at: offset); offset += 2
        data.writeLE(axis(rightStick.x), at: offset); offset += 2
        data.writeLE(axis(rightStick.y), at: offset); offset += 2
        data.writeLE(trigger(gamepad?.leftTrigger.value ?? 0), at: offset); offset += 2
        data.writeLE(trigger(gamepad?.rightTrigger.value ?? 0), at: offset); offset += 2
        data.writeLE(UInt32(1), at: offset); offset += 4
        data.writeBE(UInt32(1), at: offset)
        send(data)
    }

    private func updateExitCombo(controller: GCController, buttons: UInt16) {
        ControllerExitGesture.updateHold(
            isPressed: ControllerExitGesture.isStartSelectHeld(
                controller: controller,
                logicalStart: (buttons & UInt16(1 << 2)) != 0,
                logicalSelect: (buttons & UInt16(1 << 3)) != 0
            ),
            heldSince: &exitComboHeldSince,
            didTrigger: &didTriggerExitCombo
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.exitComboHandler?()
            }
        }
    }

    private func header(type: UInt16, payloadBytes: Int) -> Data {
        var data = Data(count: 14 + payloadBytes)
        data.writeLE(type, at: 0)
        data.writeLE(sequence, at: 2)
        var timestamp = ProcessInfo.processInfo.systemUptime * 1000
        Swift.withUnsafeBytes(of: &timestamp) { bytes in
            data.replaceSubrange(6..<14, with: bytes)
        }
        sequence &+= 1
        return data
    }

    private func axis(_ value: Float) -> Int16 { Int16(max(-1, min(1, value)) * 32767) }
    private func trigger(_ value: Float) -> UInt16 { UInt16(max(0, min(1, value)) * 65535) }

    private func applyDeadzone(x: Float, y: Float) -> (x: Float, y: Float) {
        let magnitude = sqrt(x * x + y * y)
        guard magnitude > deadzone, magnitude > 0 else { return (0, 0) }
        let scaledMagnitude = min(1, (magnitude - deadzone) / (1 - deadzone))
        let scale = scaledMagnitude / magnitude
        return (x * scale, y * scale)
    }

    private func send(_ data: Data) {
        guard let channel, channel.readyState == .open else { return }
        channel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
    }
}

private extension Data {
    mutating func writeLE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xff); self[offset + 1] = UInt8(value >> 8)
    }
    mutating func writeLE(_ value: Int16, at offset: Int) { writeLE(UInt16(bitPattern: value), at: offset) }
    mutating func writeLE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xff); self[offset + 1] = UInt8((value >> 8) & 0xff)
        self[offset + 2] = UInt8((value >> 16) & 0xff); self[offset + 3] = UInt8(value >> 24)
    }
    mutating func writeBE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value >> 24); self[offset + 1] = UInt8((value >> 16) & 0xff)
        self[offset + 2] = UInt8((value >> 8) & 0xff); self[offset + 3] = UInt8(value & 0xff)
    }
}
