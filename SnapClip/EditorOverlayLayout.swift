import CoreGraphics
import Foundation

/// Pure placement rules for the in-place editor. The coordinate space is the
/// display-local, bottom-left AppKit point space used by overlay panels.
enum EditorOverlayLayout {
  static let margin: CGFloat = 12
  static let statusSpacing: CGFloat = 8

  static func toolbarFrame(
    relativeTo selection: CGRect,
    screenBounds: CGRect,
    toolbarSize: CGSize
  ) -> CGRect {
    guard !selection.isEmpty, !screenBounds.isEmpty else { return .zero }

    let width = min(max(toolbarSize.width, 1), screenBounds.width - margin * 2)
    let height = max(toolbarSize.height, 1)
    let centerX = max(
      screenBounds.minX + margin,
      min(
        screenBounds.maxX - margin - width,
        selection.midX - width / 2
      )
    )

    let belowY = selection.minY - margin - height
    if belowY >= screenBounds.minY + margin {
      return CGRect(x: centerX, y: belowY, width: width, height: height)
    }

    let aboveY = selection.maxY + margin
    if aboveY + height <= screenBounds.maxY - margin {
      return CGRect(x: centerX, y: aboveY, width: width, height: height)
    }

    // Very tall/full-screen selection: dock at the edge with the most room.
    let bottomRoom = screenBounds.minY + margin
    let topEdgeY = screenBounds.maxY - margin - height
    if selection.midY >= screenBounds.midY {
      return CGRect(x: centerX, y: bottomRoom, width: width, height: height)
    }
    return CGRect(x: centerX, y: topEdgeY, width: width, height: height)
  }

  static func statusFrame(
    relativeTo toolbar: CGRect,
    screenBounds: CGRect,
    statusSize: CGSize
  ) -> CGRect {
    guard !toolbar.isEmpty, !screenBounds.isEmpty else { return .zero }
    let width = min(max(statusSize.width, 1), screenBounds.width - margin * 2)
    let height = max(statusSize.height, 1)
    let centerX = max(
      screenBounds.minX + margin,
      min(screenBounds.maxX - margin - width, toolbar.midX - width / 2)
    )

    let y: CGFloat
    if toolbar.minY > screenBounds.midY {
      y = min(toolbar.maxY + statusSpacing, screenBounds.maxY - margin - height)
    } else {
      y = max(toolbar.minY - statusSpacing - height, screenBounds.minY + margin)
    }
    return CGRect(x: centerX, y: y, width: width, height: height)
  }
}
