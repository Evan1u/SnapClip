import Foundation
import XCTest

@testable import SnapClip

private struct StubCaptureService: CaptureServing {
  let outcome: CaptureOutcome

  func capture(mode: CaptureMode, soundEnabled: Bool) async throws -> CaptureOutcome {
    outcome
  }
}

@MainActor
private final class StubClipboardService: ClipboardServing {
  var imageWriteSucceeds = true
  private(set) var copiedImages: [Data] = []
  private(set) var copiedTexts: [String] = []

  func copyImage(pngData: Data) -> Bool {
    copiedImages.append(pngData)
    return imageWriteSucceeds
  }

  func copyText(_ text: String) -> Bool {
    copiedTexts.append(text)
    return true
  }
}

private struct StubOCRService: OCRServing {
  func recognizeText(in pngData: Data) async throws -> String {
    "stub"
  }
}

@MainActor
private final class StubEditorController: ScreenshotEditing {
  var sessionDelegate: EditorSessionDelegate?
  private(set) var isPresenting = false
  private(set) var presentedCapture: (pngData: Data, capturedAt: Date)?

  func presentNewCapture(pngData: Data, capturedAt: Date) throws {
    presentedCapture = (pngData, capturedAt)
    isPresenting = true
    sessionDelegate?.editorDidBeginSession()
  }

  func presentHistoryItem(_ item: ScreenshotItem) throws {
    isPresenting = true
    sessionDelegate?.editorDidBeginSession()
  }

  func discardActiveSession() {
    isPresenting = false
    sessionDelegate?.editorDidCancelSession()
  }

  func focus() {}
  func shutdown() {}
}

private struct StubDesktopExportService: DesktopExportServing {
  let destination: URL
  var error: DesktopExportError?

  func savePNG(_ pngData: Data, capturedAt: Date) async throws -> URL {
    if let error {
      throw error
    }
    return destination
  }
}

@MainActor
private final class AuthorizedPermissionService: ScreenCapturePermissionServing {
  var isAuthorized = true

  func requestAuthorization() -> Bool { true }
  func openSystemSettings() {}
}

@MainActor
private final class DisabledLoginItemService: LoginItemServing {
  var status: LoginItemStatus { .disabled }

  func setEnabled(_ enabled: Bool) throws {}
  func openSystemSettings() {}
}

@MainActor
private final class StubHotKeyService: HotKeyServing {
  var accessibilityPermissionGranted = true
  var nextError: Error?
  private(set) var configurations: [[HotKeyAction: HotKeyShortcut]] = []

  func setActionHandler(_ handler: @escaping (HotKeyAction) -> Void) {}

  func reconfigure(_ newShortcuts: [HotKeyAction: HotKeyShortcut]) throws {
    if let nextError {
      self.nextError = nil
      throw nextError
    }
    configurations.append(newShortcuts)
  }

  func setRecordingMode(_ active: Bool) throws {}

  func requestAccessibilityPermission() -> Bool {
    accessibilityPermissionGranted
  }

  func openAccessibilitySettings() {}
  func stop() {}
}

@MainActor
final class AppModelTests: XCTestCase {
  func testSuccessfulCaptureCopiesBeforeAddingToHistory() async {
    let data = Data([1, 2, 3])
    let clipboard = StubClipboardService()
    let editor = StubEditorController()
    let model = makeModel(
      outcome: .captured(data),
      clipboard: clipboard,
      editor: editor
    )

    model.capture(.mainDisplay)
    await waitForCaptureToFinish(model)

    XCTAssertEqual(editor.presentedCapture?.pngData, data)
    XCTAssertTrue(clipboard.copiedImages.isEmpty)
    XCTAssertTrue(model.history.items.isEmpty)
    XCTAssertTrue(model.isEditing)
  }

  func testNewCaptureCommitCopiesBeforeAddingToHistory() async {
    let data = Data([1, 2, 3])
    let clipboard = StubClipboardService()
    let model = makeModel(
      outcome: .cancelled,
      clipboard: clipboard
    )
    let capturedAt = Date(timeIntervalSince1970: 100)

    let result = model.editorDidRequestCommit(
      EditorOutput(
        target: .newCapture(capturedAt: capturedAt),
        pngData: data,
        contentChanged: true,
        ocrCache: .clear
      )
    )

    XCTAssertEqual(result, .accepted)
    XCTAssertEqual(clipboard.copiedImages, [data])
    XCTAssertEqual(model.history.items.map(\.pngData), [data])
  }

  func testClipboardFailureDoesNotAddScreenshotToHistory() async {
    let clipboard = StubClipboardService()
    clipboard.imageWriteSucceeds = false
    let model = makeModel(
      outcome: .captured(Data([7])),
      clipboard: clipboard
    )

    let result = model.editorDidRequestCommit(
      EditorOutput(
        target: .newCapture(capturedAt: Date()),
        pngData: Data([7]),
        contentChanged: true,
        ocrCache: .clear
      )
    )

    XCTAssertEqual(result, .rejected(message: "截图成功，但无法写入剪贴板。"))
    XCTAssertTrue(model.history.items.isEmpty)
  }

  func testDesktopExportUsesReadableNameAndNeverOverwrites() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let service = DesktopExportService(
      desktopDirectory: directory,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let capturedAt = Date(timeIntervalSince1970: 0)
    let firstData = Data([1, 2, 3])
    let secondData = Data([4, 5, 6])

    let firstURL = try await service.savePNG(firstData, capturedAt: capturedAt)
    let secondURL = try await service.savePNG(secondData, capturedAt: capturedAt)

    XCTAssertEqual(firstURL.lastPathComponent, "SnapClip 1970-01-01 00.00.00.png")
    XCTAssertEqual(secondURL.lastPathComponent, "SnapClip 1970-01-01 00.00.00 2.png")
    XCTAssertEqual(try Data(contentsOf: firstURL), firstData)
    XCTAssertEqual(try Data(contentsOf: secondURL), secondData)
  }

  func testDesktopExportSuccessReportsFinalFilename() async {
    let destination = URL(fileURLWithPath: "/Desktop/SnapClip 2026-08-23 16.05.30.png")
    let exporter = StubDesktopExportService(destination: destination)
    let model = makeModel(
      outcome: .cancelled,
      clipboard: StubClipboardService(),
      desktopExporter: exporter
    )

    model.saveToDesktop(ScreenshotItem(pngData: Data([1, 2, 3])))
    await waitForSaveToFinish(model)

    XCTAssertEqual(model.statusMessage, "已保存：SnapClip 2026-08-23 16.05.30.png")
    XCTAssertFalse(model.statusIsError)
  }

  func testDesktopExportFailureReportsError() async {
    let exporter = StubDesktopExportService(
      destination: URL(fileURLWithPath: "/Desktop/unused.png"),
      error: .desktopUnavailable
    )
    let model = makeModel(
      outcome: .cancelled,
      clipboard: StubClipboardService(),
      desktopExporter: exporter
    )

    model.saveToDesktop(ScreenshotItem(pngData: Data([1, 2, 3])))
    await waitForSaveToFinish(model)

    XCTAssertEqual(model.statusMessage, "无法保存到桌面：无法找到桌面文件夹。")
    XCTAssertTrue(model.statusIsError)
  }

  func testCancellationLeavesClipboardAndHistoryUntouched() async {
    let clipboard = StubClipboardService()
    let model = makeModel(outcome: .cancelled, clipboard: clipboard)

    model.capture(.interactive)
    await waitForCaptureToFinish(model)

    XCTAssertTrue(clipboard.copiedImages.isEmpty)
    XCTAssertTrue(model.history.items.isEmpty)
  }

  func testLegacyDefaultShortcutsMigrateToSystemShortcuts() throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    try store(.legacyInteractiveDefault, key: "interactiveShortcut", in: defaults)
    try store(.legacyMainDisplayDefault, key: "mainDisplayShortcut", in: defaults)

    let model = makeModel(
      outcome: .cancelled,
      clipboard: StubClipboardService(),
      defaults: defaults
    )

    XCTAssertEqual(model.interactiveShortcut, .interactiveDefault)
    XCTAssertEqual(model.mainDisplayShortcut, .mainDisplayDefault)
  }

  func testCustomShortcutIsNotOverwrittenByMigration() throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let custom = HotKeyShortcut(
      keyCode: 12,
      modifiers: HotKeyModifier.command | HotKeyModifier.option,
      keyLabel: "Q"
    )
    try store(custom, key: "interactiveShortcut", in: defaults)
    try store(.legacyMainDisplayDefault, key: "mainDisplayShortcut", in: defaults)

    let model = makeModel(
      outcome: .cancelled,
      clipboard: StubClipboardService(),
      defaults: defaults
    )

    XCTAssertEqual(model.interactiveShortcut, custom)
    XCTAssertEqual(model.mainDisplayShortcut, .legacyMainDisplayDefault)
  }

  func testRestoreDefaultsUpdatesRuntimeAndPreferences() throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    defaults.set(2, forKey: "shortcutDefaultsVersion")
    defaults.set(false, forKey: "soundEnabled")
    let customInteractive = HotKeyShortcut(
      keyCode: 12,
      modifiers: HotKeyModifier.command | HotKeyModifier.option,
      keyLabel: "Q"
    )
    let customMain = HotKeyShortcut(
      keyCode: 13,
      modifiers: HotKeyModifier.command | HotKeyModifier.option,
      keyLabel: "W"
    )
    try store(customInteractive, key: "interactiveShortcut", in: defaults)
    try store(customMain, key: "mainDisplayShortcut", in: defaults)
    let hotKeys = StubHotKeyService()
    let model = makeModel(
      outcome: .cancelled,
      clipboard: StubClipboardService(),
      defaults: defaults,
      hotKeys: hotKeys
    )
    model.start()

    model.restoreDefaults()

    XCTAssertEqual(model.interactiveShortcut, .interactiveDefault)
    XCTAssertEqual(model.mainDisplayShortcut, .mainDisplayDefault)
    XCTAssertTrue(model.soundEnabled)
    XCTAssertEqual(hotKeys.configurations.last?[.interactiveCapture], .interactiveDefault)
    XCTAssertEqual(hotKeys.configurations.last?[.mainDisplayCapture], .mainDisplayDefault)
    XCTAssertEqual(model.statusMessage, "已恢复默认设置")
  }

  func testRestoreDefaultsReportsNoChange() {
    let hotKeys = StubHotKeyService()
    let model = makeModel(
      outcome: .cancelled,
      clipboard: StubClipboardService(),
      hotKeys: hotKeys
    )
    model.start()
    let configurationCount = hotKeys.configurations.count

    model.restoreDefaults()

    XCTAssertEqual(hotKeys.configurations.count, configurationCount)
    XCTAssertEqual(model.statusMessage, "当前已是默认设置")
  }

  func testRestoreDefaultsRetriesWhenDefaultShortcutsNeedPermission() {
    let hotKeys = StubHotKeyService()
    hotKeys.nextError = HotKeyRegistrationError.accessibilityPermissionRequired
    let model = makeModel(
      outcome: .cancelled,
      clipboard: StubClipboardService(),
      hotKeys: hotKeys
    )
    model.start()
    XCTAssertTrue(model.hotKeyPermissionRequired)

    model.restoreDefaults()

    XCTAssertFalse(model.hotKeyPermissionRequired)
    XCTAssertEqual(hotKeys.configurations.count, 1)
    XCTAssertEqual(model.statusMessage, "已恢复默认设置")
  }

  func testRestoreDefaultsRollsBackWhenRegistrationFails() throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    defaults.set(2, forKey: "shortcutDefaultsVersion")
    let customInteractive = HotKeyShortcut(
      keyCode: 12,
      modifiers: HotKeyModifier.command | HotKeyModifier.option,
      keyLabel: "Q"
    )
    let customMain = HotKeyShortcut(
      keyCode: 13,
      modifiers: HotKeyModifier.command | HotKeyModifier.option,
      keyLabel: "W"
    )
    try store(customInteractive, key: "interactiveShortcut", in: defaults)
    try store(customMain, key: "mainDisplayShortcut", in: defaults)
    let hotKeys = StubHotKeyService()
    let model = makeModel(
      outcome: .cancelled,
      clipboard: StubClipboardService(),
      defaults: defaults,
      hotKeys: hotKeys
    )
    model.start()
    hotKeys.nextError = HotKeyRegistrationError.registrationFailed(-9878)

    model.restoreDefaults()

    XCTAssertEqual(model.interactiveShortcut, customInteractive)
    XCTAssertEqual(model.mainDisplayShortcut, customMain)
    XCTAssertTrue(model.statusIsError)
  }

  private func makeModel(
    outcome: CaptureOutcome,
    clipboard: StubClipboardService,
    editor: (any ScreenshotEditing)? = nil,
    defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!,
    hotKeys: StubHotKeyService? = nil,
    desktopExporter: any DesktopExportServing = StubDesktopExportService(
      destination: URL(fileURLWithPath: "/Desktop/SnapClip.png")
    )
  ) -> AppModel {
    let hotKeys = hotKeys ?? StubHotKeyService()
    return AppModel(
      captureService: StubCaptureService(outcome: outcome),
      clipboardService: clipboard,
      desktopExportService: desktopExporter,
      ocrService: StubOCRService(),
      permissionService: AuthorizedPermissionService(),
      loginItemService: DisabledLoginItemService(),
      editorController: editor ?? StubEditorController(),
      userDefaults: defaults,
      hotKeyServiceFactory: { hotKeys }
    )
  }

  private func store(
    _ shortcut: HotKeyShortcut,
    key: String,
    in defaults: UserDefaults
  ) throws {
    defaults.set(try JSONEncoder().encode(shortcut), forKey: key)
  }

  private func waitForCaptureToFinish(_ model: AppModel) async {
    for _ in 0..<100 where model.isCapturing {
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertFalse(model.isCapturing)
  }

  private func waitForSaveToFinish(_ model: AppModel) async {
    for _ in 0..<100 where model.savingItemID != nil {
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNil(model.savingItemID)
  }
}

final class PreviewAnalysisRequestGateTests: XCTestCase {
  func testNewRequestRejectsPreviousResult() {
    var gate = PreviewAnalysisRequestGate()
    let first = UUID()
    let second = UUID()

    gate.begin(id: first)
    gate.begin(id: second)

    XCTAssertFalse(gate.accepts(first))
    XCTAssertTrue(gate.accepts(second))
  }

  func testInvalidationRejectsCurrentResult() {
    var gate = PreviewAnalysisRequestGate()
    let request = gate.begin()

    gate.invalidate()

    XCTAssertFalse(gate.accepts(request))
    XCTAssertNil(gate.currentID)
  }
}
