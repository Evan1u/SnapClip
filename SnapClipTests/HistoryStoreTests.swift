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

  func testCommitEditorOutputReplacesPNGAndBumpsImageRevision() {
    let store = HistoryStore()
    let item = store.insert(pngData: Data([1]))

    let result = store.commitEditorOutput(
      id: item.id,
      expectedImageRevision: 0,
      pngData: Data([2]),
      contentChanged: true,
      ocrCache: .clear
    )

    XCTAssertTrue(result)
    XCTAssertEqual(store.item(id: item.id)?.pngData, Data([2]))
    XCTAssertEqual(store.item(id: item.id)?.imageRevision, 1)
    XCTAssertEqual(store.item(id: item.id)?.ocrState, .idle)
  }

  func testCommitEditorOutputPreserveRequiresUnchangedContent() {
    let store = HistoryStore()
    let item = store.insert(pngData: Data([1]))

    let rejected = store.commitEditorOutput(
      id: item.id,
      expectedImageRevision: 0,
      pngData: Data([2]),
      contentChanged: true,
      ocrCache: .preserve
    )
    XCTAssertFalse(rejected)

    let accepted = store.commitEditorOutput(
      id: item.id,
      expectedImageRevision: 0,
      pngData: Data([1]),
      contentChanged: false,
      ocrCache: .preserve
    )
    XCTAssertTrue(accepted)
    XCTAssertEqual(store.item(id: item.id)?.imageRevision, 0)
  }

  func testStaleRevisionIsRejectedForCommitAndOCRWrites() {
    let store = HistoryStore()
    let item = store.insert(pngData: Data([1]))

    XCTAssertFalse(
      store.commitEditorOutput(
        id: item.id,
        expectedImageRevision: 1,
        pngData: Data([2]),
        contentChanged: true,
        ocrCache: .clear
      )
    )
    XCTAssertFalse(store.markRecognizing(id: item.id, expectedImageRevision: 1))
    XCTAssertFalse(
      store.storeRecognizedText("late", id: item.id, expectedImageRevision: 1)
    )
  }

  func testClearRemovesAllItems() {
    let store = HistoryStore()
    store.insert(pngData: Data([1]))
    store.insert(pngData: Data([2]))

    store.clear()

    XCTAssertTrue(store.items.isEmpty)
  }
}
