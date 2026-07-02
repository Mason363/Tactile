//
//  ActuatorHapticEngine.swift
//  Tactile
//

import AppKit

/// Enhanced haptics: drives the trackpad actuator directly through the
/// private MultitouchSupport framework (the approach HapticPad and HapticKey
/// use). Unlike the public API, actuation IDs map to physically distinct
/// strengths, so Light/Standard/Firm become real intensity levels.
///
/// Everything is resolved at runtime with dlopen/dlsym and probed once; if
/// the framework, symbols, or actuator are missing — or break in a macOS
/// update — `shared` is nil and callers fall back to the public engine.
/// Nothing is linked at build time.
@MainActor
final class ActuatorHapticEngine: FeedbackEngine {
    /// The built-in Force Touch trackpad's actuator device.
    private static let defaultDeviceID: UInt64 = 0x200000001

    private typealias CreateFunc = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenCloseFunc = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuateFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32

    static let shared: ActuatorHapticEngine? = ActuatorHapticEngine()

    private let actuator: UnsafeMutableRawPointer
    private let actuate: ActuateFunc
    private let closeActuator: OpenCloseFunc

    private init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }

        guard let createSym = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let openSym = dlsym(handle, "MTActuatorOpen"),
              let closeSym = dlsym(handle, "MTActuatorClose"),
              let actuateSym = dlsym(handle, "MTActuatorActuate")
        else { return nil }

        let create = unsafeBitCast(createSym, to: CreateFunc.self)
        let open = unsafeBitCast(openSym, to: OpenCloseFunc.self)
        self.closeActuator = unsafeBitCast(closeSym, to: OpenCloseFunc.self)
        self.actuate = unsafeBitCast(actuateSym, to: ActuateFunc.self)

        guard let actuator = create(Self.defaultDeviceID) else { return nil }
        guard open(actuator) == 0 else {
            Unmanaged<AnyObject>.fromOpaque(actuator).release()
            return nil
        }
        self.actuator = actuator
    }

    func tick(_ pattern: FeedbackPattern) {
        _ = actuate(actuator, pattern.actuationID, 0, 0, 0)
    }

    deinit {
        _ = closeActuator(actuator)
        Unmanaged<AnyObject>.fromOpaque(actuator).release()
    }
}

private extension FeedbackPattern {
    /// Known actuation IDs by strength: 3 is weak, 4 is medium, 6 is strong.
    var actuationID: Int32 {
        switch self {
        case .alignment: return 3
        case .generic: return 4
        case .levelChange: return 6
        }
    }
}
