//
//  ClickabilityClassifier.swift
//  Tactile
//

import CoreGraphics
import Foundation

/// Maps accessibility roles to feedback categories. Pure logic with no AX
/// dependency so it can be exercised without a live accessibility tree.
///
/// Role strings are literals rather than the HIServices constants because
/// several web-content roles (like AXLink) have no exported constant.
enum ClickabilityClassifier {
    /// Plausible bounds for an individual control. Generous enough for wide
    /// menu items, banner links, and big tiles, but rejects the window-sized
    /// "pressable" containers Electron apps report. Shared by the feedback
    /// controller (fire decisions) and the resolver (redirect decisions).
    static func isControlSized(_ frame: CGRect) -> Bool {
        frame.width <= 900 && frame.height <= 350 && frame.width * frame.height <= 160_000
    }

    static func classify(role: String, subrole: String?, actions: [String]) -> FeedbackCategory? {
        // Subroles are more specific than roles, so they win. Native tabs,
        // for example, are AXRadioButton with subrole AXTabButton.
        switch subrole {
        case "AXTabButton":
            return .tab
        case "AXToggle", "AXSwitch":
            return .toggle
        case "AXSearchField", "AXSecureTextField":
            return .textField
        case "AXOutlineRow":
            // Source-list / sidebar rows (Finder, Mail, System Settings, and
            // Tactile's own settings sidebar). They're selectable navigation
            // targets but expose only AXShowDefaultUI/AXShowAlternateUI — no
            // AXPress — so nothing else here would catch them. The hit-test
            // usually lands on the inert AXStaticText inside; the resolver's
            // ancestor recovery walks up to this row.
            return .button
        default:
            break
        }

        switch role {
        case "AXButton", "AXDockItem":
            return .button
        case "AXLink":
            return .link
        case "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle":
            return .toggle
        case "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXPopUpButton", "AXComboBox":
            return .menuItem
        case "AXTab":
            return .tab
        case "AXSlider", "AXIncrementor", "AXStepper":
            return .slider
        case "AXTextField", "AXTextArea":
            return .textField
        default:
            // Custom controls — common in web and Electron apps — often use
            // generic roles but advertise a press action. Finder and other
            // file browsers don't: files, folders, sidebar shortcuts, and
            // desktop icons expose AXOpen (activate) instead of AXPress, so
            // treat that as clickable too. AXShowMenu is deliberately excluded
            // — it sits on plenty of inert containers and would over-fire.
            let clickActions: Set<String> = ["AXPress", "AXOpen"]
            return actions.contains(where: clickActions.contains) ? .genericPressable : nil
        }
    }
}
