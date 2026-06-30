// HardwareBuddyLink.swift — CoreBluetooth link to a physical Claude Hardware Buddy.
//
// This is the piece that was missing: the macOS app rendered a virtual pet but had
// no way to pair with the real device that Claude Desktop's "Hardware Buddy & Maker
// Devices" panel talks to. `HardwareBuddyLink` is a CoreBluetooth central that:
//
//   • scans for a peripheral advertising the Nordic UART Service named "Claude…"
//   • connects, discovers the NUS RX (write) / TX (notify) characteristics
//   • sends TimeSync + a status query on connect
//   • streams `HeartbeatSnapshot` frames as session state changes
//   • parses inbound `CommandAck` / `PermissionDecision` frames
//   • pushes a data folder to the device ("Send to Device")
//
// macOS-only: CoreBluetooth is unavailable on Linux, so this file lives in the
// BuddyApp target (the Linux CLI path never references it). The wire types it uses
// live in BuddyCore (HardwareBuddyProtocol.swift) and are unit-tested on Linux.

#if canImport(CoreBluetooth)

import Foundation
// CoreBluetooth predates Swift's strict-concurrency checking and its types
// (CBCentralManager, CBPeripheral, CBService, CBCharacteristic) are not Sendable.
// @preconcurrency tells the compiler to apply the framework's original (pre-Swift 6)
// concurrency checking to those types, downgrading the "sending risks causing data
// races" region-isolation errors below to warnings instead of hard build failures —
// this is Apple's documented remedy for un-audited system frameworks.
@preconcurrency import CoreBluetooth
import BuddyCore

// MARK: - Pairing state

public enum BuddyLinkState: Equatable, Sendable {
    case bluetoothOff
    case idle
    case scanning
    case connecting(String)
    case paired(String)
    case failed(String)

    public var isPaired: Bool {
        if case .paired = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .bluetoothOff:        return "Bluetooth off"
        case .idle:                return "No buddy paired"
        case .scanning:            return "Searching…"
        case .connecting(let n):   return "Connecting to \(n)…"
        case .paired(let n):       return n
        case .failed(let e):       return "Error: \(e)"
        }
    }
}

// MARK: - Link

@MainActor
@Observable
public final class HardwareBuddyLink: NSObject {

    // Observable surface for the UI.
    public private(set) var state: BuddyLinkState = .idle
    public private(set) var deviceName: String? = nil
    public private(set) var battery: BatteryStatus? = nil
    public private(set) var deviceStats: DeviceStats? = nil
    public private(set) var lastError: String? = nil
    /// Bytes pushed / total during a folder transfer (nil when idle).
    public private(set) var pushProgress: (sent: Int, total: Int)? = nil

    /// Invoked on the main actor whenever the *device* reports a permission decision.
    public var onPermissionDecision: ((PermissionDecision) -> Void)? = nil

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?   // device RX — we write here
    private var txCharacteristic: CBCharacteristic?   // device TX — we subscribe

    private let codec = HardwareBuddyCodec()
    private let lineBuffer = LineBuffer()
    private let serviceID  = CBUUID(string: NordicUART.serviceUUID)
    private let rxID       = CBUUID(string: NordicUART.rxWriteUUID)
    private let txID       = CBUUID(string: NordicUART.txNotifyUUID)

    /// A queued frame plus whether it counts toward folder-push progress. Heartbeats,
    /// status, and TimeSync interleave with a push, so only push frames advance the bar.
    private struct OutFrame { let data: Data; let isPush: Bool }
    /// Queue of frames awaiting a writable characteristic / write-with-response slot.
    private var outbox: [OutFrame] = []
    private var lastSnapshot: HeartbeatSnapshot? = nil

    /// How long `connect()` scans before giving up if no Claude-prefixed peripheral
    /// answers. Without this, `central.scanForPeripherals` runs indefinitely —
    /// burning radio/battery forever in the (common, expected) case where no
    /// physical Hardware Buddy device is present.
    private static let scanTimeout: Duration = .seconds(15)
    private var scanTimeoutTask: Task<Void, Never>? = nil

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Pairing controls (driven by the UI)

    /// Begin scanning for a Claude buddy. No-op if Bluetooth is unavailable.
    /// Re-entrant: calling this again while already scanning just restarts the
    /// timeout rather than stacking a second scan.
    public func connect() {
        guard central.state == .poweredOn else {
            state = .bluetoothOff
            return
        }
        guard !state.isPaired else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [serviceID], options: nil)

        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.scanTimeout)
            guard !Task.isCancelled else { return }
            self?.stopScanningIfTimedOut()
        }
    }

    /// Cancel an in-progress scan (button-driven or from the timeout) without
    /// touching a connection that already exists — distinct from `disconnect()`,
    /// which also tears down an active/connecting peripheral.
    private func stopScanningIfTimedOut() {
        guard case .scanning = state else { return }
        central.stopScan()
        scanTimeoutTask = nil
        state = .idle
    }

    /// Disconnect and forget the current device (sends `unpair` first if linked).
    /// Also safe to call while merely *scanning* (no peripheral yet) — it always
    /// stops the scan so the radio never keeps running after the UI says idle.
    public func disconnect(unpairDevice: Bool = false) {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        central.stopScan()
        if unpairDevice, rxCharacteristic != nil {
            enqueue(DesktopCommand.unpair)
        }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        teardown()
        state = .idle
    }

    // MARK: - Sending state

    /// Push the latest session snapshot to the device. Deduplicated: identical
    /// consecutive snapshots are dropped to spare the BLE link.
    public func send(_ snapshot: HeartbeatSnapshot) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        enqueue(snapshot)
    }

    /// Rename the device.
    public func rename(to name: String) { enqueue(DesktopCommand.name(name)) }

    /// Set the owner shown on the device.
    public func setOwner(_ name: String) { enqueue(DesktopCommand.owner(name)) }

    /// Push a data folder to the device (the panel's "Send to Device" action).
    public func sendFolder(_ directory: URL, name: String? = nil) {
        do {
            let cmds = try FolderPush.commands(for: directory, name: name)
            // Drop any push frames still queued from a previous transfer so the
            // progress counter reflects only this push.
            outbox.removeAll { $0.isPush }
            pushProgress = (0, cmds.count)
            for cmd in cmds { enqueue(cmd, isPush: true) }
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Outbox

    private func enqueue<T: Encodable>(_ value: T, isPush: Bool = false) {
        guard let frame = try? codec.frame(value) else { return }
        outbox.append(OutFrame(data: frame, isPush: isPush))
        flush()
    }

    private func flush() {
        guard let peripheral, let rx = rxCharacteristic else { return }
        // Prefer write-with-response when the characteristic supports it so the
        // firmware can pace us; fall back to without-response otherwise.
        let type: CBCharacteristicWriteType =
            rx.properties.contains(.write) ? .withResponse : .withoutResponse

        while !outbox.isEmpty {
            if type == .withResponse {
                // Only one response-paced write outstanding at a time; the rest
                // drain from didWriteValueFor.
                if rxInFlight { break }
                let frame = outbox.removeFirst()
                rxInFlight = true
                rxInFlightPush = frame.isPush
                peripheral.writeValue(frame.data, for: rx, type: .withResponse)
                break
            } else {
                // Respect the without-response flow-control signal.
                guard peripheral.canSendWriteWithoutResponse else { break }
                let frame = outbox.removeFirst()
                peripheral.writeValue(frame.data, for: rx, type: .withoutResponse)
                if frame.isPush { advancePushProgress() }
            }
        }
    }

    private var rxInFlight = false
    /// Whether the response-paced write currently in flight is a folder-push frame.
    private var rxInFlightPush = false

    private func advancePushProgress() {
        if var p = pushProgress {
            p.sent = min(p.sent + 1, p.total)
            pushProgress = p.sent >= p.total ? nil : p
        }
    }

    private func teardown() {
        peripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        outbox.removeAll()
        lastSnapshot = nil
        rxInFlight = false
        rxInFlightPush = false
        pushProgress = nil
        battery = nil
        deviceStats = nil
    }

    // MARK: - Inbound frame handling

    private func handleInbound(_ chunk: Data) {
        for line in lineBuffer.append(chunk) {
            // A device→desktop frame is either a CommandAck or a PermissionDecision.
            if let decision = try? JSONDecoder().decode(PermissionDecision.self, from: line),
               decision.cmd == "permission" {
                onPermissionDecision?(decision)
                continue
            }
            if let ack = try? JSONDecoder().decode(CommandAck.self, from: line) {
                apply(ack)
            }
        }
    }

    private func apply(_ ack: CommandAck) {
        if let data = ack.data {
            deviceName = data.name
            battery = data.bat
            deviceStats = data.stats
            if case .connecting = state { state = .paired(data.name) }
        }
        if !ack.ok, let err = ack.error { lastError = err }
    }
}

// MARK: - CBCentralManagerDelegate

extension HardwareBuddyLink: CBCentralManagerDelegate {

    // NOTE: CoreBluetooth delegate methods are protocol-required `nonisolated`, but
    // this central is constructed with `queue: .main` (see `init`), so callbacks are
    // *always* actually delivered on the main actor's executor. We use
    // `MainActor.assumeIsolated` (synchronous, same-frame) rather than
    // `Task { @MainActor in … }` (unstructured, async) because spawning a Task hands
    // the non-Sendable CoreBluetooth objects (CBCentralManager/CBPeripheral/CBService)
    // across an isolation boundary, which Swift 6's region isolation checker flags as
    // a potential data race ("sending risks causing data races"). assumeIsolated runs
    // the closure synchronously on the spot, so nothing is actually sent anywhere.

    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if case .scanning = self.state {
                    central.scanForPeripherals(withServices: [self.serviceID], options: nil)
                }
            case .poweredOff, .unauthorized, .unsupported:
                self.state = .bluetoothOff
                self.teardown()
            default:
                break
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                           didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any],
                                           rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "buddy"
        guard advName.hasPrefix(NordicUART.namePrefix) else { return }
        MainActor.assumeIsolated {
            central.stopScan()
            self.scanTimeoutTask?.cancel()
            self.scanTimeoutTask = nil
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state = .connecting(advName)
            central.connect(peripheral, options: nil)
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                           didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([self.serviceID])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                           didFailToConnect peripheral: CBPeripheral,
                                           error: Error?) {
        MainActor.assumeIsolated {
            self.state = .failed(error?.localizedDescription ?? "connect failed")
            self.teardown()
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                           didDisconnectPeripheral peripheral: CBPeripheral,
                                           error: Error?) {
        MainActor.assumeIsolated {
            self.teardown()
            self.state = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension HardwareBuddyLink: CBPeripheralDelegate {

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
                                       didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let svc = peripheral.services?.first(where: { $0.uuid == self.serviceID }) else {
                self.state = .failed("NUS service not found")
                return
            }
            peripheral.discoverCharacteristics([self.rxID, self.txID], for: svc)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
                                       didDiscoverCharacteristicsFor service: CBService,
                                       error: Error?) {
        MainActor.assumeIsolated {
            for ch in service.characteristics ?? [] {
                if ch.uuid == self.rxID { self.rxCharacteristic = ch }
                if ch.uuid == self.txID {
                    self.txCharacteristic = ch
                    peripheral.setNotifyValue(true, for: ch)
                }
            }
            guard self.rxCharacteristic != nil else {
                self.state = .failed("RX characteristic missing")
                return
            }
            // Optimistically mark paired; a status ack refines the name.
            if case .connecting(let n) = self.state { self.state = .paired(n) }
            self.enqueue(TimeSync.now())
            self.enqueue(DesktopCommand.status)
            if let snap = self.lastSnapshot { self.enqueue(snap) }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
                                       didUpdateValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        guard let value = characteristic.value else { return }
        MainActor.assumeIsolated { self.handleInbound(value) }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
                                       didWriteValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        MainActor.assumeIsolated {
            self.rxInFlight = false
            if self.rxInFlightPush { self.advancePushProgress() }
            self.rxInFlightPush = false
            self.flush()
        }
    }

    public nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.flush() }
    }
}

#endif
