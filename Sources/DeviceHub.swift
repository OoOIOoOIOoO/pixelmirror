import Foundation
import SwiftUI

/// One phone, however many ways it is attached (a cable and Wi-Fi at once count once).
struct Phone: Identifiable, Equatable {
  var id: String  // hardware serial
  var name: String
  var android: String
  var transport: String  // the adb serial to talk to
  var isUSB: Bool
}

struct KnownPhone: Codable, Equatable, Identifiable {
  var id: String
  var name: String
}

/// Watches USB and the local network all the time, connects every phone it is
/// allowed to, and pairs new ones from a QR code or a pairing code.
@MainActor
final class DeviceHub: ObservableObject {
  static let shared = DeviceHub()

  @Published private(set) var phones: [Phone] = []
  @Published private(set) var needsUSBApproval = false
  @Published private(set) var known: [KnownPhone] = []
  @Published private(set) var pairing = PairingState.idle
  @Published private(set) var qr = PairingQR.make()

  enum PairingState: Equatable {
    case idle, pairing, paired, failed
  }

  /// Called whenever a phone becomes ready, and whenever the set of phones changes.
  var onPhoneReady: ((Phone) -> Void)?
  var onPhonesChanged: (([Phone]) -> Void)?

  private let worker = HubWorker()
  private let queue = DispatchQueue(label: "com.reffwu.pixelmirror.hub")
  private var timer: Timer?
  private var scanning = false
  private var typedCode: String?
  private var readyIDs: Set<String> = []

  private init() {
    if let data = UserDefaults.standard.data(forKey: "knownPhones"),
      let list = try? JSONDecoder().decode([KnownPhone].self, from: data)
    {
      known = list
    }
  }

  func start() {
    guard timer == nil else { return }
    scan()
    timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.scan() }
    }
  }

  /// Pair with the six-digit code shown under "Pair device with pairing code".
  func pair(withCode code: String) {
    typedCode = code
    pairing = .pairing
    scan()
  }

  func resetPairing() {
    if pairing != .pairing { pairing = .idle }
  }

  // MARK: - Scanning

  private func scan() {
    guard !scanning else { return }
    scanning = true
    let request = HubWorker.Request(qr: qr, typedCode: typedCode)
    queue.async { [worker] in
      let result = worker.scan(request) { started in
        DispatchQueue.main.async { if started { self.pairing = .pairing } }
      }
      DispatchQueue.main.async { self.apply(result, request: request) }
    }
  }

  private func apply(_ result: HubWorker.Result, request: HubWorker.Request) {
    scanning = false
    if let paired = result.paired {
      if request.typedCode != nil, request.typedCode == typedCode { typedCode = nil }
      pairing = paired ? .paired : .failed
      if paired { qr = PairingQR.make() }
    }
    if phones != result.phones {
      phones = result.phones
      onPhonesChanged?(result.phones)
    }
    if needsUSBApproval != result.unauthorized { needsUSBApproval = result.unauthorized }

    for phone in result.phones where !readyIDs.contains(phone.id) {
      remember(phone)
      onPhoneReady?(phone)
    }
    readyIDs = Set(result.phones.map(\.id))
  }

  private func remember(_ phone: Phone) {
    if let index = known.firstIndex(where: { $0.id == phone.id }) {
      guard known[index].name != phone.name else { return }
      known[index].name = phone.name
    } else {
      known.append(KnownPhone(id: phone.id, name: phone.name))
    }
    if let data = try? JSONEncoder().encode(known) {
      UserDefaults.standard.set(data, forKey: "knownPhones")
    }
  }
}

/// The part of the hub that talks to adb. Only ever used on the hub's queue.
final class HubWorker: @unchecked Sendable {
  struct Request {
    var qr: PairingQR
    var typedCode: String?
  }

  struct Result {
    var phones: [Phone] = []
    var unauthorized = false
    var paired: Bool?
  }

  private struct Identity {
    var id: String
    var name: String
    var android: String
  }

  private var identities: [String: Identity] = [:]
  private var lastAttempt: [String: Date] = [:]
  private var started = false

  func scan(_ request: Request, pairingStarted: (Bool) -> Void) -> Result {
    if !started {
      ADB.run(["start-server"], timeout: 15)
      started = true
    }
    var result = Result()
    let services = ADB.services()

    // Pairing: the phone advertises a pairing service named after our QR code,
    // or a pairing service of its own while someone types its pairing code.
    let pairingServices = services.filter { $0.type.hasPrefix("_adb-tls-pairing") }
    if let service = pairingServices.first(where: { $0.name == request.qr.name }) {
      pairingStarted(true)
      result.paired = ADB.pair(service.address, code: request.qr.password)
    } else if let code = request.typedCode, let service = pairingServices.first {
      result.paired = ADB.pair(service.address, code: code)
    }

    // Connect every phone that offers wireless debugging and is not attached yet.
    var devices = ADB.devices()
    let attachedIDs = Set(devices.compactMap { identities[$0.serial]?.id ?? impliedID(of: $0) })
    let attachedSerials = Set(devices.map(\.serial))
    var connected = false
    for service in services where service.type.hasPrefix("_adb-tls-connect") {
      if attachedSerials.contains(service.address) { continue }
      if let id = ADB.serial(fromServiceName: service.name), attachedIDs.contains(id) { continue }
      if let last = lastAttempt[service.address], Date().timeIntervalSince(last) < 4 { continue }
      lastAttempt[service.address] = Date()
      if ADB.connect(service.address) { connected = true }
    }
    if connected || result.paired == true { devices = ADB.devices() }

    // Learn who each attachment is, once per attachment.
    let present = Set(devices.map(\.serial))
    identities = identities.filter { present.contains($0.key) }
    for device in devices where device.state == "device" && identities[device.serial] == nil {
      identities[device.serial] = identify(device)
    }

    var byID: [String: Phone] = [:]
    for device in devices where device.state == "device" {
      guard let identity = identities[device.serial] else { continue }
      if let existing = byID[identity.id], existing.isUSB { continue }
      byID[identity.id] = Phone(
        id: identity.id, name: identity.name, android: identity.android,
        transport: device.serial, isUSB: device.isUSB)
    }
    result.phones = byID.values.sorted { $0.name < $1.name }
    result.unauthorized = devices.contains { $0.isUSB && $0.state == "unauthorized" }
    return result
  }

  /// A cable's serial is the hardware serial; adb's own mDNS connections carry it in the name.
  private func impliedID(of device: ADB.Device) -> String? {
    if device.isUSB { return device.serial }
    if device.serial.hasPrefix("adb-"), let name = device.serial.split(separator: ".").first {
      return ADB.serial(fromServiceName: String(name))
    }
    return nil
  }

  private func identify(_ device: ADB.Device) -> Identity {
    let lines = ADB.shell(
      device.serial,
      "getprop ro.serialno; settings get global device_name; getprop ro.build.version.release"
    )
    .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let serial = lines.first ?? ""
    var name = lines.count > 1 ? lines[1] : ""
    if name.isEmpty || name == "null" { name = device.model.isEmpty ? "Android" : device.model }
    return Identity(
      id: serial.isEmpty ? device.serial : serial, name: name,
      android: lines.count > 2 ? lines[2] : "")
  }
}

/// The QR code Android's "Pair device with QR code" scanner understands.
struct PairingQR: Equatable {
  var name: String
  var password: String

  var payload: String { "WIFI:T:ADB;S:\(name);P:\(password);;" }

  static func make() -> PairingQR {
    let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
    func random(_ count: Int) -> String {
      String((0..<count).map { _ in letters.randomElement()! })
    }
    return PairingQR(name: "pixelmirror-\(random(6))", password: random(10))
  }
}
