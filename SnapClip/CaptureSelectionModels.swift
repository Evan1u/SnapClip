import CoreGraphics
import Foundation

/// Whether an overlay panel is currently looking for a rectangular region or
/// a clickable window.
enum CaptureSelectionMode: Equatable, Sendable {
  case region
  case window
}

enum UserCancelReason: Equatable, Sendable {
  case escape
  case rightClick
  case tooSmall
}

enum CaptureSelectionDecision: Equatable, Sendable {
  case region(displayID: CGDirectDisplayID, rectInDisplayPoints: CGRect)
  case window(CaptureWindowDescriptor)
  case cancelled(UserCancelReason)
}

/// Pure drag bookkeeping. All coordinates are display-local AppKit points
/// (bottom-left origin).
struct CaptureDragState: Equatable, Sendable {
  let startPoint: CGPoint
  var currentPoint: CGPoint

  init(startPoint: CGPoint, currentPoint: CGPoint? = nil) {
    self.startPoint = startPoint
    self.currentPoint = currentPoint ?? startPoint
  }

  var movement: CGSize {
    CGSize(
      width: currentPoint.x - startPoint.x,
      height: currentPoint.y - startPoint.y
    )
  }

  var isClick: Bool {
    abs(movement.width) <= CaptureSelectionMetrics.clickThresholdPoints
      && abs(movement.height) <= CaptureSelectionMetrics.clickThresholdPoints
  }
}

enum CaptureSelectionMetrics {
  static let minSelectionSize: CGFloat = 10
  static let clickThresholdPoints: CGFloat = 6
}

enum CaptureSelectionMath {
  static func normalizedRect(
    start: CGPoint,
    end: CGPoint
  ) -> CGRect {
    CGRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    )
  }

  /// Clamps to `bounds` and returns nil when the result is too small to be a
  /// meaningful screenshot.
  static func validSelectionRect(
    start: CGPoint,
    end: CGPoint,
    bounds: CGRect
  ) -> CGRect? {
    let raw = normalizedRect(start: start, end: end)
    let clamped = raw.intersection(bounds)
    guard
      !clamped.isNull,
      !clamped.isEmpty,
      clamped.width >= CaptureSelectionMetrics.minSelectionSize,
      clamped.height >= CaptureSelectionMetrics.minSelectionSize
    else {
      return nil
    }
    return clamped
  }
}
