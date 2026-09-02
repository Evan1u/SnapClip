import Foundation

enum OCRExecutionError: LocalizedError, Equatable {
  case busy

  var errorDescription: String? {
    "请等待当前文字识别完成。"
  }
}

actor OCRExecutionGate {
  private let ocrService: any OCRServing
  private var activeRequestID: UUID?
  private var activeTask: Task<String, Error>?

  init(ocrService: any OCRServing) {
    self.ocrService = ocrService
  }

  func recognize(requestID: UUID, pngData: Data) async throws -> String {
    guard activeTask == nil else {
      throw OCRExecutionError.busy
    }
    activeRequestID = requestID
    let task = Task { [ocrService] in
      try await ocrService.recognizeText(in: pngData)
    }
    activeTask = task
    defer {
      if activeRequestID == requestID {
        activeRequestID = nil
        activeTask = nil
      }
    }
    return try await task.value
  }

  func cancel(requestID: UUID) {
    guard activeRequestID == requestID else { return }
    activeTask?.cancel()
  }

  var hasActiveRequest: Bool {
    activeTask != nil
  }
}
