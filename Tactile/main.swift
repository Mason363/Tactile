//
//  main.swift
//  Tactile
//
//  The one entry point. When Chrome launches this binary as a native-messaging
//  host, it passes the calling extension's origin as an argument; in that case
//  we run the dumb stdio<->socket relay and never touch AppKit. Otherwise we
//  start the normal menu-bar app.
//

import Foundation
import SwiftUI

if NativeMessagingHost.isHostLaunch(CommandLine.arguments) {
    NativeMessagingHost.run()
} else {
    TactileApp.main()
}
