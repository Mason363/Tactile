//
//  FeedbackEngine.swift
//  Tactile
//

import Foundation

/// A destination for feedback ticks. Engines must be cheap to call and safe
/// to call from the main thread at up to the configured rate limit.
@MainActor
protocol FeedbackEngine {
    func tick(_ pattern: FeedbackPattern)
}
