import AppKit
import Foundation

protocol ProcessRunning: Sendable {
  func run(executableURL: URL, arguments: [String]) async throws -> Int32
}

struct FoundationProcessRunner: ProcessRunning {
  func run(executableURL: URL, arguments: [String]) async throws -> Int32 {
    let controller = ProcessController(
      executableURL: executableURL,
      arguments: arguments
    )

    let status = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        controller.process.terminationHandler = { process in
          continuation.resume(returning: process.terminationStatus)
        }

        do {
          guard try controller.start() else {
            continuation.resume(throwing: CancellationError())
            return
          }
        } catch {
          controller.process.terminationHandler = nil
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      controller.cancel()
    }

    try Task.checkCancellation()
    return status
  }
}

private final class ProcessController: @unchecked Sendable {
  let process = Process()

  private let executableURL: URL
  private let arguments: [String]
  private let lock = NSLock()
  private var isCancelled = false

  init(executableURL: URL, arguments: [String]) {
    self.executableURL = executableURL
    self.arguments = arguments
  }

  func start() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }

    guard !isCancelled else {
      return false
    }

    process.executableURL = executableURL
    process.arguments = arguments
    try process.run()
    return true
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let shouldTerminate = process.isRunning
    lock.unlock()

    if shouldTerminate {
      process.terminate()
    }
  }
}

protocol CaptureServing: Sendable {
  func capture(mode: CaptureMode, soundEnabled: Bool) async throws -> CaptureOutcome
}

actor SystemCaptureService: CaptureServing {
  private let processRunner: any ProcessRunning
  private let temporaryDirectory: URL
  private var isCapturing = false

  init(
    processRunner: any ProcessRunning = FoundationProcessRunner(),
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    self.processRunner = processRunner
    self.temporaryDirectory = temporaryDirectory
    Self.cleanupStaleTemporaryFiles(in: temporaryDirectory)
  }

  func capture(mode: CaptureMode, soundEnabled: Bool) async throws -> CaptureOutcome {
    guard !isCapturing else {
      throw CaptureError.busy
    }

    isCapturing = true
    defer { isCapturing = false }

    let outputURL =
      temporaryDirectory
      .appendingPathComponent("SnapClip-\(UUID().uuidString)")
      .appendingPathExtension("png")

    defer {
      try? FileManager.default.removeItem(at: outputURL)
    }

    let arguments = Self.arguments(
      for: mode,
      soundEnabled: soundEnabled,
      outputURL: outputURL
    )

    let status = try await processRunner.run(
      executableURL: URL(fileURLWithPath: "/usr/sbin/screencapture"),
      arguments: arguments
    )

    guard FileManager.default.fileExists(atPath: outputURL.path) else {
      if status == 0 || status == 1 {
        return .cancelled
      }
      throw CaptureError.processFailed(status)
    }

    guard status == 0 else {
      throw CaptureError.processFailed(status)
    }

    let data = try Data(contentsOf: outputURL)
    guard NSImage(data: data) != nil else {
      throw CaptureError.invalidImage
    }

    return .captured(data)
  }

  static func arguments(
    for mode: CaptureMode,
    soundEnabled: Bool,
    outputURL: URL
  ) -> [String] {
    var arguments: [String]

    switch mode {
    case .interactive:
      arguments = ["-i", "-t", "png"]
    case .mainDisplay:
      arguments = ["-m", "-t", "png"]
    }

    if !soundEnabled {
      arguments.append("-x")
    }

    arguments.append(outputURL.path)
    return arguments
  }

  static func cleanupStaleTemporaryFiles(
    in directory: URL,
    now: Date = Date()
  ) {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    for file in files
    where file.lastPathComponent.hasPrefix("SnapClip-")
      && file.pathExtension.lowercased() == "png"
    {
      guard
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
        let modifiedAt = values.contentModificationDate,
        now.timeIntervalSince(modifiedAt) > 60 * 60
      else {
        continue
      }
      try? FileManager.default.removeItem(at: file)
    }
  }
}
