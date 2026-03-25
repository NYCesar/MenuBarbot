// MenuBarBot — macOS Menu Bar Chatbot App
// A lightweight macOS menu bar app that opens a popover with any web-hosted chatbot.
//
// Build with: ./build.sh
// Configure:  Edit config.sh before building.
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

// MARK: - Configuration
// These placeholder values are replaced at build time by build.sh using
// the values in config.sh. Do not edit them here.

let botURL           = "__BOT_URL__"
let popoverWidth:  CGFloat = __POPOVER_WIDTH__
let popoverHeight: CGFloat = __POPOVER_HEIGHT__
let appName          = "__APP_DISPLAY_NAME__"
let appVersion       = "__APP_VERSION__"
let appCopyright     = "__APP_COPYRIGHT__"

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
            } else if let sfImage = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right.fill", accessibilityDescription: appName) {
                sfImage.isTemplate = true
                button.image = sfImage
            } else {
                button.title = "Bot"
            }
            button.toolTip = appName

            // Handle both left-click (popover) and right-click (context menu)
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create the popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
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

        menu.addItem(NSMenuItem(title: "New Conversation", action: #selector(newConversation), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Reload", action: #selector(reloadBot), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About \(appName)", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        button.performClick(nil)
        // Clear the menu after it closes so left-click still triggers the popover
        statusItem.menu = nil
    }

    @objc func newConversation() {
        if let vc = popover.contentViewController as? BotViewController {
            vc.newConversation()
        }
    }

    @objc func reloadBot() {
        if let vc = popover.contentViewController as? BotViewController {
            vc.reloadPage()
        }
    }

    @objc func openInBrowser() {
        if let url = URL(string: botURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = "Version \(appVersion)\n\n\(appCopyright)\n\nBuilt with AppKit & WebKit."
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
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Bot View Controller

class BotViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    var webView: WKWebView!
    var loadingIndicator: NSProgressIndicator!
    var toolbar: NSView!
    var titleLabel: NSTextField!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))
        container.wantsLayer = true

        // --- Top toolbar ---
        let toolbarHeight: CGFloat = 36
        toolbar = NSView(frame: NSRect(x: 0, y: popoverHeight - toolbarHeight, width: popoverWidth, height: toolbarHeight))
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // App title
        titleLabel = NSTextField(labelWithString: appName)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.frame = NSRect(x: 12, y: 8, width: 200, height: 20)
        toolbar.addSubview(titleLabel)

        // New conversation button
        let newChatButton = NSButton(frame: NSRect(x: popoverWidth - 68, y: 4, width: 28, height: 28))
        newChatButton.bezelStyle = .inline
        newChatButton.isBordered = false
        newChatButton.image = NSImage(systemSymbolName: "plus.message.fill", accessibilityDescription: "New Conversation")
        newChatButton.target = self
        newChatButton.action = #selector(newConversationClicked)
        newChatButton.toolTip = "New Conversation"
        toolbar.addSubview(newChatButton)

        // Reload button
        let reloadButton = NSButton(frame: NSRect(x: popoverWidth - 36, y: 4, width: 28, height: 28))
        reloadButton.bezelStyle = .inline
        reloadButton.isBordered = false
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage)
        reloadButton.toolTip = "Reload"
        toolbar.addSubview(reloadButton)

        // Separator line
        let separator = NSBox(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: 1))
        separator.boxType = .separator
        toolbar.addSubview(separator)

        container.addSubview(toolbar)

        // --- WebView ---
        let webConfig = WKWebViewConfiguration()
        webConfig.defaultWebpagePreferences.allowsContentJavaScript = true

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        webConfig.defaultWebpagePreferences = prefs

        // Non-persistent store so new conversation can fully reset
        webConfig.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight - toolbarHeight), configuration: webConfig)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false

        webView.customUserAgent = "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 \(appName.replacingOccurrences(of: " ", with: ""))/\(appVersion)"

        container.addSubview(webView)

        // --- Loading spinner ---
        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.frame = NSRect(x: (popoverWidth - 32) / 2, y: (popoverHeight - toolbarHeight - 32) / 2, width: 32, height: 32)
        loadingIndicator.isHidden = true
        container.addSubview(loadingIndicator)

        self.view = container

        loadBot()
    }

    func loadBot() {
        guard let url = URL(string: botURL) else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
        webView.load(request)
    }

    @objc func reloadPage() {
        webView.reload()
    }

    @objc func newConversationClicked() {
        newConversation()
    }

    func newConversation() {
        // Clear all website data (cookies, local storage, session) to reset bot state
        let dataStore = webView.configuration.websiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(ofTypes: dataTypes, for: records) {
                DispatchQueue.main.async {
                    self.loadBot()
                }
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true

        let css = """
            document.body.style.margin = '0';
            document.body.style.padding = '0';
            document.body.style.overflow = 'hidden';
        """
        webView.evaluateJavaScript(css, completionHandler: nil)
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
            let botHost = URL(string: botURL)?.host ?? ""
            if url.host == botHost || url.scheme == "about" {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        } else {
            decisionHandler(.allow)
        }
    }

    // Handle target="_blank" and window.open()
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    // MARK: - Error display

    func showError(_ message: String) {
        let bg = isDarkMode() ? "#1e1e1e" : "#f5f5f5"
        let fg = isDarkMode() ? "#e0e0e0" : "#333"
        let errorHTML = """
        <html>
        <body style="font-family: -apple-system, sans-serif; display: flex; align-items: center;
                      justify-content: center; height: 100vh; margin: 0; background: \(bg); color: \(fg);">
            <div style="text-align: center; padding: 20px;">
                <div style="font-size: 48px; margin-bottom: 16px;">⚠️</div>
                <h3 style="margin: 0 0 8px 0;">Can't reach the bot</h3>
                <p style="font-size: 13px; opacity: 0.7; margin: 0 0 16px 0;">\(message)</p>
                <p style="font-size: 12px; opacity: 0.5;">Click the reload button to try again</p>
            </div>
        </body>
        </html>
        """
        webView.loadHTMLString(errorHTML, baseURL: nil)
    }

    func isDarkMode() -> Bool {
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
