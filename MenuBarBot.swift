// MenuBarBot — macOS Menu Bar Chatbot App
// A lightweight macOS menu bar app that opens a popover with any web-hosted chatbot.
//
// Build with: ./build.sh
// Configure:  Edit config.sh before building.
//
// Configuration lives in Config.swift. build.sh generates that file from
// config.sh at build time; the copy checked into the repo holds development
// defaults so this source stays compilable on its own.
//
// Minimum: macOS 14 (Sonoma)
// Tested:  macOS 15 (Sequoia), macOS 26 (Tahoe)
//
// Forward compatibility notes:
//   - Uses NSStatusItem + NSPopover (stable AppKit APIs since macOS 10.7)
//   - Uses WKWebView (stable WebKit API, actively maintained by Apple)
//   - No deprecated APIs used; no private APIs or undocumented behavior
//   - SwiftUI menu bar APIs exist but NSStatusItem is still the recommended
//     approach for apps that need popover + webview + right-click menus

import Cocoa
import WebKit

// MARK: - Toolbar

/// Layer-backed view that re-resolves its background whenever the system
/// appearance changes. A CGColor is a static snapshot of a dynamic NSColor,
/// so assigning one only at setup would leave the toolbar stuck in whichever
/// mode was active when the view loaded.
final class ToolbarView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — this is a menu bar-only app
        NSApp.setActivationPolicy(.accessory)

        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            // Try to load the bundled app icon for the menu bar
            // Fall back to SF Symbol, then plain text
            if let iconPath = Bundle.main.path(forResource: "menubar_icon", ofType: "png"),
               let iconImage = NSImage(contentsOfFile: iconPath) {
                iconImage.isTemplate = false
                iconImage.size = NSSize(width: 18, height: 18)
                button.image = iconImage
            } else if let sfImage = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right.fill", accessibilityDescription: Config.appName) {
                sfImage.isTemplate = true
                button.image = sfImage
            } else {
                button.title = "Bot"
            }
            button.toolTip = Config.appName

            // Handle both left-click (popover) and right-click (context menu)
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create the popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: Config.popoverWidth, height: Config.popoverHeight)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = BotViewController()

        // Monitor clicks outside the popover to close it
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    @objc func statusBarButtonClicked(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu(from: button)
        } else {
            togglePopover(sender)
        }
    }

    func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        // Targets are set explicitly rather than relying on the responder
        // chain finding the app delegate.
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            return menuItem
        }

        menu.addItem(item("New Conversation", #selector(newConversation)))
        menu.addItem(item("Reload", #selector(reloadBot)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Open in Browser", #selector(openInBrowser)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("About \(Config.appName)", #selector(showAbout)))
        menu.addItem(item("Quit \(Config.appName)", #selector(quitApp)))

        statusItem.menu = menu
        // performClick runs menu tracking in a nested run loop, so this only
        // returns once the menu closes.
        button.performClick(nil)
        // Clear the menu so left-click still triggers the popover
        statusItem.menu = nil
    }

    private var botViewController: BotViewController? {
        popover.contentViewController as? BotViewController
    }

    @objc func newConversation() {
        botViewController?.newConversation()
    }

    @objc func reloadBot() {
        botViewController?.reloadPage()
    }

    @objc func openInBrowser() {
        // Config.botURL is trusted (it comes from config.sh at build time).
        if let url = URL(string: Config.botURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = Config.appName
        alert.informativeText = "Version \(Config.appVersion)\n\n\(Config.appCopyright)\n\nBuilt with AppKit & WebKit."
        alert.alertStyle = .informational

        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            alert.icon = icon
        }

        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
                // Focus the web view so users can type without clicking first.
                if let vc = botViewController {
                    window.makeFirstResponder(vc.webView)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Bot View Controller

class BotViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    var webView: WKWebView!
    var loadingIndicator: NSProgressIndicator!
    var toolbar: NSView!
    var titleLabel: NSTextField!

    /// True while the local error page is on screen. Used so the reload
    /// controls retry the bot instead of reloading the error page.
    private var isShowingError = false

    /// Destinations for in-flight downloads, so we can reveal them on finish.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    /// Schemes we're willing to hand to NSWorkspace. Everything else (file://,
    /// custom app schemes, and so on) is ignored, so page content can't ask us
    /// to launch arbitrary handlers.
    private static let allowedExternalSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    override func loadView() {
        let width = Config.popoverWidth
        let height = Config.popoverHeight

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true

        // --- Top toolbar ---
        let toolbarHeight: CGFloat = 36
        let buttonSize: CGFloat = 28
        let edgeInset: CGFloat = 8
        let buttonGap: CGFloat = 4
        let buttonAreaWidth = edgeInset + (buttonSize * 2) + buttonGap

        let toolbarView = ToolbarView(frame: NSRect(x: 0, y: height - toolbarHeight, width: width, height: toolbarHeight))
        toolbarView.wantsLayer = true
        toolbarView.autoresizingMask = [.width, .minYMargin]
        toolbar = toolbarView

        // App title
        titleLabel = NSTextField(labelWithString: Config.appName)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.frame = NSRect(x: 12, y: 8, width: max(0, width - 12 - buttonAreaWidth - 8), height: 20)
        titleLabel.autoresizingMask = [.width]
        toolbar.addSubview(titleLabel)

        // New conversation button
        let newChatButton = NSButton(frame: NSRect(x: width - buttonAreaWidth, y: 4, width: buttonSize, height: buttonSize))
        newChatButton.bezelStyle = .inline
        newChatButton.isBordered = false
        newChatButton.image = NSImage(systemSymbolName: "plus.message.fill", accessibilityDescription: "New Conversation")
        newChatButton.target = self
        newChatButton.action = #selector(newConversationClicked)
        newChatButton.toolTip = "New Conversation"
        newChatButton.autoresizingMask = [.minXMargin]
        toolbar.addSubview(newChatButton)

        // Reload button
        let reloadButton = NSButton(frame: NSRect(x: width - edgeInset - buttonSize, y: 4, width: buttonSize, height: buttonSize))
        reloadButton.bezelStyle = .inline
        reloadButton.isBordered = false
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage)
        reloadButton.toolTip = "Reload"
        reloadButton.autoresizingMask = [.minXMargin]
        toolbar.addSubview(reloadButton)

        // Separator line along the bottom edge of the toolbar
        let separator = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .maxYMargin]
        toolbar.addSubview(separator)

        container.addSubview(toolbar)

        // --- WebView ---
        let webConfig = WKWebViewConfiguration()

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        webConfig.defaultWebpagePreferences = prefs

        // A non-persistent store keeps nothing on disk between launches. That
        // is the private default, but it means an SSO-protected bot asks for a
        // sign-in every launch, so it's configurable.
        webConfig.websiteDataStore = Config.persistentSession
            ? WKWebsiteDataStore.default()
            : WKWebsiteDataStore.nonPersistent()

        // Append our token to WebKit's real User-Agent rather than replacing
        // it. A hand-rolled UA string trips browser sniffing on hosted chat
        // platforms and gets you an "unsupported browser" page.
        webConfig.applicationNameForUserAgent =
            "\(Config.appName.replacingOccurrences(of: " ", with: ""))/\(Config.appVersion)"

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height - toolbarHeight), configuration: webConfig)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.autoresizingMask = [.width, .height]

        container.addSubview(webView)

        // --- Loading spinner ---
        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.frame = NSRect(x: (width - 32) / 2, y: (height - toolbarHeight - 32) / 2, width: 32, height: 32)
        loadingIndicator.isHidden = true
        loadingIndicator.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        container.addSubview(loadingIndicator)

        self.view = container

        loadBot()
    }

    func loadBot() {
        isShowingError = false

        guard let url = URL(string: Config.botURL) else {
            showError("\(Config.botURL) is not a valid URL. Check BOT_URL in config.sh.")
            return
        }

        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
        webView.load(request)
    }

    @objc func reloadPage() {
        // reload() on the error page would just reload about:blank, so retry
        // the bot URL outright whenever the error page is what's showing.
        if isShowingError || webView.url == nil {
            loadBot()
        } else {
            webView.reload()
        }
    }

    @objc func newConversationClicked() {
        newConversation()
    }

    func newConversation() {
        // Clear all website data (cookies, local storage, session) to reset bot state
        let dataStore = webView.configuration.websiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        dataStore.fetchDataRecords(ofTypes: dataTypes) { [weak self] records in
            dataStore.removeData(ofTypes: dataTypes, for: records) {
                DispatchQueue.main.async {
                    self?.loadBot()
                }
            }
        }
    }

    /// Opens a URL in the user's default handler, but only for schemes we
    /// consider safe to hand off from web content.
    private func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              BotViewController.allowedExternalSchemes.contains(scheme) else {
            NSLog("Refusing to open URL with disallowed scheme: \(url.scheme ?? "none")")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true

        guard !isShowingError else { return }

        // Strip the page's default body margin so the chat fills the popover.
        // Deliberately does not touch overflow: some chat UIs scroll the body,
        // and hiding it puts older messages out of reach.
        let js = """
            document.body.style.margin = '0';
            document.body.style.padding = '0';
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
        showError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true
        showError(error.localizedDescription)
    }

    // External link handling — open anything outside the bot URL in the default browser
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            let botHost = URL(string: Config.botURL)?.host?.lowercased() ?? ""
            if url.host?.lowercased() == botHost || url.scheme == "about" {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated {
                openExternally(url)
                decisionHandler(.cancel)
            } else {
                // Redirects, form posts and subframes stay in the popover so
                // SSO flows through third-party identity providers still work.
                decisionHandler(.allow)
            }
        } else {
            decisionHandler(.allow)
        }
    }

    // Anything WebKit can't render itself becomes a download.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // Handle target="_blank" and window.open()
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            openExternally(url)
        }
        return nil
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let fileManager = FileManager.default
        let downloadsDir = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

        // The server picks suggestedFilename, so strip anything that could
        // escape the Downloads folder before using it as a path component.
        var name = suggestedFilename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "download" }

        var destination = downloadsDir.appendingPathComponent(name)
        let ext = destination.pathExtension
        let base = destination.deletingPathExtension().lastPathComponent
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            destination = downloadsDir.appendingPathComponent(candidate)
            counter += 1
        }

        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("Download failed: \(error.localizedDescription)")
    }

    // MARK: - Error display

    func showError(_ message: String) {
        let errorHTML = """
        <html>
        <head>
            <meta name="color-scheme" content="light dark">
            <style>
                :root { color-scheme: light dark; --bg: #f5f5f5; --fg: #333; }
                @media (prefers-color-scheme: dark) {
                    :root { --bg: #1e1e1e; --fg: #e0e0e0; }
                }
                body {
                    font-family: -apple-system, sans-serif;
                    display: flex; align-items: center; justify-content: center;
                    height: 100vh; margin: 0;
                    background: var(--bg); color: var(--fg);
                }
            </style>
        </head>
        <body>
            <div style="text-align: center; padding: 20px;">
                <div style="font-size: 48px; margin-bottom: 16px;">&#9888;&#65039;</div>
                <h3 style="margin: 0 0 8px 0;">Can't reach the bot</h3>
                <p style="font-size: 13px; opacity: 0.7; margin: 0 0 16px 0;">\(BotViewController.htmlEscaped(message))</p>
                <p style="font-size: 12px; opacity: 0.5;">Click the reload button to try again</p>
            </div>
        </body>
        </html>
        """
        webView.loadHTMLString(errorHTML, baseURL: nil)
        isShowingError = true
    }

    private static func htmlEscaped(_ string: String) -> String {
        var escaped = string.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        return escaped
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
