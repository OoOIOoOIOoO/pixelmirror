import Foundation
import LocalAuthentication
import Security
import SwiftUI

/// Android hides its PIN screen from every capture, so the mirror goes black there.
/// The PIN is typed on the Mac instead, and the app opens that screen and enters it.
enum PhoneUnlock {
  /// The PIN screen is the only one that captures as pure black, a tiny PNG.
  private static let black = "[ $(screencap -p | wc -c) -lt 100000 ]"

  /// Whether the phone is locked and, only then, whether its PIN screen is open.
  static func state(_ transport: String) -> (locked: Bool, pinScreen: Bool) {
    let script = """
      dumpsys window policy | grep -A1 KeyguardServiceDelegate | grep -q showing=true || exit
      echo locked; \(black) && echo pin
      """
    let out = ADB.shell(transport, script)
    return (out.contains("locked"), out.hasSuffix("pin"))
  }

  /// Wakes the phone and opens its PIN screen, unless it is open already.
  /// A fingerprint prompt sometimes takes the first swipe, so it tries again,
  /// after giving a slow PIN screen time to open.
  static func openPINScreen(_ transport: String) -> Bool {
    let script = """
      black() { \(black); }
      black && { echo ready; exit; }
      input keyevent KEYCODE_WAKEUP; sleep 0.4
      set -- $(wm size | grep -o '[0-9]*x[0-9]*' | tail -1 | tr x ' ')
      for try in 1 2; do
        input tap $(($1/2)) $(($2/6)); sleep 0.5
        input touchscreen swipe $(($1/2)) $(($2*9/10)) $(($1/2)) $(($2*3/10)) 400
        for wait in 1 2 3 4; do sleep 0.4; black && { echo ready; exit; }; done
      done
      """
    return ADB.shell(transport, script, timeout: 15).hasSuffix("ready")
  }
}

/// A phone's PIN, kept in this Mac's keychain only behind Touch ID, never synced.
enum PhonePIN {
  private static let service = "com.reffwu.pixelmirror.phone-pin"
  private static func savedKey(_ id: String) -> String { "pinSaved.\(id)" }

  static var canUseTouchID: Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
  }

  static func isSaved(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: savedKey(id)) }

  /// False when this Mac or this build can't keep it, such as a Mac without a password.
  @discardableResult
  static func save(_ pin: String, for id: String) -> Bool {
    delete(id)
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil)
    else { return false }
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecValueData as String: Data(pin.utf8),
      kSecAttrAccessControl as String: access,
      kSecUseDataProtectionKeychain as String: true,
    ]
    let saved = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    UserDefaults.standard.set(saved, forKey: savedKey(id))
    return saved
  }

  /// Asks for Touch ID. Nil if it was cancelled; a PIN Touch ID no longer opens is forgotten.
  static func read(_ id: String, reason: String) -> String? {
    let context = LAContext()
    context.localizedReason = reason
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
      kSecUseDataProtectionKeychain as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { delete(id) }
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  static func delete(_ id: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecUseDataProtectionKeychain as String: true,
    ]
    SecItemDelete(query as CFDictionary)
    UserDefaults.standard.removeObject(forKey: savedKey(id))
  }
}

@MainActor
final class UnlockModel: ObservableObject {
  @Published var pin = ""
  @Published var remember = false
  @Published var working = false
  @Published var problem: String?
  @Published var saved = false
  @Published var canRemember = PhonePIN.canUseTouchID
  var onTouchID: () -> Void = {}
}

/// Sits over the black PIN screen. Keys go to the mirror, which hands the PIN here.
struct UnlockCard: View {
  @ObservedObject var model: UnlockModel

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "lock.fill").font(.system(size: 20))
      Text("Unlock the phone").font(.system(size: 13, weight: .semibold))
      Group {
        if model.pin.isEmpty {
          Text("Type the PIN, then press Return")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
          HStack(spacing: 8) {
            ForEach(Array(model.pin.indices), id: \.self) { _ in
              Circle().frame(width: 9, height: 9)
            }
          }
        }
      }
      .frame(height: 16)
      if model.working {
        ProgressView().controlSize(.small)
      } else if model.saved {
        Button {
          model.onTouchID()
        } label: {
          Label("Unlock with Touch ID", systemImage: "touchid")
        }
        .focusable(false)
      } else if model.canRemember {
        Toggle("Remember with Touch ID", isOn: $model.remember)
          .toggleStyle(.checkbox)
          .font(.system(size: 11))
          .focusable(false)
      }
      if let problem = model.problem {
        Text(problem).font(.system(size: 11)).foregroundStyle(.red)
      }
    }
    .padding(18)
    .frame(width: 240)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .environment(\.colorScheme, .dark)
  }
}
