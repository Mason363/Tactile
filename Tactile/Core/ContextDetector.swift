//
//  ContextDetector.swift
//  Tactile
//

import Foundation

/// Recognizes elements that deserve a warning feel: window close buttons and
/// controls whose label reads as destructive.
///
/// Keyword matching is word-boundary based ("Delete Account" matches,
/// "Deletion Log" doesn't as a whole word ... "deletion" is not "delete")
/// and currently English-only.
enum ContextDetector {
    private static let dangerWords: Set<String> = [
        "delete", "remove", "trash", "erase", "discard", "uninstall",
        "clear", "reset", "quit", "close", "empty", "eject", "disconnect",
        "terminate", "destroy", "wipe", "forget", "revoke", "unsubscribe",
    ]

    static func isDanger(title: String?, subrole: String?) -> Bool {
        if subrole == "AXCloseButton" { return true }
        guard let title, !title.isEmpty else { return false }
        return title.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { dangerWords.contains(String($0)) }
    }
}
