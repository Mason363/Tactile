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

    /// Categories whose label names an ACTION the control performs. Links
    /// and tabs are navigation - their text is *content*, so a commit
    /// message or headline reading "remove old docs" must not shake as a
    /// destructive control.
    private static let dangerCategories: Set<FeedbackCategory> = [
        .button, .menuItem, .toggle, .genericPressable,
    ]

    static func isDanger(title: String?, subrole: String?, category: FeedbackCategory?) -> Bool {
        if subrole == "AXCloseButton" { return true }
        guard let category, dangerCategories.contains(category) else { return false }
        // Real action labels are short ("Delete repository"). Long text means
        // the "label" is actually content leaking out of a wrapper element.
        guard let title, !title.isEmpty, title.count <= 40 else { return false }
        return title.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { dangerWords.contains(String($0)) }
    }
}
