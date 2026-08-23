import Foundation
import XCTest

@testable import SnapClip

@MainActor
final class HistoryStoreTests: XCTestCase {
  func testKeepsNewestThreeItems() {
    let store = HistoryStore(capacity: 3)

    store.insert(pngData: Data([1]), capturedAt: Date(timeIntervalSince1970: 1))
    store.insert(pngData: Data([2]), capturedAt: Date(timeIntervalSince1970: 2))
    store.insert(pngData: Data([3]), capturedAt: Date(timeIntervalSince1970: 3))
    store.insert(pngData: Data([4]), capturedAt: Date(timeIntervalSince1970: 4))

    XCTAssertEqual(store.items.map(\.pngData), [Data([4]), Data([3]), Data([2])])
  }

  func testOCRUpdateDoesNotReorderItems() {
    let store = HistoryStore()
    let older = store.insert(pngData: Data([1]))
    let newer = store.insert(pngData: Data([2]))

    store.markRecognizing(id: older.id)
    store.storeRecognizedText("hello", id: older.id)

    XCTAssertEqual(store.items.map(\.id), [newer.id, older.id])
    XCTAssertEqual(store.item(id: older.id)?.recognizedText, "hello")
    XCTAssertEqual(store.item(id: older.id)?.ocrState, .completed)
  }

  func testClearRemovesAllItems() {
    let store = HistoryStore()
    store.insert(pngData: Data([1]))
    store.insert(pngData: Data([2]))

    store.clear()

    XCTAssertTrue(store.items.isEmpty)
  }
}
