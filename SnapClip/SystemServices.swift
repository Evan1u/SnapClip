import AppKit
import CoreGraphics
import Foundation
import ServiceManagement
@preconcurrency import Vision

@MainActor
protocol ClipboardServing {
  @discardableResult
  func copyImage(pngData: Data) -> Bool

  @discardableResult
  func copyText(_ text: String) -> Bool
}

@MainActor
final class SystemClipboardService: ClipboardServing {
  @discardableResult
  func copyImage(pngData: Data) -> Bool {
    guard let image = NSImage(data: pngData) else {
      return false
    }

    let item = NSPasteboardItem()
    item.setData(pngData, forType: .png)
    if let tiffData = image.tiffRepresentation {
      item.setData(tiffData, forType: .tiff)
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }

  @discardableResult
  func copyText(_ text: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }
}

protocol DesktopExportServing: Sendable {
  func savePNG(_ pngData: Data, capturedAt: Date) async throws -> URL
}

enum DesktopExportError: LocalizedError, Equatable, Sendable {
  case desktopUnavailable
  case noAvailableFilename

  var errorDescription: String? {
    switch self {
    case .desktopUnavailable:
      return "无法找到桌面文件夹。"
    case .noAvailableFilename:
      return "无法生成可用的截图文件名。"
    }
  }
}

struct DesktopExportService: DesktopExportServing {
  private let desktopDirectory: URL?
  private let timeZone: TimeZone

  init(
    desktopDirectory: URL? = nil,
    timeZone: TimeZone = .current
  ) {
    self.desktopDirectory = desktopDirectory
    self.timeZone = timeZone
  }

  func savePNG(_ pngData: Data, capturedAt: Date) async throws -> URL {
    let directory =
      desktopDirectory
      ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    guard let directory else {
      throw DesktopExportError.desktopUnavailable
    }

    return try await Task.detached(priority: .userInitiated) {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = timeZone
      formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
      let baseName = "SnapClip \(formatter.string(from: capturedAt))"
      let temporaryURL = directory.appendingPathComponent(
        ".SnapClip-\(UUID().uuidString).tmp"
      )
      try pngData.write(to: temporaryURL, options: .atomic)
      defer { try? FileManager.default.removeItem(at: temporaryURL) }

      for index in 1...9_999 {
        let suffix = index == 1 ? "" : " \(index)"
        let destination = directory.appendingPathComponent("\(baseName)\(suffix).png")

        guard !FileManager.default.fileExists(atPath: destination.path) else {
          continue
        }

        do {
          try FileManager.default.moveItem(at: temporaryURL, to: destination)
          return destination
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          continue
        }
      }

      throw DesktopExportError.noAvailableFilename
    }.value
  }
}

struct OCRLine: Equatable, Sendable {
  let text: String
  let boundingBox: CGRect
}

private struct OCRRow {
  let anchorY: CGFloat
  let anchorHeight: CGFloat
  var lines: [OCRLine]
}

enum OCRError: LocalizedError, Equatable {
  case invalidImage
  case noText

  var errorDescription: String? {
    switch self {
    case .invalidImage:
      return "无法读取这张截图。"
    case .noText:
      return "未识别到文字。"
    }
  }
}

protocol OCRServing: Sendable {
  func recognizeText(in pngData: Data) async throws -> String
}

struct VisionOCRService: OCRServing {
  func recognizeText(in pngData: Data) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

      let handler = VNImageRequestHandler(data: pngData, options: [:])
      try handler.perform([request])

      let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
        guard let candidate = observation.topCandidates(1).first else {
          return nil
        }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
          return nil
        }
        return OCRLine(text: text, boundingBox: observation.boundingBox)
      }

      return try Self.joinLines(lines)
    }.value
  }

  static func joinLines(_ lines: [OCRLine]) throws -> String {
    let topToBottom = lines.sorted { left, right in
      if left.boundingBox.midY != right.boundingBox.midY {
        return left.boundingBox.midY > right.boundingBox.midY
      }
      if left.boundingBox.minX != right.boundingBox.minX {
        return left.boundingBox.minX < right.boundingBox.minX
      }
      return left.text < right.text
    }

    var rows: [OCRRow] = []
    for line in topToBottom {
      if let lastIndex = rows.indices.last {
        let row = rows[lastIndex]
        let threshold = max(row.anchorHeight, line.boundingBox.height) * 0.55
        if abs(row.anchorY - line.boundingBox.midY) <= threshold {
          rows[lastIndex].lines.append(line)
          continue
        }
      }
      rows.append(
        OCRRow(
          anchorY: line.boundingBox.midY,
          anchorHeight: line.boundingBox.height,
          lines: [line]
        ))
    }

    let ordered = rows.flatMap { row in
      row.lines.sorted { left, right in
        if left.boundingBox.minX != right.boundingBox.minX {
          return left.boundingBox.minX < right.boundingBox.minX
        }
        return left.text < right.text
      }
    }

    let text =
      ordered
      .map(\.text)
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !text.isEmpty else {
      throw OCRError.noText
    }

    return text
  }
}

@MainActor
protocol ScreenCapturePermissionServing {
  var isAuthorized: Bool { get }
  func requestAuthorization() -> Bool
  func openSystemSettings()
}

@MainActor
final class ScreenCapturePermissionService: ScreenCapturePermissionServing {
  var isAuthorized: Bool {
    CGPreflightScreenCaptureAccess()
  }

  func requestAuthorization() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  func openSystemSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}

enum LoginItemStatus: Equatable {
  case disabled
  case enabled
  case requiresApproval
  case unavailable
}

@MainActor
protocol LoginItemServing {
  var status: LoginItemStatus { get }
  func setEnabled(_ enabled: Bool) throws
  func openSystemSettings()
}

@MainActor
final class LoginItemService: LoginItemServing {
  var status: LoginItemStatus {
    switch SMAppService.mainApp.status {
    case .enabled:
      return .enabled
    case .requiresApproval:
      return .requiresApproval
    case .notFound:
      return .unavailable
    case .notRegistered:
      return .disabled
    @unknown default:
      return .unavailable
    }
  }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  func openSystemSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
