import AppKit
import Foundation

/// Owns the shared NSColorPanel for one editor color transaction.
@MainActor
final class ColorPanelCoordinator: NSObject {
  private var completion: ((RGBAColor) -> Void)?
  private var preview: ((RGBAColor) -> Void)?
  private var cancel: (() -> Void)?
  private var lastValidColor: RGBAColor?

  func present(
    initialColor: RGBAColor,
    onColor: @escaping (RGBAColor) -> Void,
    onPreview: @escaping (RGBAColor) -> Void,
    onCancel: @escaping () -> Void
  ) {
    closeIfNeeded()
    lastValidColor = initialColor
    completion = onColor
    preview = onPreview
    cancel = onCancel

    let panel = NSColorPanel.shared
    panel.color = NSColor(
      srgbRed: initialColor.red,
      green: initialColor.green,
      blue: initialColor.blue,
      alpha: initialColor.alpha
    )
    panel.isContinuous = true
    panel.setTarget(self)
    panel.setAction(#selector(colorChanged(_:)))
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(panelWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: panel
    )
  }

  func closeIfNeeded() {
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.willCloseNotification,
      object: NSColorPanel.shared
    )
    NSColorPanel.shared.close()
    if let lastValidColor {
      completion?(lastValidColor)
    }
    completion = nil
    preview = nil
    cancel = nil
    lastValidColor = nil
  }

  func cancelColorTransaction() {
    guard NSColorPanel.shared.isVisible else { return }
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.willCloseNotification,
      object: NSColorPanel.shared
    )
    NSColorPanel.shared.close()
    cancel?()
    completion = nil
    preview = nil
    cancel = nil
    lastValidColor = nil
  }

  var isPresenting: Bool {
    NSColorPanel.shared.isVisible
  }

  @objc private func colorChanged(_ sender: NSColorPanel) {
    guard let color = sender.color.usingColorSpace(.sRGB) else { return }
    lastValidColor = RGBAColor(
      red: color.redComponent,
      green: color.greenComponent,
      blue: color.blueComponent,
      alpha: color.alphaComponent
    )
    if let lastValidColor {
      preview?(lastValidColor)
    }
  }

  @objc private func panelWillClose(_ notification: Notification) {
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.willCloseNotification,
      object: notification.object
    )
    if let lastValidColor {
      completion?(lastValidColor)
    }
    completion = nil
    preview = nil
    cancel = nil
    lastValidColor = nil
  }
}
