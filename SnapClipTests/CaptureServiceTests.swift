import Foundation
import XCTest

@testable import SnapClip

actor MockProcessRunner: ProcessRunning {
  private let status: Int32
  private let outputData: Data?
  private(set) var calls: [[String]] = []

  init(status: Int32, outputData: Data?) {
    self.status = status
    self.outputData = outputData
  }

  func run(executableURL: URL, arguments: [String]) async throws -> Int32 {
    calls.append(arguments)
    if let outputData, let path = arguments.last {
      try outputData.write(to: URL(fileURLWithPath: path))
    }
    return status
  }
}

final class CaptureServiceTests: XCTestCase {
  private let onePixelPNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  )!

  func testInteractiveArgumentsAndTemporaryFileCleanup() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let runner = MockProcessRunner(status: 0, outputData: onePixelPNG)
    let service = SystemCaptureService(
      processRunner: runner,
      temporaryDirectory: temporaryDirectory
    )

    let outcome = try await service.capture(mode: .interactive, soundEnabled: false)

    XCTAssertEqual(outcome, .captured(onePixelPNG))
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(Array(calls[0].prefix(4)), ["-i", "-t", "png", "-x"])
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).isEmpty)
  }

  func testMissingOutputIsCancellation() async throws {
    let runner = MockProcessRunner(status: 1, outputData: nil)
    let service = SystemCaptureService(processRunner: runner)

    let outcome = try await service.capture(mode: .interactive, soundEnabled: true)

    XCTAssertEqual(outcome, .cancelled)
  }

  func testUnexpectedExitWithoutOutputIsFailure() async {
    let runner = MockProcessRunner(status: 2, outputData: nil)
    let service = SystemCaptureService(processRunner: runner)

    do {
      _ = try await service.capture(mode: .interactive, soundEnabled: true)
      XCTFail("Expected process failure")
    } catch {
      XCTAssertEqual(error as? CaptureError, .processFailed(2))
    }
  }

  func testMainDisplayArguments() {
    let output = URL(fileURLWithPath: "/tmp/example.png")

    let arguments = SystemCaptureService.arguments(
      for: .mainDisplay,
      soundEnabled: true,
      outputURL: output
    )

    XCTAssertEqual(arguments, ["-m", "-t", "png", "/tmp/example.png"])
  }

  func testCleanupRemovesOnlyStaleSnapClipPNGs() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let stale = directory.appendingPathComponent("SnapClip-stale.png")
    let recent = directory.appendingPathComponent("SnapClip-recent.png")
    let unrelated = directory.appendingPathComponent("other.png")
    try Data([1]).write(to: stale)
    try Data([2]).write(to: recent)
    try Data([3]).write(to: unrelated)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)],
      ofItemAtPath: stale.path
    )

    SystemCaptureService.cleanupStaleTemporaryFiles(
      in: directory,
      now: Date(timeIntervalSince1970: 7200)
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }
}
