import AppKit
import CoreGraphics
import Foundation
@preconcurrency import Vision

struct QRCodeResult: Identifiable, Equatable, Sendable {
  let id: UUID
  let rawPayload: String
  let boundingBox: CGRect

  init(
    id: UUID = UUID(),
    rawPayload: String,
    boundingBox: CGRect
  ) {
    self.id = id
    self.rawPayload = rawPayload
    self.boundingBox = boundingBox
  }
}

enum QRCodeRecognitionError: LocalizedError, Equatable, Sendable {
  case invalidImage
  case noQRCode
  case visionFailed

  var errorDescription: String? {
    switch self {
    case .invalidImage:
      return "无法读取当前画面。"
    case .noQRCode:
      return "未识别到二维码。"
    case .visionFailed:
      return "二维码识别失败，请重试。"
    }
  }
}

protocol QRCodeRecognizing: Sendable {
  func recognizeQRCodes(in pngData: Data) async throws -> [QRCodeResult]
}

struct VisionQRCodeService: QRCodeRecognizing {
  func recognizeQRCodes(in pngData: Data) async throws -> [QRCodeResult] {
    guard !pngData.isEmpty else {
      throw QRCodeRecognitionError.invalidImage
    }

    return try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let request = VNDetectBarcodesRequest()
      request.symbologies = [.qr]
      let handler = VNImageRequestHandler(data: pngData, options: [:])

      do {
        try handler.perform([request])
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw QRCodeRecognitionError.visionFailed
      }

      try Task.checkCancellation()
      let results = (request.results ?? []).compactMap { observation -> QRCodeResult? in
        guard let payload = observation.payloadStringValue else { return nil }
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return nil
        }
        return QRCodeResult(
          rawPayload: payload,
          boundingBox: observation.boundingBox
        )
      }
      .sorted { left, right in
        if left.boundingBox.midY != right.boundingBox.midY {
          return left.boundingBox.midY > right.boundingBox.midY
        }
        if left.boundingBox.minX != right.boundingBox.minX {
          return left.boundingBox.minX < right.boundingBox.minX
        }
        return left.rawPayload < right.rawPayload
      }

      guard !results.isEmpty else {
        throw QRCodeRecognitionError.noQRCode
      }
      return results
    }.value
  }
}

enum QRCodePayloadKind: Equatable, Sendable {
  case link(url: URL, displayHost: String, copyValue: String)
  case text(String)
}

enum QRCodePayloadClassifier {
  static func classify(_ rawPayload: String) -> QRCodePayloadKind {
    let value = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !value.isEmpty,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      var components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.user == nil,
      components.password == nil,
      let host = components.host,
      !host.isEmpty
    else {
      return .text(rawPayload)
    }

    components.scheme = scheme
    guard let url = components.url else {
      return .text(rawPayload)
    }
    let displayHost = components.port.map { "\(host):\($0)" } ?? host
    return .link(url: url, displayHost: displayHost, copyValue: value)
  }
}

@MainActor
protocol ExternalURLOpening {
  func open(_ url: URL) -> Bool
}

@MainActor
struct SystemExternalURLOpener: ExternalURLOpening {
  func open(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
  }
}
