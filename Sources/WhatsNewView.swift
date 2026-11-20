import AppKit
import SwiftUI

struct WhatsNewFeature: Identifiable {
  let id = UUID()
  let symbol: String
  let tint: Color
  let title: String
  let subtitle: String
}

struct WhatsNewView: View {
  var onContinue: () -> Void

  // 默认由子类或 App 自行配置特性列表
  var features: [WhatsNewFeature] = []

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 12)

      // 顶部大标题（严格对齐 Apple 官方设计规范）
      VStack(spacing: 8) {
        Text(String(localized: "What's New in PixelMirror"))
          .font(.system(size: 23, weight: .bold))
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 28)
      .padding(.top, 24)
      .padding(.bottom, 28)

      // 特征列表（带大尺寸生动 SF Symbol 图标）
      VStack(alignment: .leading, spacing: 22) {
        ForEach(features) { feature in
          HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(feature.tint.gradient)
              .frame(width: 38, height: 38)
              .overlay(
                Image(systemName: feature.symbol)
                  .font(.system(size: 20, weight: .semibold))
                  .foregroundStyle(.white)
              )
              .shadow(color: feature.tint.opacity(0.3), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 3) {
              Text(feature.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.primary)

              Text(feature.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            }
          }
        }
      }
      .padding(.horizontal, 32)

      Spacer(minLength: 24)

      // 底部宽幅大胶囊主按钮（匹配 Apple 官方主行动按钮）
      Button(action: onContinue) {
        Text(String(localized: "Continue"))
          .font(.system(size: 13.5, weight: .semibold))
          .frame(maxWidth: .infinity)
          .frame(height: 36)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.accentColor)
      .clipShape(Capsule())
      .keyboardShortcut(.defaultAction)
      .padding(.horizontal, 32)
      .padding(.bottom, 28)
    }
    .frame(width: 440, height: 470)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

@MainActor
final class WhatsNewManager: ObservableObject {
  static let shared = WhatsNewManager()

  private let key = "lastSeenWhatsNewVersion"
  @Published var isPresented = false

  var currentVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
  }

  func checkPresentation() {
    let defaults = UserDefaults.standard
    guard let lastSeen = defaults.string(forKey: key) else {
      defaults.set(currentVersion, forKey: key)
      return
    }

    if lastSeen != currentVersion {
      self.isPresented = true
    }
  }

  func dismiss() {
    UserDefaults.standard.set(currentVersion, forKey: key)
    isPresented = false
  }
}
