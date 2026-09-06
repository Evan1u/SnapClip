import AppKit
import Foundation
import XCTest

@testable import SnapClip

private struct StubQRCodeRenderer: ScreenshotRendering {
  let output: Data

  func render(
    sourcePNG: Data,
    cropRect: CGRect,
    annotations: [EditorAnnotation]
  ) async throws -> Data {
    output
  }
}

private struct StubQRCodeService: QRCodeRecognizing {
  let delay: Duration
  let outcome: Result<[QRCodeResult], QRCodeRecognitionError>
  let ignoresCancellation: Bool

  func recognizeQRCodes(in pngData: Data) async throws -> [QRCodeResult] {
    if delay > .zero {
      if ignoresCancellation {
        try? await Task.sleep(for: delay)
      } else {
        try await Task.sleep(for: delay)
      }
    }
    return try outcome.get()
  }
}

@MainActor
private final class QRCodeClipboardSpy: ClipboardServing {
  let succeeds: Bool
  private(set) var copiedTexts: [String] = []

  init(succeeds: Bool = true) {
    self.succeeds = succeeds
  }

  func copyImage(pngData: Data) -> Bool { true }

  func copyText(_ text: String) -> Bool {
    copiedTexts.append(text)
    return succeeds
  }
}

@MainActor
private final class QRCodeURLOpenerSpy: ExternalURLOpening {
  let succeeds: Bool
  private(set) var openedURLs: [URL] = []

  init(succeeds: Bool = true) {
    self.succeeds = succeeds
  }

  func open(_ url: URL) -> Bool {
    openedURLs.append(url)
    return succeeds
  }
}

@MainActor
final class EditorSessionCoreQRCodeTests: XCTestCase {
  func testNoQRCodeReturnsToSelectionAndClearsBusyState() async throws {
    let png = try makeSolidPNG(width: 40, height: 40)
    let core = makeCore(
      png: png,
      service: StubQRCodeService(
        delay: .zero,
        outcome: .failure(.noQRCode),
        ignoresCancellation: false
      )
    )
    try begin(core: core, png: png)

    core.handleToolSelection(.qrCode)
    await waitUntil { !core.toolbarModel.model.isQRCodeWorking }

    XCTAssertEqual(core.toolbarModel.model.tool, .selection)
    XCTAssertFalse(core.toolbarModel.model.isQRCodeWorking)
  }

  func testSwitchingToolsRejectsLateQRCodeResult() async throws {
    let png = try makeSolidPNG(width: 40, height: 40)
    let core = makeCore(
      png: png,
      service: StubQRCodeService(
        delay: .milliseconds(80),
        outcome: .success([
          QRCodeResult(
            rawPayload: "https://example.com",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
          )
        ]),
        ignoresCancellation: true
      )
    )
    try begin(core: core, png: png)

    core.handleToolSelection(.qrCode)
    core.handleToolSelection(.rectangle)
    try? await Task.sleep(for: .milliseconds(140))

    XCTAssertEqual(core.toolbarModel.model.tool, .rectangle)
    XCTAssertFalse(core.toolbarModel.model.isQRCodeWorking)
  }

  func testCopyLinkWritesTrimmedValueAndKeepsSessionOpen() throws {
    let png = try makeSolidPNG(width: 40, height: 40)
    let clipboard = QRCodeClipboardSpy()
    let core = makeCore(
      png: png,
      service: successfulService,
      clipboard: clipboard
    )
    try begin(core: core, png: png)

    core.handleQRCodeCopy(
      QRCodePayloadClassifier.classify("  https://example.com/path  ")
    )

    XCTAssertEqual(clipboard.copiedTexts, ["https://example.com/path"])
    XCTAssertTrue(core.isPresenting)
  }

  func testFailedCopyKeepsSessionOpenAndReportsError() throws {
    let png = try makeSolidPNG(width: 40, height: 40)
    let clipboard = QRCodeClipboardSpy(succeeds: false)
    let core = makeCore(
      png: png,
      service: successfulService,
      clipboard: clipboard
    )
    var status: (String, Bool)?
    core.statusHandler = { status = ($0, $1) }
    try begin(core: core, png: png)

    core.handleQRCodeCopy(.text("原始内容"))

    XCTAssertEqual(clipboard.copiedTexts, ["原始内容"])
    XCTAssertEqual(status?.0, "无法把二维码内容写入剪贴板。")
    XCTAssertEqual(status?.1, true)
    XCTAssertTrue(core.isPresenting)
  }

  func testOpenLinkRunsOnlyAfterExplicitActionAndClosesSession() throws {
    let png = try makeSolidPNG(width: 40, height: 40)
    let opener = QRCodeURLOpenerSpy()
    let core = makeCore(
      png: png,
      service: successfulService,
      opener: opener
    )
    var closeCount = 0
    core.onRequestClose = { closeCount += 1 }
    try begin(core: core, png: png)

    let kind = QRCodePayloadClassifier.classify("https://example.com/qr")
    XCTAssertTrue(opener.openedURLs.isEmpty)
    core.handleQRCodeOpen(kind)

    XCTAssertEqual(opener.openedURLs, [URL(string: "https://example.com/qr")!])
    XCTAssertEqual(closeCount, 1)
    XCTAssertFalse(core.isPresenting)
  }

  func testFailedOpenAndNonLinkPayloadKeepSessionOpen() throws {
    let png = try makeSolidPNG(width: 40, height: 40)
    let opener = QRCodeURLOpenerSpy(succeeds: false)
    let core = makeCore(
      png: png,
      service: successfulService,
      opener: opener
    )
    var status: (String, Bool)?
    core.statusHandler = { status = ($0, $1) }
    try begin(core: core, png: png)

    core.handleQRCodeOpen(.text("not a link"))
    XCTAssertTrue(opener.openedURLs.isEmpty)

    core.handleQRCodeOpen(QRCodePayloadClassifier.classify("https://example.com"))
    XCTAssertEqual(opener.openedURLs.count, 1)
    XCTAssertEqual(status?.0, "无法打开链接。")
    XCTAssertEqual(status?.1, true)
    XCTAssertTrue(core.isPresenting)
  }

  private var successfulService: StubQRCodeService {
    StubQRCodeService(
      delay: .zero,
      outcome: .success([]),
      ignoresCancellation: false
    )
  }

  private func makeCore(
    png: Data,
    service: StubQRCodeService,
    clipboard: QRCodeClipboardSpy = QRCodeClipboardSpy(),
    opener: QRCodeURLOpenerSpy = QRCodeURLOpenerSpy()
  ) -> EditorSessionCore {
    let canvas = EditorCanvasView(
      frame: CGRect(x: 0, y: 0, width: 160, height: 160),
      sourcePixelSize: CGSize(width: 40, height: 40),
      styleStore: EditorToolStyleStore()
    )
    return EditorSessionCore(
      canvas: canvas,
      renderer: StubQRCodeRenderer(output: png),
      qrCodeService: service,
      clipboardService: clipboard,
      externalURLOpener: opener
    )
  }

  private func begin(core: EditorSessionCore, png: Data) throws {
    try core.begin(
      pngData: png,
      pixelSize: CGSize(width: 40, height: 40),
      capturedAt: Date(timeIntervalSince1970: 0),
      target: .newCapture(capturedAt: Date(timeIntervalSince1970: 0)),
      sourceRevision: 0,
      pointsToImageScale: 1
    )
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func makeSolidPNG(width: Int, height: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      throw QRCodeRecognitionError.invalidImage
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    CGRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw QRCodeRecognitionError.invalidImage
    }
    return data
  }
}
