import AppKit
import CoreGraphics
import Foundation

/// Live Quartz hit testing for the window-capture mode. This intentionally
/// reads window geometry only; actual window pixels come from ScreenCaptureKit.
struct WindowHitTestResult: Sendable, Equatable {
  let windowID: CGWindowID
  /// AppKit global screen points (bottom-left origin).
  let frameInAppKitPoints: CGRect
  let ownerPID: pid_t
  let ownerName: String?
  let layer: Int
}

@MainActor
enum WindowHitTester {
  private static let systemProcessBlacklist: Set<String> = [
    "Window Server",
    "Dock",
    "SystemUIServer",
  ]

  private struct Candidate {
    let windowID: CGWindowID
    let quartzBounds: CGRect
    let ownerPID: pid_t
    let ownerName: String?
    let layer: Int

    var area: CGFloat {
      quartzBounds.width * quartzBounds.height
    }
  }

  static func hitTestAtMouse(skipSelfWindows: Bool = true) -> WindowHitTestResult? {
    let appKitPoint = NSEvent.mouseLocation
    return hitTest(appKitPoint: appKitPoint, skipSelfWindows: skipSelfWindows)
  }

  static func hitTest(
    appKitPoint: CGPoint,
    skipSelfWindows: Bool = true
  ) -> WindowHitTestResult? {
    let mainID = CGMainDisplayID()
    guard mainID != 0 else { return nil }
    let mainBounds = CGDisplayBounds(mainID)
    guard mainBounds.width > 0, mainBounds.height > 0 else { return nil }

    let quartzPoint = CGPoint(
      x: appKitPoint.x,
      y: mainBounds.height - appKitPoint.y
    )
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard
      let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]]
    else {
      return nil
    }

    let skipPIDs: Set<pid_t> = skipSelfWindows ? [getpid()] : []
    let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
    let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
    var best: Candidate?
    var frontmostContainment: CGRect?

    for info in list {
      guard
        let boundsValue = info[kCGWindowBounds as String] as? [String: Any],
        let quartzBounds = CGRect(
          dictionaryRepresentation: boundsValue as CFDictionary
        )
      else {
        continue
      }
      guard quartzBounds.contains(quartzPoint) else { continue }
      guard
        let number = info[kCGWindowNumber as String] as? NSNumber
      else {
        continue
      }
      let windowID = number.uint32Value
      let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)
        .map { pid_t($0.int32Value) } ?? 0
      if skipPIDs.contains(ownerPID) { continue }

      let ownerName = info[kCGWindowOwnerName as String] as? String
      let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
      guard layer >= normalLevel, layer <= popupLevel else { continue }

      if let alpha = info[kCGWindowAlpha as String] as? NSNumber,
        alpha.doubleValue <= 0
      {
        continue
      }
      if let ownerName, systemProcessBlacklist.contains(ownerName) {
        continue
      }
      // Skip system full-screen overlays such as Mission Control and Spaces.
      if quartzBounds.width >= mainBounds.width - 1,
        quartzBounds.height >= mainBounds.height - 1
      {
        continue
      }

      let candidate = Candidate(
        windowID: windowID,
        quartzBounds: quartzBounds,
        ownerPID: ownerPID,
        ownerName: ownerName,
        layer: layer
      )

      if best == nil {
        best = candidate
        frontmostContainment = quartzBounds.insetBy(dx: -1, dy: -1)
        continue
      }

      // Promote a same-PID parent window that fully contains the frontmost
      // candidate (Chromium/Electron child windows).
      guard
        let currentBest = best,
        candidate.ownerPID == currentBest.ownerPID,
        let containment = frontmostContainment,
        candidate.quartzBounds.contains(containment)
      else {
        continue
      }
      if candidate.area > currentBest.area {
        best = candidate
      }
    }

    guard let best else { return nil }
    let appKitBounds = CaptureGeometry.appKitRect(
      fromQuartzRect: best.quartzBounds,
      mainDisplayHeight: mainBounds.height
    )
    return WindowHitTestResult(
      windowID: best.windowID,
      frameInAppKitPoints: appKitBounds,
      ownerPID: best.ownerPID,
      ownerName: best.ownerName,
      layer: best.layer
    )
  }
}
