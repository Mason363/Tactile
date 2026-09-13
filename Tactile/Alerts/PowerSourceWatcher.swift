//
//  PowerSourceWatcher.swift
//  Tactile
//

import Foundation
import IOKit.ps

/// Notices the charger being connected: the haptic stand-in for the
/// charging chime. IOKit posts power-source changes to the run loop, so
/// this costs nothing between them.
@MainActor
final class PowerSourceWatcher {
    var onChargerConnected: (() -> Void)?

    private var source: CFRunLoopSource?
    private var wasOnCharger = true

    var isRunning: Bool { source != nil }

    /// Desktops have no battery and nothing to connect.
    static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    private static var isOnCharger: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    func start() {
        guard source == nil else { return }
        wasOnCharger = Self.isOnCharger
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let watcher = Unmanaged<PowerSourceWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.powerChanged() }
        }
        guard let created = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        source = nil
    }

    private func powerChanged() {
        let onCharger = Self.isOnCharger
        defer { wasOnCharger = onCharger }
        if onCharger, !wasOnCharger { onChargerConnected?() }
    }
}
