import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
  enum PreferenceKey {
    static let interactiveShortcut = "interactiveShortcut"
    static let mainDisplayShortcut = "mainDisplayShortcut"
    static let soundEnabled = "soundEnabled"
    static let shortcutDefaultsVersion = "shortcutDefaultsVersion"
  }

  private static let currentShortcutDefaultsVersion = 2

  let history: HistoryStore

  @Published private(set) var isCapturing = false
  @Published private(set) var isIconFlashing = false
  @Published private(set) var statusMessage = "就绪"
  @Published private(set) var statusIsError = false
  @Published private(set) var canOpenPermissionSettings = false
  @Published private(set) var hotKeyPermissionRequired = false
  @Published private(set) var interactiveShortcut: HotKeyShortcut
  @Published private(set) var mainDisplayShortcut: HotKeyShortcut
  @Published private(set) var soundEnabled: Bool
  @Published private(set) var launchAtLoginEnabled = false
  @Published private(set) var loginItemRequiresApproval = false
  @Published private(set) var recognizingItemID: UUID?
  @Published private(set) var savingItemID: UUID?

  private let captureService: any CaptureServing
  private let clipboardService: any ClipboardServing
  private let desktopExportService: any DesktopExportServing
  private let ocrService: any OCRServing
  private let permissionService: any ScreenCapturePermissionServing
  private let loginItemService: any LoginItemServing
  private let previewController: PreviewWindowController
  private let userDefaults: UserDefaults
  private let hotKeyServiceFactory: @MainActor () throws -> any HotKeyServing
  private var hotKeyService: (any HotKeyServing)?
  private var captureTask: Task<Void, Never>?
  private var ocrTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var feedbackTask: Task<Void, Never>?
  private var iconTask: Task<Void, Never>?
  private var didStart = false

  init(
    history: HistoryStore = HistoryStore(),
    captureService: any CaptureServing = SystemCaptureService(),
    clipboardService: any ClipboardServing = SystemClipboardService(),
    desktopExportService: any DesktopExportServing = DesktopExportService(),
    ocrService: any OCRServing = VisionOCRService(),
    permissionService: any ScreenCapturePermissionServing = ScreenCapturePermissionService(),
    loginItemService: any LoginItemServing = LoginItemService(),
    previewController: PreviewWindowController = PreviewWindowController(),
    userDefaults: UserDefaults = .standard,
    hotKeyServiceFactory: @escaping @MainActor () throws -> any HotKeyServing = {
      try HotKeyService()
    }
  ) {
    self.history = history
    self.captureService = captureService
    self.clipboardService = clipboardService
    self.desktopExportService = desktopExportService
    self.ocrService = ocrService
    self.permissionService = permissionService
    self.loginItemService = loginItemService
    self.previewController = previewController
    self.userDefaults = userDefaults
    self.hotKeyServiceFactory = hotKeyServiceFactory

    let storedInteractive = Self.loadShortcut(
      key: PreferenceKey.interactiveShortcut,
      fallback: .interactiveDefault,
      userDefaults: userDefaults
    )
    let storedMainDisplay = Self.loadShortcut(
      key: PreferenceKey.mainDisplayShortcut,
      fallback: .mainDisplayDefault,
      userDefaults: userDefaults
    )
    let shouldMigrateLegacyDefaults =
      userDefaults.integer(forKey: PreferenceKey.shortcutDefaultsVersion)
      < Self.currentShortcutDefaultsVersion
      && storedInteractive == .legacyInteractiveDefault
      && storedMainDisplay == .legacyMainDisplayDefault

    if shouldMigrateLegacyDefaults {
      self.interactiveShortcut = .interactiveDefault
      self.mainDisplayShortcut = .mainDisplayDefault
      Self.saveShortcut(
        .interactiveDefault,
        key: PreferenceKey.interactiveShortcut,
        userDefaults: userDefaults
      )
      Self.saveShortcut(
        .mainDisplayDefault,
        key: PreferenceKey.mainDisplayShortcut,
        userDefaults: userDefaults
      )
    } else {
      self.interactiveShortcut = storedInteractive
      self.mainDisplayShortcut = storedMainDisplay
    }
    userDefaults.set(
      Self.currentShortcutDefaultsVersion,
      forKey: PreferenceKey.shortcutDefaultsVersion
    )

    if userDefaults.object(forKey: PreferenceKey.soundEnabled) == nil {
      self.soundEnabled = true
    } else {
      self.soundEnabled = userDefaults.bool(forKey: PreferenceKey.soundEnabled)
    }
  }

  func start() {
    guard !didStart else { return }
    didStart = true

    refreshLoginItemStatus()

    do {
      let service = try hotKeyServiceFactory()
      service.setActionHandler { [weak self] action in
        switch action {
        case .interactiveCapture:
          self?.capture(.interactive)
        case .mainDisplayCapture:
          self?.capture(.mainDisplay)
        }
      }
      hotKeyService = service
      try service.reconfigure([
        .interactiveCapture: interactiveShortcut,
        .mainDisplayCapture: mainDisplayShortcut,
      ])
      hotKeyPermissionRequired = false
    } catch {
      handleHotKeyError(error)
    }
  }

  func capture(_ mode: CaptureMode) {
    guard !isCapturing else { return }

    guard permissionService.isAuthorized || permissionService.requestAuthorization() else {
      canOpenPermissionSettings = true
      showError("需要屏幕录制权限才能截图。")
      return
    }

    isCapturing = true
    statusMessage = "正在截图…"
    statusIsError = false
    canOpenPermissionSettings = false
    let soundEnabled = soundEnabled

    captureTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isCapturing = false
        captureTask = nil
      }

      do {
        let outcome = try await captureService.capture(
          mode: mode,
          soundEnabled: soundEnabled
        )

        switch outcome {
        case .captured(let data):
          guard clipboardService.copyImage(pngData: data) else {
            showError("截图成功，但无法写入剪贴板。")
            return
          }
          history.insert(pngData: data)
          flashMenuBarIcon()
          showFeedback("已复制截图")
        case .cancelled:
          showFeedback("已取消截图", duration: .milliseconds(800))
        }
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func copyImage(_ item: ScreenshotItem) {
    if clipboardService.copyImage(pngData: item.pngData) {
      showFeedback("已复制截图")
    } else {
      showError("无法把截图写入剪贴板。")
    }
  }

  func openPreview(_ item: ScreenshotItem) {
    do {
      try previewController.show(
        pngData: item.pngData,
        title: "SnapClip · \(item.capturedAt.formatted(date: .omitted, time: .shortened))"
      )
    } catch {
      showError(error.localizedDescription)
    }
  }

  func saveToDesktop(_ item: ScreenshotItem) {
    guard savingItemID == nil else {
      showError("请等待当前图片保存完成。")
      return
    }

    savingItemID = item.id
    statusMessage = "正在保存到桌面…"
    statusIsError = false

    exportTask = Task { [weak self] in
      guard let self else { return }
      defer {
        savingItemID = nil
        exportTask = nil
      }

      do {
        let destination = try await desktopExportService.savePNG(
          item.pngData,
          capturedAt: item.capturedAt
        )
        guard !Task.isCancelled else { return }
        showFeedback("已保存：\(destination.lastPathComponent)")
      } catch is CancellationError {
        return
      } catch {
        showError("无法保存到桌面：\(error.localizedDescription)")
      }
    }
  }

  func copyRecognizedText(_ item: ScreenshotItem) {
    if let cached = item.recognizedText {
      copyTextAndReport(cached)
      return
    }

    guard recognizingItemID == nil else {
      showError("请等待当前文字识别完成。")
      return
    }
    guard item.ocrState != .recognizing else { return }
    recognizingItemID = item.id
    history.markRecognizing(id: item.id)
    statusMessage = "正在识别文字…"
    statusIsError = false

    ocrTask = Task { [weak self] in
      guard let self else { return }
      defer {
        recognizingItemID = nil
        ocrTask = nil
      }

      do {
        let text = try await ocrService.recognizeText(in: item.pngData)
        guard history.item(id: item.id) != nil else {
          return
        }
        history.storeRecognizedText(text, id: item.id)
        copyTextAndReport(text)
      } catch is CancellationError {
        return
      } catch {
        guard history.item(id: item.id) != nil else {
          return
        }
        history.markOCRFailed(error.localizedDescription, id: item.id)
        showError(error.localizedDescription)
      }
    }
  }

  func clearHistory() {
    history.clear()
    showFeedback("已清空历史")
  }

  func updateShortcut(_ shortcut: HotKeyShortcut, for action: HotKeyAction) {
    let other = action == .interactiveCapture ? mainDisplayShortcut : interactiveShortcut
    guard shortcut != other else {
      showError(HotKeyRegistrationError.duplicateShortcut.localizedDescription)
      return
    }

    do {
      guard let hotKeyService else {
        throw HotKeyRegistrationError.serviceUnavailable
      }
      let newInteractive =
        action == .interactiveCapture ? shortcut : interactiveShortcut
      let newMainDisplay =
        action == .mainDisplayCapture ? shortcut : mainDisplayShortcut
      try hotKeyService.reconfigure([
        .interactiveCapture: newInteractive,
        .mainDisplayCapture: newMainDisplay,
      ])
      hotKeyPermissionRequired = false
      switch action {
      case .interactiveCapture:
        interactiveShortcut = shortcut
        saveShortcut(shortcut, key: PreferenceKey.interactiveShortcut)
      case .mainDisplayCapture:
        mainDisplayShortcut = shortcut
        saveShortcut(shortcut, key: PreferenceKey.mainDisplayShortcut)
      }
      showFeedback("快捷键已更新")
    } catch {
      handleHotKeyError(error)
    }
  }

  func setHotKeyRecording(_ active: Bool) {
    do {
      guard let hotKeyService else {
        throw HotKeyRegistrationError.serviceUnavailable
      }
      try hotKeyService.setRecordingMode(active)
    } catch {
      handleHotKeyError(error)
    }
  }

  func setSoundEnabled(_ enabled: Bool) {
    soundEnabled = enabled
    userDefaults.set(enabled, forKey: PreferenceKey.soundEnabled)
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try loginItemService.setEnabled(enabled)
      refreshLoginItemStatus()
      showFeedback(enabled ? "已启用登录时启动" : "已关闭登录时启动")
    } catch {
      refreshLoginItemStatus()
      showError("无法更新登录项：\(error.localizedDescription)")
    }
  }

  func refreshLoginItemStatus() {
    switch loginItemService.status {
    case .enabled:
      launchAtLoginEnabled = true
      loginItemRequiresApproval = false
    case .requiresApproval:
      launchAtLoginEnabled = false
      loginItemRequiresApproval = true
    case .disabled, .unavailable:
      launchAtLoginEnabled = false
      loginItemRequiresApproval = false
    }
  }

  func restoreDefaults() {
    if interactiveShortcut == .interactiveDefault,
      mainDisplayShortcut == .mainDisplayDefault,
      soundEnabled,
      !hotKeyPermissionRequired
    {
      showFeedback("当前已是默认设置")
      return
    }

    do {
      guard let hotKeyService else {
        throw HotKeyRegistrationError.serviceUnavailable
      }
      try hotKeyService.reconfigure([
        .interactiveCapture: .interactiveDefault,
        .mainDisplayCapture: .mainDisplayDefault,
      ])
      interactiveShortcut = .interactiveDefault
      mainDisplayShortcut = .mainDisplayDefault
      saveShortcut(.interactiveDefault, key: PreferenceKey.interactiveShortcut)
      saveShortcut(.mainDisplayDefault, key: PreferenceKey.mainDisplayShortcut)
      setSoundEnabled(true)
      hotKeyPermissionRequired = false
      showFeedback("已恢复默认设置")
    } catch {
      handleHotKeyError(error)
    }
  }

  func requestHotKeyPermission() {
    guard let hotKeyService else {
      handleHotKeyError(HotKeyRegistrationError.serviceUnavailable)
      return
    }

    _ = hotKeyService.requestAccessibilityPermission()
    retryHotKeys()
  }

  func retryHotKeys() {
    do {
      guard let hotKeyService else {
        throw HotKeyRegistrationError.serviceUnavailable
      }
      try hotKeyService.reconfigure([
        .interactiveCapture: interactiveShortcut,
        .mainDisplayCapture: mainDisplayShortcut,
      ])
      hotKeyPermissionRequired = false
      showFeedback("快捷键已启用")
    } catch {
      handleHotKeyError(error)
    }
  }

  func openAccessibilitySettings() {
    hotKeyService?.openAccessibilitySettings()
  }

  func openScreenCaptureSettings() {
    permissionService.openSystemSettings()
  }

  func openLoginItemSettings() {
    loginItemService.openSystemSettings()
  }

  func shutdown() {
    captureTask?.cancel()
    ocrTask?.cancel()
    exportTask?.cancel()
    feedbackTask?.cancel()
    iconTask?.cancel()
    hotKeyService?.stop()
    hotKeyService = nil
  }

  private func copyTextAndReport(_ text: String) {
    guard clipboardService.copyText(text) else {
      showError("无法把识别结果写入剪贴板。")
      return
    }
    showFeedback("已复制 \(text.count) 个字符")
  }

  private func flashMenuBarIcon() {
    iconTask?.cancel()
    isIconFlashing = true
    iconTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled else { return }
      self?.isIconFlashing = false
    }
  }

  private func showFeedback(
    _ message: String,
    duration: Duration = .seconds(2)
  ) {
    feedbackTask?.cancel()
    statusMessage = message
    statusIsError = false
    canOpenPermissionSettings = false
    feedbackTask = Task { [weak self] in
      try? await Task.sleep(for: duration)
      guard !Task.isCancelled else { return }
      self?.statusMessage = "就绪"
    }
  }

  private func showError(_ message: String) {
    feedbackTask?.cancel()
    statusMessage = message
    statusIsError = true
  }

  private func handleHotKeyError(_ error: Error) {
    if let registrationError = error as? HotKeyRegistrationError,
      registrationError == .accessibilityPermissionRequired
        || registrationError == .eventTapCreationFailed
    {
      hotKeyPermissionRequired = true
    }
    showError(error.localizedDescription)
  }

  private func saveShortcut(_ shortcut: HotKeyShortcut, key: String) {
    Self.saveShortcut(shortcut, key: key, userDefaults: userDefaults)
  }

  private static func saveShortcut(
    _ shortcut: HotKeyShortcut,
    key: String,
    userDefaults: UserDefaults
  ) {
    guard let data = try? JSONEncoder().encode(shortcut) else { return }
    userDefaults.set(data, forKey: key)
  }

  private static func loadShortcut(
    key: String,
    fallback: HotKeyShortcut,
    userDefaults: UserDefaults
  ) -> HotKeyShortcut {
    guard let data = userDefaults.data(forKey: key),
      let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
    else {
      return fallback
    }
    return shortcut
  }
}
