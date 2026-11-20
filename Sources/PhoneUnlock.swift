import Foundation
import LocalAuthentication
import Security
import SwiftUI

/// Android hides its PIN screen from every capture, so the mirror goes black there.
/// The PIN is typed on the Mac instead, and the app opens that screen and enters it.
enum PhoneUnlock {
  /// Wakes the phone and opens its PIN screen, unless it is open already.
  /// That screen is the only one that captures as pure black, a tiny PNG.
  static func openPINScreen(_ transport: String) -> Bool {
    let script = """
      black() { [ $(screencap -p | wc -c) -lt 100000 ]; }
      black && { echo ready; exit; }
      input keyevent KEYCODE_WAKEUP; sleep 0.4
      set -- $(wm size | grep -o '[0-9]*x[0-9]*' | tail -1 | tr x ' ')
      input tap $(($1/2)) $(($2/6)); sleep 0.5
      input touchscreen swipe $(($1/2)) $(($2*9/10)) $(($1/2)) $(($2*3/10)) 400; sleep 0.9
      black && echo ready
      """
    return ADB.shell(transport, script, timeout: 10).hasSuffix("ready")
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
  @Published var focus = 0
  @Published var canRemember = PhonePIN.canUseTouchID
  var onUnlock: (String, Bool) -> Void = { _, _ in }
  var onTouchID: () -> Void = {}
}

struct UnlockCard: View {
  @ObservedObject var model: UnlockModel
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Unlock the phone", systemImage: "lock.fill")
        .font(.system(size: 13, weight: .semibold))
      HStack(spacing: 8) {
        SecureField("PIN", text: $model.pin)
          .textFieldStyle(.roundedBorder)
          .frame(width: 160)
          .focused($focused)
          .onSubmit(submit)
          .disabled(model.working)
        if model.saved {
          Button {
            model.onTouchID()
          } label: {
            Image(systemName: "touchid").font(.system(size: 15))
          }
          .help(String(localized: "Unlock with Touch ID"))
          .disabled(model.working)
        }
        Button("Unlock", action: submit)
          .disabled(model.pin.isEmpty || model.working)
        if model.working { ProgressView().controlSize(.small) }
      }
      if !model.saved, model.canRemember {
        Toggle("Remember with Touch ID", isOn: $model.remember)
          .toggleStyle(.checkbox)
          .font(.system(size: 11))
      }
      if let problem = model.problem {
        Text(problem).font(.system(size: 11)).foregroundStyle(.red)
      }
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .environment(\.colorScheme, .dark)
    .onAppear { focused = true }
    .onChange(of: model.focus) { focused = true }
  }

  private func submit() {
    guard !model.pin.isEmpty, !model.working else { return }
    model.onUnlock(model.pin, model.remember)
  }
}
