import AppKit
import VisionKit

@MainActor
final class EditorOCRSelectionView: NSView, ImageAnalysisOverlayViewDelegate {
  private let imageView = NSImageView()
  private let overlayView = ImageAnalysisOverlayView()
  private let liveTextAnalyzer: any LiveTextAnalyzing
  private var analysisTask: Task<Void, Never>?
  private var requestGate = PreviewAnalysisRequestGate()

  init(liveTextAnalyzer: any LiveTextAnalyzing = VisionKitLiveTextAnalyzer()) {
    self.liveTextAnalyzer = liveTextAnalyzer
    super.init(frame: .zero)
    configureViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var isFlipped: Bool { true }

  func showImage(_ image: NSImage?) {
    cancelAnalysis()
    overlayView.resetSelection()
    overlayView.analysis = nil
    imageView.image = image
  }

  func beginAnalysis(for image: NSImage?) {
    guard let image else {
      showImage(nil)
      return
    }
    showImage(image)
    guard liveTextAnalyzer.isSupported else { return }

    let requestID = requestGate.begin()
    analysisTask = Task { [weak self, liveTextAnalyzer] in
      do {
        let analysis = try await liveTextAnalyzer.analyze(image)
        guard let self, !Task.isCancelled, self.requestGate.accepts(requestID) else {
          return
        }
        self.analysisTask = nil
        self.overlayView.analysis = analysis
      } catch is CancellationError {
        return
      } catch {
        guard let self, !Task.isCancelled, self.requestGate.accepts(requestID) else {
          return
        }
        self.analysisTask = nil
      }
    }
  }

  func reset() {
    cancelAnalysis()
    showImage(nil)
  }

  private func cancelAnalysis() {
    analysisTask?.cancel()
    analysisTask = nil
    requestGate.invalidate()
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
    wantsLayer = true
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.setAccessibilityLabel("截图")

    overlayView.delegate = self
    overlayView.trackingImageView = imageView
    overlayView.preferredInteractionTypes = .textSelection
    overlayView.translatesAutoresizingMaskIntoConstraints = false
    overlayView.setAccessibilityLabel("可选择的图片文字")

    addSubview(imageView)
    addSubview(overlayView)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      overlayView.topAnchor.constraint(equalTo: topAnchor),
      overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}
