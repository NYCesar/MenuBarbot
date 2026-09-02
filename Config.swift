// Config.swift — build-time configuration for MenuBarBot.
//
// The values below are DEFAULTS. They exist so the source in this repo is
// real, compilable Swift that your editor, `swiftc`, and any linter can
// understand:
//
//     swiftc -framework Cocoa -framework WebKit \
//         MenuBarBot.swift Config.swift -o MenuBarBot
//
// build.sh does NOT read this file. It generates its own Config.swift into
// build/ from the values in config.sh and compiles that instead, so editing
// this file has no effect on a packaged build. Edit config.sh.

import CoreGraphics

enum Config {
    /// The URL the popover loads.
    static let botURL = "https://example.com/"

    /// Name shown in the toolbar, tooltip, About dialog and User-Agent token.
    static let appName = "MenuBarBot"

    /// Version string shown in the About dialog and User-Agent token.
    static let appVersion = "0.0-dev"

    /// Copyright line shown in the About dialog.
    static let appCopyright = ""

    /// Popover size in points.
    static let popoverWidth: CGFloat = 420
    static let popoverHeight: CGFloat = 640

    /// When false, the web view uses an in-memory data store: nothing survives
    /// a relaunch. Set true (via PERSISTENT_SESSION in config.sh) if your bot
    /// sits behind SSO and you don't want users signing in every launch.
    /// "New Conversation" clears the store either way.
    static let persistentSession = false
}
