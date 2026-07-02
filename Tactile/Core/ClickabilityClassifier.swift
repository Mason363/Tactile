//
//  ClickabilityClassifier.swift
//  Tactile
//

import Foundation

/// Maps accessibility roles to feedback categories. Pure logic with no AX
/// dependency so it can be exercised without a live accessibility tree.
///
/// Role strings are literals rather than the HIServices constants because
/// several web-content roles (like AXLink) have no exported constant.
enum ClickabilityClassifier {
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
            // generic roles but advertise a press action.
            return actions.contains("AXPress") ? .genericPressable : nil
        }
    }
}
