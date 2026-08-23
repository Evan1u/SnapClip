import AppKit
import Foundation
import ImageIO
import VisionKit

struct PreviewAnalysisRequestGate {
  private(set) var currentID: UUID?

  mutating func begin(id: UUID = UUID()) -> UUID {
    currentID = id
    return id
  }

  func accepts(_ id: UUID) -> Bool {
    currentID == id
  }

  mutating func invalidate() {
    currentID = nil
  }
}

@MainActor
protocol LiveTextAnalyzing: AnyObject {
  var isSupported: Bool { get }
  func analyze(_ image: NSImage) async throws -> ImageAnalysis
}

@MainActor
final class VisionKitLiveTextAnalyzer: LiveTextAnalyzing {
  private let analyzer = ImageAnalyzer()

  var isSupported: Bool {
    ImageAnalyzer.isSupported
  }

  func analyze(_ image: NSImage) async throws -> ImageAnalysis {
    var configuration = ImageAnalyzer.Configuration(.text)
    let supportedLanguages = Set(ImageAnalyzer.supportedTextRecognitionLanguages)
    configuration.locales = ["zh-Hans", "zh-Hant", "en-US"].filter {
      supportedLanguages.contains($0)
    }

    return try await analyzer.analyze(
      image,
      orientation: .up,
      configuration: configuration
    )
  }
}

@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
  private let liveTextAnalyzer: any LiveTextAnalyzing
  private var windowController: NSWindowController?
  private weak var previewView: SelectableImagePreviewView?
  private var analysisTask: Task<Void, Never>?
  private var requestGate = PreviewAnalysisRequestGate()

  init(liveTextAnalyzer: any LiveTextAnalyzing = VisionKitLiveTextAnalyzer()) {
    self.liveTextAnalyzer = liveTextAnalyzer
    super.init()
  }

  func show(pngData: Data, title: String) throws {
    guard let image = NSImage(data: pngData) else {
      throw CaptureError.invalidImage
    }

    let controller = windowController ?? makeWindowController()
    windowController = controller

    previewView?.show(image: image)
    controller.window?.title = title
    resizeWindow(for: image, window: controller.window)

    NSApp.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    beginLiveTextAnalysis(for: image)
  }

  func windowWillClose(_ notification: Notification) {
    cancelLiveTextAnalysis()
    previewView?.clear()
  }

  private func makeWindowController() -> NSWindowController {
    let previewView = SelectableImagePreviewView()
    previewView.setAccessibilityLabel("支持选择文字的截图预览")

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = previewView
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName("SnapClipPreviewWindow")

    self.previewView = previewView
    return NSWindowController(window: window)
  }

  private func beginLiveTextAnalysis(for image: NSImage) {
    analysisTask?.cancel()
    analysisTask = nil
    let requestID = requestGate.begin()

    guard liveTextAnalyzer.isSupported else {
      previewView?.showLiveTextUnavailable()
      return
    }

    previewView?.showAnalyzing()
    analysisTask = Task { [weak self] in
      guard let self else { return }

      do {
        let analysis = try await liveTextAnalyzer.analyze(image)
        guard !Task.isCancelled, requestGate.accepts(requestID) else {
          return
        }

        analysisTask = nil
        if analysis.hasResults(for: .text) {
          previewView?.apply(analysis: analysis)
        } else {
          previewView?.showNoLiveText()
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, requestGate.accepts(requestID) else {
          return
        }
        analysisTask = nil
        previewView?.showLiveTextFailure()
      }
    }
  }

  private func cancelLiveTextAnalysis() {
    analysisTask?.cancel()
    analysisTask = nil
    requestGate.invalidate()
  }

  private func resizeWindow(for image: NSImage, window: NSWindow?) {
    guard let window else { return }

    let visibleFrame =
      window.screen?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

    let maximum = NSSize(
      width: visibleFrame.width * 0.8,
      height: visibleFrame.height * 0.8
    )
    let minimum = NSSize(width: 420, height: 280)
    let imageSize = image.size
    let scale = min(
      maximum.width / max(imageSize.width, 1),
      maximum.height / max(imageSize.height, 1),
      1
    )
    let target = NSSize(
      width: max(minimum.width, imageSize.width * scale),
      height: max(minimum.height, imageSize.height * scale)
    )

    window.setContentSize(target)
    window.center()
  }
}

@MainActor
final class SelectableImagePreviewView: NSView, ImageAnalysisOverlayViewDelegate {
  private let imageView = NSImageView()
  private let overlayView = ImageAnalysisOverlayView()
  private let statusView = NSVisualEffectView()
  private let progressIndicator = NSProgressIndicator()
  private let statusLabel = NSTextField(labelWithString: "")
  private var statusTask: Task<Void, Never>?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureViews()
  }

  func show(image: NSImage) {
    statusTask?.cancel()
    overlayView.resetSelection()
    overlayView.analysis = nil
    imageView.image = image
  }

  func showAnalyzing() {
    showStatus("正在识别可选择文字…", spinning: true)
  }

  func apply(analysis: ImageAnalysis) {
    overlayView.analysis = analysis
    overlayView.setContentsRectNeedsUpdate()
    showTemporaryStatus("可拖选文字，按 ⌘C 复制")
  }

  func showNoLiveText() {
    overlayView.analysis = nil
    showTemporaryStatus("未识别到可选择文字")
  }

  func showLiveTextFailure() {
    overlayView.analysis = nil
    showTemporaryStatus("实况文本识别失败，图片仍可查看")
  }

  func showLiveTextUnavailable() {
    overlayView.analysis = nil
    showTemporaryStatus("此设备不支持实况文本，图片仍可查看")
  }

  func clear() {
    statusTask?.cancel()
    statusTask = nil
    overlayView.resetSelection()
    overlayView.analysis = nil
    imageView.image = nil
    statusView.isHidden = true
    progressIndicator.stopAnimation(nil)
  }

  func contentView(for overlayView: ImageAnalysisOverlayView) -> NSView? {
    imageView
  }

  func overlayView(
    _ overlayView: ImageAnalysisOverlayView,
    shouldHandleKeyDownEvent event: NSEvent
  ) -> Bool {
    true
  }

  func overlayView(
    _ overlayView: ImageAnalysisOverlayView,
    shouldShowMenuForEvent event: NSEvent,
    atPoint point: CGPoint
  ) -> Bool {
    true
  }

  private func configureViews() {
    imageView.imageAlignment = .alignCenter
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.setAccessibilityLabel("截图")

    overlayView.delegate = self
    overlayView.trackingImageView = imageView
    overlayView.preferredInteractionTypes = .textSelection
    overlayView.translatesAutoresizingMaskIntoConstraints = false
    overlayView.setAccessibilityLabel("可选择的图片文字")

    statusView.material = .hudWindow
    statusView.blendingMode = .withinWindow
    statusView.state = .active
    statusView.wantsLayer = true
    statusView.layer?.cornerRadius = 8
    statusView.translatesAutoresizingMaskIntoConstraints = false
    statusView.isHidden = true

    progressIndicator.style = .spinning
    progressIndicator.controlSize = .small
    progressIndicator.isDisplayedWhenStopped = false
    progressIndicator.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.textColor = .labelColor
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(imageView)
    addSubview(overlayView)
    addSubview(statusView)
    statusView.addSubview(progressIndicator)
    statusView.addSubview(statusLabel)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      overlayView.topAnchor.constraint(equalTo: topAnchor),
      overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
      statusView.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
      progressIndicator.leadingAnchor.constraint(equalTo: statusView.leadingAnchor, constant: 10),
      progressIndicator.centerYAnchor.constraint(equalTo: statusView.centerYAnchor),
      statusLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 7),
      statusLabel.trailingAnchor.constraint(equalTo: statusView.trailingAnchor, constant: -10),
      statusLabel.topAnchor.constraint(equalTo: statusView.topAnchor, constant: 7),
      statusLabel.bottomAnchor.constraint(equalTo: statusView.bottomAnchor, constant: -7),
    ])
  }

  private func showStatus(_ message: String, spinning: Bool) {
    statusTask?.cancel()
    statusTask = nil
    statusLabel.stringValue = message
    statusView.isHidden = false
    if spinning {
      progressIndicator.startAnimation(nil)
    } else {
      progressIndicator.stopAnimation(nil)
    }
  }

  private func showTemporaryStatus(_ message: String) {
    showStatus(message, spinning: false)
    statusTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.statusView.isHidden = true
      self?.statusTask = nil
    }
  }
}
