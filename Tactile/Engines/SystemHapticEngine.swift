//
//  SystemHapticEngine.swift
//  Tactile
//

import AppKit

/// Drives the Force Touch trackpad through the public haptics API.
/// Feedback is physically felt only while a finger rests on the trackpad,
/// which is naturally the case while it is being used to move the cursor.
@MainActor
final class SystemHapticEngine: FeedbackEngine {
    private let performer = NSHapticFeedbackManager.defaultPerformer

    func tick(_ pattern: FeedbackPattern) {
        performer.perform(pattern.systemPattern, performanceTime: .now)
    }
}

private extension FeedbackPattern {
    var systemPattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .generic: return .generic
        case .alignment: return .alignment
        case .levelChange: return .levelChange
        }
    }
}
