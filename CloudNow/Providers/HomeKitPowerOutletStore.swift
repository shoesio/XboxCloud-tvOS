import Foundation
import HomeKit
import Observation

struct HomeKitPowerOutlet: Identifiable, Hashable {
    let id: String
    let name: String
    let roomName: String?
    let isReachable: Bool
    let isOn: Bool?

    var displayName: String {
        guard let roomName, !roomName.isEmpty else { return name }
        return "\(name) · \(roomName)"
    }
}

enum HomeKitPowerOutletError: LocalizedError {
    case accessUnavailable
    case homeDataTimedOut
    case outletNotFound
    case outletUnreachable(String)
    case missingPowerCharacteristic(String)

    var errorDescription: String? {
        switch self {
        case .accessUnavailable:
            return "Stream does not have permission to access Apple Home."
        case .homeDataTimedOut:
            return "Apple Home did not finish loading its accessories."
        case .outletNotFound:
            return "The selected Apple Home power outlet could not be found. Choose it again in Settings."
        case .outletUnreachable(let name):
            return "The Apple Home outlet “\(name)” is not reachable."
        case .missingPowerCharacteristic(let name):
            return "The Apple Home accessory “\(name)” does not expose an on/off control."
        }
    }
}

@MainActor
@Observable
final class HomeKitPowerOutletStore: NSObject, HMHomeManagerDelegate {
    private static let selectionKey = "sunshine.homeKitPowerOutlet"

    private(set) var outlets: [HomeKitPowerOutlet] = []
    private(set) var hasStarted = false
    private(set) var isReady = false
    private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus = []
    var selectedOutletID: String {
        didSet {
            UserDefaults.standard.set(selectedOutletID, forKey: Self.selectionKey)
        }
    }

    @ObservationIgnored private var homeManager: HMHomeManager?

    override init() {
        selectedOutletID = UserDefaults.standard.string(forKey: Self.selectionKey) ?? ""
        super.init()
    }

    var hasSelectedOutlet: Bool {
        !selectedOutletID.isEmpty
    }

    var selectedOutlet: HomeKitPowerOutlet? {
        outlets.first { $0.id == selectedOutletID }
    }

    func start() {
        guard homeManager == nil else {
            refreshOutlets()
            return
        }
        let manager = HMHomeManager()
        manager.delegate = self
        homeManager = manager
        hasStarted = true
        authorizationStatus = manager.authorizationStatus
    }

    func refresh() async {
        start()
        try? await waitUntilReady()
        refreshOutlets()
    }

    func setSelectedOutletPower(_ enabled: Bool) async throws {
        guard hasSelectedOutlet else { return }
        start()
        try await waitUntilReady()
        guard authorizationStatus.contains(.authorized) else {
            throw HomeKitPowerOutletError.accessUnavailable
        }
        guard let target = liveOutlet(withID: selectedOutletID) else {
            throw HomeKitPowerOutletError.outletNotFound
        }
        guard target.accessory.isReachable else {
            throw HomeKitPowerOutletError.outletUnreachable(target.accessory.name)
        }
        guard let characteristic = target.service.characteristics.first(where: {
            $0.characteristicType == HMCharacteristicTypePowerState
        }) else {
            throw HomeKitPowerOutletError.missingPowerCharacteristic(target.accessory.name)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(enabled) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        characteristic.readValue { [weak self] _ in
            Task { @MainActor in self?.refreshOutlets() }
        }
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        authorizationStatus = manager.authorizationStatus
        isReady = true
        refreshOutlets()
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        authorizationStatus = status
        refreshOutlets()
    }

    private func waitUntilReady() async throws {
        for _ in 0..<30 {
            if isReady { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        throw HomeKitPowerOutletError.homeDataTimedOut
    }

    private func refreshOutlets() {
        guard let homeManager else { return }
        authorizationStatus = homeManager.authorizationStatus
        outlets = homeManager.homes
            .flatMap(\.accessories)
            .flatMap { accessory in
                accessory.services.compactMap { service -> HomeKitPowerOutlet? in
                    guard service.serviceType == HMServiceTypeOutlet || service.serviceType == HMServiceTypeSwitch,
                          let characteristic = service.characteristics.first(where: {
                              $0.characteristicType == HMCharacteristicTypePowerState
                          }) else {
                        return nil
                    }
                    let id = Self.outletID(accessory: accessory, service: service)
                    let value = (characteristic.value as? NSNumber)?.boolValue
                    return HomeKitPowerOutlet(
                        id: id,
                        name: accessory.name,
                        roomName: accessory.room?.name,
                        isReachable: accessory.isReachable,
                        isOn: value
                    )
                }
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        for home in homeManager.homes {
            for accessory in home.accessories {
                for service in accessory.services where service.serviceType == HMServiceTypeOutlet || service.serviceType == HMServiceTypeSwitch {
                    service.characteristics
                        .first { $0.characteristicType == HMCharacteristicTypePowerState }?
                        .readValue { [weak self] _ in
                            Task { @MainActor in self?.refreshValuesOnly() }
                        }
                }
            }
        }
    }

    private func refreshValuesOnly() {
        guard let homeManager else { return }
        outlets = outlets.map { outlet in
            guard let target = liveOutlet(withID: outlet.id, manager: homeManager),
                  let characteristic = target.service.characteristics.first(where: {
                      $0.characteristicType == HMCharacteristicTypePowerState
                  }) else {
                return outlet
            }
            return HomeKitPowerOutlet(
                id: outlet.id,
                name: target.accessory.name,
                roomName: target.accessory.room?.name,
                isReachable: target.accessory.isReachable,
                isOn: (characteristic.value as? NSNumber)?.boolValue
            )
        }
    }

    private func liveOutlet(withID id: String) -> (accessory: HMAccessory, service: HMService)? {
        guard let homeManager else { return nil }
        return liveOutlet(withID: id, manager: homeManager)
    }

    private func liveOutlet(
        withID id: String,
        manager: HMHomeManager
    ) -> (accessory: HMAccessory, service: HMService)? {
        for accessory in manager.homes.flatMap(\.accessories) {
            for service in accessory.services where Self.outletID(accessory: accessory, service: service) == id {
                return (accessory, service)
            }
        }
        return nil
    }

    private static func outletID(accessory: HMAccessory, service: HMService) -> String {
        "\(accessory.uniqueIdentifier.uuidString)|\(service.uniqueIdentifier.uuidString)"
    }
}
