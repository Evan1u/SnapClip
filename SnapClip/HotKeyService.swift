import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SwiftUI

enum HotKeyRegistrationError: LocalizedError, Equatable {
  case eventHandlerInstallationFailed(OSStatus)
  case registrationFailed(OSStatus)
  case duplicateShortcut
  case accessibilityPermissionRequired
  case eventTapCreationFailed
  case serviceUnavailable

  var errorDescription: String? {
    switch self {
    case .eventHandlerInstallationFailed(let status):
      return "无法启动快捷键监听（状态码：\(status)）。"
    case .registrationFailed(let status):
      return "快捷键已被系统或其他应用占用（状态码：\(status)）。"
    case .duplicateShortcut:
      return "两个 SnapClip 功能不能使用相同快捷键。"
    case .accessibilityPermissionRequired:
      return "使用系统截图快捷键需要先授予 SnapClip 辅助功能权限。"
    case .eventTapCreationFailed:
      return "无法接管系统截图快捷键，请重新授权辅助功能权限后重试。"
    case .serviceUnavailable:
      return "快捷键服务当前不可用，请重新启动 SnapClip。"
    }
  }
}

@MainActor
protocol HotKeyServing: AnyObject {
  var accessibilityPermissionGranted: Bool { get }
  func setActionHandler(_ handler: @escaping (HotKeyAction) -> Void)
  func reconfigure(_ newShortcuts: [HotKeyAction: HotKeyShortcut]) throws
  func setRecordingMode(_ active: Bool) throws
  @discardableResult func requestAccessibilityPermission() -> Bool
  func openAccessibilitySettings()
  func stop()
}

extension Notification.Name {
  static let snapClipSystemShortcutRecorded = Notification.Name(
    "SnapClipSystemShortcutRecorded"
  )
}

private let systemShortcutEventCallback: CGEventTapCallBack = {
  _, type, event, userData in
  guard let userData else {
    return Unmanaged.passUnretained(event)
  }

  let interceptor = Unmanaged<SystemShortcutInterceptor>
    .fromOpaque(userData)
    .takeUnretainedValue()
  return interceptor.handle(type: type, event: event)
}

final class SystemShortcutInterceptor: @unchecked Sendable {
  typealias Handler = @Sendable (HotKeyAction) -> Void

  private let lock = NSLock()
  private let handler: Handler
  private var shortcuts: [HotKeyAction: HotKeyShortcut] = [:]
  private var isRecording = false
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func prepare(promptForPermission: Bool) throws {
    lock.lock()
    let isPrepared = eventTap != nil
    lock.unlock()
    if isPrepared { return }

    let options: CFDictionary?
    if promptForPermission {
      options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    } else {
      options = nil
    }

    guard AXIsProcessTrustedWithOptions(options) else {
      throw HotKeyRegistrationError.accessibilityPermissionRequired
    }

    let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: systemShortcutEventCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      throw HotKeyRegistrationError.eventTapCreationFailed
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)

    lock.lock()
    self.eventTap = eventTap
    runLoopSource = source
    lock.unlock()
  }

  func configure(_ shortcuts: [HotKeyAction: HotKeyShortcut]) {
    lock.lock()
    self.shortcuts = shortcuts
    lock.unlock()
  }

  func setRecording(_ active: Bool) {
    lock.lock()
    isRecording = active
    lock.unlock()
  }

  func stop() {
    lock.lock()
    let source = runLoopSource
    let tap = eventTap
    shortcuts.removeAll()
    runLoopSource = nil
    eventTap = nil
    lock.unlock()

    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap {
      CFMachPortInvalidate(tap)
    }
  }

  func handle(
    type: CGEventType,
    event: CGEvent
  ) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      lock.lock()
      let tap = eventTap
      lock.unlock()
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else {
      return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = Self.carbonModifiers(from: event.flags)

    lock.lock()
    let match = shortcuts.first { _, shortcut in
      shortcut.keyCode == keyCode && shortcut.modifiers == modifiers
    }
    let isRecording = isRecording
    lock.unlock()

    guard let (action, shortcut) = match else {
      return Unmanaged.passUnretained(event)
    }

    if isRecording {
      Task { @MainActor in
        NotificationCenter.default.post(
          name: .snapClipSystemShortcutRecorded,
          object: shortcut
        )
      }
      return nil
    }

    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if !isRepeat {
      handler(action)
    }
    return nil
  }

  static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
    var value: UInt32 = 0
    if flags.contains(.maskCommand) { value |= HotKeyModifier.command }
    if flags.contains(.maskShift) { value |= HotKeyModifier.shift }
    if flags.contains(.maskAlternate) { value |= HotKeyModifier.option }
    if flags.contains(.maskControl) { value |= HotKeyModifier.control }
    return value
  }
}

private let snapClipHotKeyCallback: EventHandlerUPP = { _, event, userData in
  guard let event, let userData else {
    return OSStatus(eventNotHandledErr)
  }

  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )

  guard status == noErr else {
    return status
  }

  let service = Unmanaged<HotKeyService>
    .fromOpaque(userData)
    .takeUnretainedValue()

  Task { @MainActor in
    service.dispatch(id: hotKeyID.id)
  }

  return noErr
}

@MainActor
final class HotKeyService: HotKeyServing {
  private static let signature: OSType = 0x5343_4C50  // SCLP

  private var eventHandlerRef: EventHandlerRef?
  private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]
  private var shortcuts: [HotKeyAction: HotKeyShortcut] = [:]
  private var actionHandler: ((HotKeyAction) -> Void)?
  private var systemInterceptor: SystemShortcutInterceptor?
  private var isRecording = false

  var accessibilityPermissionGranted: Bool {
    AXIsProcessTrusted()
  }

  init() throws {
    var eventSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      snapClipHotKeyCallback,
      1,
      &eventSpec,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandlerRef
    )

    guard status == noErr else {
      throw HotKeyRegistrationError.eventHandlerInstallationFailed(status)
    }
  }

  func setActionHandler(_ handler: @escaping (HotKeyAction) -> Void) {
    actionHandler = handler
  }

  func reconfigure(_ newShortcuts: [HotKeyAction: HotKeyShortcut]) throws {
    let values = Array(newShortcuts.values)
    guard Set(values).count == values.count else {
      throw HotKeyRegistrationError.duplicateShortcut
    }

    let systemShortcuts = newShortcuts.filter { _, shortcut in
      shortcut.requiresSystemScreenshotInterception
    }
    let interceptor = try prepareSystemInterceptorIfNeeded(
      for: systemShortcuts,
      promptForPermission: true
    )

    let oldShortcuts = shortcuts
    unregisterCarbonHotKeys()
    shortcuts.removeAll()

    do {
      for action in HotKeyAction.allCases {
        guard let shortcut = newShortcuts[action], !shortcut.requiresSystemScreenshotInterception
        else { continue }
        hotKeyRefs[action] = try makeRegistration(action: action, shortcut: shortcut)
      }
      interceptor?.configure(systemShortcuts)
      interceptor?.setRecording(isRecording)
      shortcuts = newShortcuts
    } catch {
      restoreRegistrations(oldShortcuts)
      throw error
    }
  }

  func setRecordingMode(_ active: Bool) throws {
    guard isRecording != active else { return }
    isRecording = active
    systemInterceptor?.setRecording(active)

    if active {
      unregisterCarbonHotKeys()
      return
    }

    do {
      for action in HotKeyAction.allCases {
        guard let shortcut = shortcuts[action], !shortcut.requiresSystemScreenshotInterception
        else { continue }
        hotKeyRefs[action] = try makeRegistration(action: action, shortcut: shortcut)
      }
    } catch {
      unregisterCarbonHotKeys()
      throw error
    }
  }

  @discardableResult
  func requestAccessibilityPermission() -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  func stop() {
    unregisterCarbonHotKeys()
    shortcuts.removeAll()
    systemInterceptor?.stop()
    systemInterceptor = nil
    isRecording = false
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
      self.eventHandlerRef = nil
    }
    actionHandler = nil
  }

  fileprivate func dispatch(id: UInt32) {
    guard let action = HotKeyAction(rawValue: id) else {
      return
    }
    actionHandler?(action)
  }

  fileprivate func dispatch(action: HotKeyAction) {
    actionHandler?(action)
  }

  private func prepareSystemInterceptorIfNeeded(
    for shortcuts: [HotKeyAction: HotKeyShortcut],
    promptForPermission: Bool
  ) throws -> SystemShortcutInterceptor? {
    guard !shortcuts.isEmpty else {
      systemInterceptor?.configure([:])
      return systemInterceptor
    }

    let interceptor: SystemShortcutInterceptor
    if let systemInterceptor {
      interceptor = systemInterceptor
    } else {
      interceptor = SystemShortcutInterceptor { [weak self] action in
        Task { @MainActor [weak self] in
          self?.dispatch(action: action)
        }
      }
      systemInterceptor = interceptor
    }

    try interceptor.prepare(promptForPermission: promptForPermission)
    return interceptor
  }

  private func restoreRegistrations(
    _ oldShortcuts: [HotKeyAction: HotKeyShortcut]
  ) {
    unregisterCarbonHotKeys()
    let oldSystemShortcuts = oldShortcuts.filter { _, shortcut in
      shortcut.requiresSystemScreenshotInterception
    }
    systemInterceptor?.configure(oldSystemShortcuts)

    for action in HotKeyAction.allCases {
      guard let shortcut = oldShortcuts[action], !shortcut.requiresSystemScreenshotInterception
      else { continue }
      if let reference = try? makeRegistration(action: action, shortcut: shortcut) {
        hotKeyRefs[action] = reference
      }
    }
    shortcuts = oldShortcuts
  }

  private func unregisterCarbonHotKeys() {
    for reference in hotKeyRefs.values {
      UnregisterEventHotKey(reference)
    }
    hotKeyRefs.removeAll()
  }

  private func makeRegistration(
    action: HotKeyAction,
    shortcut: HotKeyShortcut
  ) throws -> EventHotKeyRef {
    var reference: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(
      signature: Self.signature,
      id: action.rawValue
    )

    let status = RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &reference
    )

    guard status == noErr, let reference else {
      throw HotKeyRegistrationError.registrationFailed(status)
    }

    return reference
  }
}

struct HotKeyRecorder: NSViewRepresentable {
  let shortcut: HotKeyShortcut
  let onChange: (HotKeyShortcut) -> Void
  let onRecordingChanged: (Bool) -> Void

  func makeNSView(context: Context) -> RecorderView {
    let view = RecorderView()
    view.shortcut = shortcut
    view.onChange = onChange
    view.onRecordingChanged = onRecordingChanged
    return view
  }

  func updateNSView(_ nsView: RecorderView, context: Context) {
    guard !nsView.isRecording else {
      return
    }
    nsView.shortcut = shortcut
    nsView.onChange = onChange
    nsView.onRecordingChanged = onRecordingChanged
    nsView.needsDisplay = true
  }
}

final class RecorderView: NSView {
  var shortcut = HotKeyShortcut.interactiveDefault
  var onChange: ((HotKeyShortcut) -> Void)?
  var onRecordingChanged: ((Bool) -> Void)?
  private(set) var isRecording = false

  override var acceptsFirstResponder: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 28) }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    setAccessibilityRole(.button)
    setAccessibilityLabel("录制快捷键")
    NotificationCenter.default.removeObserver(
      self,
      name: .snapClipSystemShortcutRecorded,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(systemShortcutRecorded(_:)),
      name: .snapClipSystemShortcutRecorded,
      object: nil
    )
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    setRecording(true)
  }

  override func resignFirstResponder() -> Bool {
    setRecording(false)
    return super.resignFirstResponder()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      setRecording(false)
      window?.makeFirstResponder(nil)
      return
    }

    let modifiers = Self.carbonModifiers(from: event.modifierFlags)
    guard modifiers != 0 else {
      NSSound.beep()
      return
    }

    let label = Self.keyLabel(from: event)
    let newShortcut = HotKeyShortcut(
      keyCode: UInt32(event.keyCode),
      modifiers: modifiers,
      keyLabel: label
    )

    completeRecording(with: newShortcut)
  }

  @objc private func systemShortcutRecorded(_ notification: Notification) {
    guard isRecording, let newShortcut = notification.object as? HotKeyShortcut else {
      return
    }
    completeRecording(with: newShortcut)
  }

  private func completeRecording(with newShortcut: HotKeyShortcut) {
    shortcut = newShortcut
    setRecording(false)
    window?.makeFirstResponder(nil)
    onChange?(newShortcut)
    needsDisplay = true
  }

  private func setRecording(_ active: Bool) {
    guard isRecording != active else { return }
    isRecording = active
    onRecordingChanged?(active)
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
    (isRecording
      ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor)
      .setFill()
    path.fill()
    (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
    path.lineWidth = 1
    path.stroke()

    let text = isRecording ? "请按新的快捷键…" : shortcut.displayString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
      .foregroundColor: NSColor.labelColor,
    ]
    let size = text.size(withAttributes: attributes)
    let origin = NSPoint(
      x: (bounds.width - size.width) / 2,
      y: (bounds.height - size.height) / 2
    )
    text.draw(at: origin, withAttributes: attributes)
  }

  private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    let flags = flags.intersection(.deviceIndependentFlagsMask)
    var value: UInt32 = 0
    if flags.contains(.command) { value |= HotKeyModifier.command }
    if flags.contains(.shift) { value |= HotKeyModifier.shift }
    if flags.contains(.option) { value |= HotKeyModifier.option }
    if flags.contains(.control) { value |= HotKeyModifier.control }
    return value
  }

  private static func keyLabel(from event: NSEvent) -> String {
    let characters = event.charactersIgnoringModifiers?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()

    if let characters, !characters.isEmpty {
      return characters
    }
    return "KEY \(event.keyCode)"
  }
}
