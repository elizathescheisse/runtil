import Foundation
import CoreBluetooth
import Observation
import RuntilCore

/// Talks to a Bluetooth heart rate monitor.
///
/// Uses the standard Bluetooth SIG Heart Rate Service (0x180D), which anything worth
/// buying implements — chest straps, optical armbands, some earbuds and bike computers.
/// So there's no per-brand code here, and no vendor SDK.
///
/// This is what makes heart-rate plans work without an Apple Watch. A chest strap in
/// particular tends to beat a wrist optical sensor during running, where arm motion and
/// cadence lock cause trouble.
@Observable
final class HeartRateMonitor: NSObject {

    enum State: Equatable {
        case unavailable(String)
        case idle
        case scanning
        case connecting(String)
        case connected(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }

        var description: String {
            switch self {
            case .unavailable(let why): return why
            case .idle: return "Not connected"
            case .scanning: return "Searching…"
            case .connecting(let name): return "Connecting to \(name)…"
            case .connected(let name): return name
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var heartRate: Int?
    /// Set when the monitor reports it isn't making skin contact — worth surfacing,
    /// because the usual cause is a dry sensor giving nonsense readings.
    private(set) var poorContact = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private static let heartRateService = CBUUID(string: "180D")
    private static let measurementCharacteristic = CBUUID(string: "2A37")

    /// Remembered so a monitor that drops mid-run can be picked up again without asking.
    private var lastKnownIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: "hrMonitorID").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "hrMonitorID") }
    }

    override init() {
        super.init()
    }

    /// Creating the central manager triggers the Bluetooth permission prompt, so it's
    /// deferred until the user actually asks to connect a monitor.
    func startScanning() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            return   // scanning begins once the radio reports ready
        }
        beginScan()
    }

    func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        heartRate = nil
        lastKnownIdentifier = nil
        state = .idle
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }

        // Reconnect silently to a monitor we've used before, if it's already awake.
        if let id = lastKnownIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(to: known)
            return
        }

        state = .scanning
        central.scanForPeripherals(withServices: [Self.heartRateService])
    }

    private func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting(peripheral.name ?? "Monitor")
        central?.stopScan()
        central?.connect(peripheral)
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateMonitor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginScan()
        case .poweredOff:
            state = .unavailable("Bluetooth is off")
        case .unauthorized:
            state = .unavailable("Bluetooth permission denied")
        case .unsupported:
            state = .unavailable("Bluetooth isn't available")
        default:
            state = .idle
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        lastKnownIdentifier = peripheral.identifier
        state = .connected(peripheral.name ?? "Monitor")
        peripheral.discoverServices([Self.heartRateService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        heartRate = nil
        state = .scanning
        // Monitors drop out when they slip or the battery sags. Keep trying rather than
        // silently stopping — losing heart rate mid-run shouldn't need a phone in hand.
        central.connect(peripheral)
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService })
        else { return }
        peripheral.discoverCharacteristics([Self.measurementCharacteristic], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == Self.measurementCharacteristic })
        else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value,
              let reading = HeartRateMeasurement.parse(data)
        else { return }
        heartRate = reading.bpm
        poorContact = reading.isPoorContact
    }
}
