import AppKit
import SwiftUI

@main
struct SnapClipApp: App {
  @StateObject private var model = AppModel()

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(model: model)
    } label: {
      Image("MenuBarScissors")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 16, height: 16)
        .opacity(model.isIconFlashing ? 0.42 : 1)
        .scaleEffect(model.isIconFlashing ? 0.9 : 1)
        .animation(.easeOut(duration: 0.12), value: model.isIconFlashing)
        .accessibilityLabel("SnapClip")
        .onAppear {
          model.start()
        }
    }
    .menuBarExtraStyle(.window)

    Settings {
      PreferencesView(model: model)
    }
  }
}
