import CoreGraphics
import Foundation
import XCTest

@testable import SnapClip

private final class RecordedActions: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [HotKeyAction] = []

  func append(_ action: HotKeyAction) {
    lock.lock()
    storage.append(action)
    lock.unlock()
  }

  var values: [HotKeyAction] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

final class HotKeyShortcutTests: XCTestCase {
  func testDefaultDisplayStrings() {
    XCTAssertEqual(HotKeyShortcut.interactiveDefault.displayString, "⇧⌘4")
    XCTAssertEqual(HotKeyShortcut.mainDisplayDefault.displayString, "⇧⌘3")
    XCTAssertTrue(HotKeyShortcut.interactiveDefault.requiresSystemScreenshotInterception)
    XCTAssertTrue(HotKeyShortcut.mainDisplayDefault.requiresSystemScreenshotInterception)
  }

  func testLegacyDefaultsRemainAvailableForMigration() {
    XCTAssertEqual(HotKeyShortcut.legacyInteractiveDefault.displayString, "⌃⌥4")
    XCTAssertEqual(HotKeyShortcut.legacyMainDisplayDefault.displayString, "⌃⌥3")
    XCTAssertFalse(HotKeyShortcut.legacyInteractiveDefault.requiresSystemScreenshotInterception)
    XCTAssertFalse(HotKeyShortcut.legacyMainDisplayDefault.requiresSystemScreenshotInterception)
  }

  func testRoundTripEncoding() throws {
    let shortcut = HotKeyShortcut(
      keyCode: 12,
      modifiers: HotKeyModifier.command | HotKeyModifier.shift,
      keyLabel: "Q"
    )

    let data = try JSONEncoder().encode(shortcut)
    let decoded = try JSONDecoder().decode(HotKeyShortcut.self, from: data)

    XCTAssertEqual(decoded, shortcut)
    XCTAssertEqual(decoded.displayString, "⇧⌘Q")
  }

  func testSystemInterceptorConsumesMatchingKeyAndSuppressesRepeat() throws {
    let recorded = RecordedActions()
    let interceptor = SystemShortcutInterceptor(handler: recorded.append)
    interceptor.configure([
      .interactiveCapture: .interactiveDefault,
      .mainDisplayCapture: .mainDisplayDefault,
    ])

    let event = try XCTUnwrap(
      CGEvent(
        keyboardEventSource: nil,
        virtualKey: CGKeyCode(HotKeyShortcut.mainDisplayDefault.keyCode),
        keyDown: true
      )
    )
    event.flags = [.maskCommand, .maskShift, .maskAlphaShift]

    XCTAssertNil(interceptor.handle(type: .keyDown, event: event))
    XCTAssertEqual(recorded.values, [.mainDisplayCapture])

    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    XCTAssertNil(interceptor.handle(type: .keyDown, event: event))
    XCTAssertEqual(recorded.values, [.mainDisplayCapture])
  }

  func testSystemInterceptorPassesUnmatchedKeyThrough() throws {
    let recorded = RecordedActions()
    let interceptor = SystemShortcutInterceptor(handler: recorded.append)
    interceptor.configure([.interactiveCapture: .interactiveDefault])
    let event = try XCTUnwrap(
      CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)
    )
    event.flags = [.maskCommand, .maskShift]

    XCTAssertNotNil(interceptor.handle(type: .keyDown, event: event))
    XCTAssertTrue(recorded.values.isEmpty)
  }
}
