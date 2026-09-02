import AppKit
import Foundation
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
