import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Backend contract for frozen screen and on-demand window capture. Only
/// immutable values cross this boundary.
protocol DisplaySnapshotting: Sendable {
  func captureFrozenScreens() async throws -> [FrozenDisplaySnapshot]
  func captureWindow(descriptor: CaptureWindowDescriptor) async throws -> CaptureImage
}

/// ScreenCaptureKit implementation. All SCK objects stay inside the actor.
actor SCKDisplaySnapshotter: DisplaySnapshotting {
  func captureFrozenScreens() async throws -> [FrozenDisplaySnapshot] {
    let topology = try await MainActor.run {
      try Self.collectTopology()
    }
    let content = try await Self.shareableContent()
    let displays = Dictionary(
      uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) }
    )

    var snapshots: [FrozenDisplaySnapshot] = []
    snapshots.reserveCapacity(topology.screens.count)
    for screen in topology.screens {
      guard let display = displays[screen.displayID] else {
        throw CaptureGeometryError.displayUnavailable(screen.displayID)
      }
      let filter = SCContentFilter(display: display, excludingWindows: [])
      try Self.validate(filter, against: screen)
      let pixels = try CaptureGeometry.validatedPixelSize(
        sizeInPoints: screen.frame.size,
        pointScale: CGFloat(filter.pointPixelScale)
      )
      let configuration = Self.displayConfiguration(
        width: pixels.width,
        height: pixels.height
      )
      let image = try await Self.captureImage(
        filter: filter,
        configuration: configuration
      )
      guard image.width == pixels.width, image.height == pixels.height else {
        throw CaptureGeometryError.invalidPixelDimensions
      }
      let validated = try CaptureImage(
        cgImage: image,
        pointScale: CGFloat(filter.pointPixelScale)
      )
      snapshots.append(
        FrozenDisplaySnapshot(
          displayID: screen.displayID,
          frameInAppKitPoints: screen.frame,
          image: validated
        )
      )
    }
    return snapshots
  }

  func captureWindow(
    descriptor: CaptureWindowDescriptor
  ) async throws -> CaptureImage {
    let content = try await Self.shareableContent()
    guard
      let window = content.windows.first(where: {
        $0.windowID == descriptor.windowID
          && $0.owningApplication?.processID == descriptor.ownerPID
      })
    else {
      throw CaptureGeometryError.windowUnavailable(descriptor.windowID)
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let pixels = try CaptureGeometry.validatedPixelSize(
      sizeInPoints: filter.contentRect.size,
      pointScale: CGFloat(filter.pointPixelScale)
    )
    let configuration = SCStreamConfiguration()
    configuration.width = pixels.width
    configuration.height = pixels.height
    configuration.captureResolution = .best
    configuration.showsCursor = false
    configuration.scalesToFit = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.ignoreShadowsSingleWindow = true
    configuration.shouldBeOpaque = false

    let image = try await Self.captureImage(
      filter: filter,
      configuration: configuration
    )
    guard image.width == pixels.width, image.height == pixels.height else {
      throw CaptureGeometryError.invalidPixelDimensions
    }
    return try CaptureImage(
      cgImage: image,
      pointScale: CGFloat(filter.pointPixelScale)
    )
  }

  // MARK: Internals

  private struct Topology: Sendable {
    struct Screen: Sendable {
      let displayID: CGDirectDisplayID
      let frame: CGRect
      let backingScaleFactor: CGFloat
    }

    let screens: [Screen]
    let mainDisplayHeight: CGFloat
  }

  @MainActor
  private static func collectTopology() throws -> Topology {
    let mainID = CGMainDisplayID()
    guard mainID != 0 else { throw CaptureGeometryError.noDisplays }
    let mainHeight = CGDisplayBounds(mainID).height
    let screens: [Topology.Screen] = NSScreen.screens.compactMap { screen in
      guard
        let rawID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")],
        let displayID = rawID as? CGDirectDisplayID
      else {
        return nil
      }
      return Topology.Screen(
        displayID: displayID,
        frame: screen.frame,
        backingScaleFactor: screen.backingScaleFactor
      )
    }
    guard !screens.isEmpty else { throw CaptureGeometryError.noDisplays }

    var seen: Set<CGDirectDisplayID> = []
    for screen in screens {
      guard seen.insert(screen.displayID).inserted,
        screen.frame.width.isFinite,
        screen.frame.height.isFinite,
        screen.frame.width > 0,
        screen.frame.height > 0,
        screen.backingScaleFactor.isFinite,
        screen.backingScaleFactor > 0
      else {
        throw CaptureGeometryError.invalidGeometry
      }
    }
    return Topology(
      screens: screens.sorted { $0.displayID < $1.displayID },
      mainDisplayHeight: mainHeight
    )
  }

  private static func shareableContent() async throws -> SCShareableContent {
    do {
      return try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let value = error as NSError
      if value.domain == SCStreamErrorDomain,
        value.code == SCStreamError.Code.userDeclined.rawValue
      {
        throw CaptureGeometryError.permissionDenied
      }
      throw CaptureGeometryError.contentEnumerationFailed
    }
  }

  private static func validate(
    _ filter: SCContentFilter,
    against screen: Topology.Screen
  ) throws {
    let scale = CGFloat(filter.pointPixelScale)
    guard scale.isFinite, scale > 0 else {
      throw CaptureGeometryError.invalidGeometry
    }
    guard abs(scale - screen.backingScaleFactor) < 0.01 else {
      throw CaptureGeometryError.topologyChanged
    }
    guard
      abs(filter.contentRect.width - screen.frame.width) < 0.5,
      abs(filter.contentRect.height - screen.frame.height) < 0.5
    else {
      throw CaptureGeometryError.topologyChanged
    }
  }

  private static func displayConfiguration(
    width: Int,
    height: Int
  ) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.captureResolution = .best
    configuration.showsCursor = false
    configuration.scalesToFit = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.shouldBeOpaque = true
    return configuration
  }

  private static func captureImage(
    filter: SCContentFilter,
    configuration: SCStreamConfiguration
  ) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
      SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      ) { image, error in
        if let image {
          continuation.resume(returning: image)
        } else if let error {
          let nsError = error as NSError
          if nsError.domain == SCStreamErrorDomain,
            nsError.code == SCStreamError.Code.userDeclined.rawValue
          {
            continuation.resume(throwing: CaptureGeometryError.permissionDenied)
          } else {
            continuation.resume(
              throwing: CaptureGeometryError.platformFailure(nsError.code)
            )
          }
        } else {
          continuation.resume(throwing: CaptureGeometryError.platformFailure(0))
        }
      }
    }
  }
}
