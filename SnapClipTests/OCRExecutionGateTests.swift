import Foundation
import XCTest

@testable import SnapClip

private struct StubGateOCRService: OCRServing {
  let text: String
  var delayNanoseconds: UInt64 = 0

  func recognizeText(in pngData: Data) async throws -> String {
    if delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return text
  }
}

final class OCRExecutionGateTests: XCTestCase {
  func testRecognizeReturnsResultAndRejectsSecondConcurrentRequest() async throws {
    let gate = OCRExecutionGate(
      ocrService: StubGateOCRService(text: "结果", delayNanoseconds: 100_000_000)
    )
    let first = Task {
      try await gate.recognize(requestID: UUID(), pngData: Data([1]))
    }
    try? await Task.sleep(for: .milliseconds(20))

    do {
      _ = try await gate.recognize(requestID: UUID(), pngData: Data([2]))
      XCTFail("Expected busy")
    } catch {
      XCTAssertEqual(error as? OCRExecutionError, .busy)
    }

    let firstResult = try await first.value
    XCTAssertEqual(firstResult, "结果")
    let retry = try await gate.recognize(requestID: UUID(), pngData: Data([3]))
    XCTAssertEqual(retry, "结果")
  }

  func testCancelKeepsBusyUntilUnderlyingCallCompletes() async throws {
    let gate = OCRExecutionGate(
      ocrService: StubGateOCRService(text: "done", delayNanoseconds: 100_000_000)
    )
    let requestID = UUID()
    let first = Task {
      try await gate.recognize(requestID: requestID, pngData: Data([1]))
    }
    try? await Task.sleep(for: .milliseconds(20))
    await gate.cancel(requestID: requestID)

    do {
      _ = try await gate.recognize(requestID: UUID(), pngData: Data([2]))
      XCTFail("Expected busy while underlying request is still running")
    } catch {
      XCTAssertEqual(error as? OCRExecutionError, .busy)
    }
    _ = try? await first.value
  }
}
