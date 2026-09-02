import Combine
import Foundation

enum CaptureMode: Sendable {
  case interactive
  case mainDisplay
}

enum OCRState: Equatable, Sendable {
  case idle
  case recognizing
  case completed
  case failed(String)
}

struct ScreenshotItem: Identifiable, Equatable, Sendable {
  let id: UUID
  let capturedAt: Date
  var pngData: Data
  var imageRevision: UInt64
  var recognizedText: String?
  var ocrState: OCRState

  init(
    id: UUID = UUID(),
    capturedAt: Date = Date(),
    pngData: Data,
    imageRevision: UInt64 = 0,
    recognizedText: String? = nil,
    ocrState: OCRState = .idle
  ) {
    self.id = id
    self.capturedAt = capturedAt
    self.pngData = pngData
    self.imageRevision = imageRevision
    self.recognizedText = recognizedText
    self.ocrState = ocrState
  }
}

@MainActor
final class HistoryStore: ObservableObject {
  static let defaultCapacity = 3

  @Published private(set) var items: [ScreenshotItem] = []

  private let capacity: Int

  init(capacity: Int = HistoryStore.defaultCapacity) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  @discardableResult
  func insert(pngData: Data, capturedAt: Date = Date()) -> ScreenshotItem {
    let item = ScreenshotItem(capturedAt: capturedAt, pngData: pngData)
    items.insert(item, at: 0)

    if items.count > capacity {
      items.removeLast(items.count - capacity)
    }

    return item
  }

  func item(id: UUID) -> ScreenshotItem? {
    items.first { $0.id == id }
  }

  func markRecognizing(id: UUID) {
    update(id: id) { item in
      item.ocrState = .recognizing
    }
  }

  func storeRecognizedText(_ text: String, id: UUID) {
    update(id: id) { item in
      item.recognizedText = text
      item.ocrState = .completed
    }
  }

  func markOCRFailed(_ message: String, id: UUID) {
    update(id: id) { item in
      item.ocrState = .failed(message)
    }
  }

  @discardableResult
  func commitEditorOutput(
    id: UUID,
    expectedImageRevision: UInt64,
    pngData: Data,
    contentChanged: Bool,
    ocrCache: OCRCacheDisposition
  ) -> Bool {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return false
    }
    guard items[index].imageRevision == expectedImageRevision else {
      return false
    }

    switch ocrCache {
    case .preserve:
      guard !contentChanged else { return false }
    case .clear:
      items[index].recognizedText = nil
      items[index].ocrState = .idle
    case .replace(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return false }
      items[index].recognizedText = trimmed
      items[index].ocrState = .completed
    }

    if contentChanged {
      items[index].pngData = pngData
      items[index].imageRevision &+= 1
    }
    return true
  }

  @discardableResult
  func markRecognizing(
    id: UUID,
    expectedImageRevision: UInt64
  ) -> Bool {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return false
    }
    guard items[index].imageRevision == expectedImageRevision else {
      return false
    }
    items[index].ocrState = .recognizing
    return true
  }

  @discardableResult
  func storeRecognizedText(
    _ text: String,
    id: UUID,
    expectedImageRevision: UInt64
  ) -> Bool {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return false
    }
    guard items[index].imageRevision == expectedImageRevision else {
      return false
    }
    items[index].recognizedText = text
    items[index].ocrState = .completed
    return true
  }

  @discardableResult
  func markOCRFailed(
    _ message: String,
    id: UUID,
    expectedImageRevision: UInt64
  ) -> Bool {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return false
    }
    guard items[index].imageRevision == expectedImageRevision else {
      return false
    }
    items[index].ocrState = .failed(message)
    return true
  }

  func clear() {
    items.removeAll(keepingCapacity: false)
  }

  private func update(id: UUID, mutation: (inout ScreenshotItem) -> Void) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return
    }
    mutation(&items[index])
  }
}

enum HotKeyModifier {
  static let command: UInt32 = 1 << 8
  static let shift: UInt32 = 1 << 9
  static let option: UInt32 = 1 << 11
  static let control: UInt32 = 1 << 12
}

struct HotKeyShortcut: Codable, Equatable, Hashable, Sendable {
  let keyCode: UInt32
  let modifiers: UInt32
  let keyLabel: String

  static let interactiveDefault = HotKeyShortcut(
    keyCode: 21,
    modifiers: HotKeyModifier.command | HotKeyModifier.shift,
    keyLabel: "4"
  )

  static let mainDisplayDefault = HotKeyShortcut(
    keyCode: 20,
    modifiers: HotKeyModifier.command | HotKeyModifier.shift,
    keyLabel: "3"
  )

  static let legacyInteractiveDefault = HotKeyShortcut(
    keyCode: 21,
    modifiers: HotKeyModifier.control | HotKeyModifier.option,
    keyLabel: "4"
  )

  static let legacyMainDisplayDefault = HotKeyShortcut(
    keyCode: 20,
    modifiers: HotKeyModifier.control | HotKeyModifier.option,
    keyLabel: "3"
  )

  var requiresSystemScreenshotInterception: Bool {
    self == Self.interactiveDefault || self == Self.mainDisplayDefault
  }

  var displayString: String {
    var value = ""
    if modifiers & HotKeyModifier.control != 0 { value += "⌃" }
    if modifiers & HotKeyModifier.option != 0 { value += "⌥" }
    if modifiers & HotKeyModifier.shift != 0 { value += "⇧" }
    if modifiers & HotKeyModifier.command != 0 { value += "⌘" }
    return value + keyLabel.uppercased()
  }
}

enum HotKeyAction: UInt32, CaseIterable, Sendable {
  case interactiveCapture = 1
  case mainDisplayCapture = 2
}
