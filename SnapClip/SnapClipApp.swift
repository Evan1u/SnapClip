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
      Image(systemName: model.isIconFlashing ? "camera.fill" : "camera")
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
