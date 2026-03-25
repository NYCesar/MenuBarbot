# MenuBarBot

A lightweight macOS menu bar app that wraps any web-hosted chatbot in a native popover. Click the icon in your menu bar, chat with your bot, click away to dismiss. That's it.

Works with **Zapier Chatbots**, **Botpress**, **Tidio**, **Intercom**, **Drift**, or literally any chatbot that lives at a URL.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

## What it does

- Lives in the macOS menu bar (no Dock icon)
- Opens your chatbot in a native popover on click
- Right-click menu with reload, new conversation, open in browser, quit
- "New Conversation" clears all session data for a fresh start
- External links open in your default browser
- Dark mode support
- Universal binary (Apple Silicon + Intel)
- Auto-starts at login via LaunchAgent

## Quick Start (Local)

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/MenuBarBot.git
cd MenuBarBot
cp config.sh.example config.sh   # or just edit config.sh directly
```

Open `config.sh` and set your chatbot URL:

```bash
BOT_URL="https://your-chatbot.zapier.app/"
APP_DISPLAY_NAME="My IT Bot"
APP_NAME="MenuBarBot"
APP_IDENTIFIER="com.yourorg.menubarbot"
APP_VERSION="1.0"
```

### 2. Build

```bash
chmod +x build.sh
./build.sh
```

This compiles a universal binary, creates a `.app` bundle, and packages everything into a `.pkg` installer.

### 3. Run locally (without installing)

```bash
open build/payload/Applications/MenuBarBot.app
```

Or install the package:

```bash
sudo installer -pkg build/MenuBarBot-1.0.pkg -target /
```

## Configuration

All configuration lives in `config.sh`. Edit once, and the build script, uninstall script, and all packaging pick it up automatically.

| Variable | What it does | Example |
|---|---|---|
| `BOT_URL` | The URL your chatbot is hosted at | `https://mybot.zapier.app/` |
| `APP_DISPLAY_NAME` | Name shown in the menu bar tooltip and About dialog | `My IT Bot` |
| `APP_NAME` | Internal name (no spaces) — used for the binary and .app bundle | `MyITBot` |
| `APP_IDENTIFIER` | macOS bundle identifier | `com.yourcompany.itbot` |
| `APP_VERSION` | Version string | `1.0` |
| `APP_COPYRIGHT` | Copyright line in the About dialog | `© 2025 Acme Corp` |
| `POPOVER_WIDTH` | Popover width in pixels (default: 420) | `420` |
| `POPOVER_HEIGHT` | Popover height in pixels (default: 640) | `640` |
| `MIN_MACOS_VERSION` | Minimum macOS version (default: 14 = Sonoma) | `14` |

## Custom App Icon

To use your own icon instead of the default SF Symbol:

1. Create a folder called `AppIcon.iconset/` in the project root
2. Add PNG files at these sizes:

```
icon_16x16.png        (16x16)
icon_16x16@2x.png     (32x32)
icon_32x32.png        (32x32)
icon_32x32@2x.png     (64x64)
icon_128x128.png      (128x128)
icon_128x128@2x.png   (256x256)
icon_256x256.png      (256x256)
icon_256x256@2x.png   (512x512)
icon_512x512.png      (512x512)
icon_512x512@2x.png   (1024x1024)
```

The `icon_32x32.png` is also used as the menu bar icon. If you want a different menu bar icon, you can replace `menubar_icon.png` in the built `.app` bundle.

The build script will automatically detect `AppIcon.iconset/` and compile it into an `.icns` file. If the folder isn't there, the app falls back to an SF Symbol.

## Deploying with Jamf Pro

The build script outputs a `.pkg` file that's ready to upload to Jamf.

### Upload the package

1. Go to **Settings → Computer Management → Packages → New**
2. Upload `build/MenuBarBot-1.0.pkg` (or whatever your `APP_NAME-APP_VERSION` is)

### Create a deployment policy

1. Go to **Computers → Policies → New**
2. Set it up:
   - **Display Name:** Install MenuBarBot (or your `APP_DISPLAY_NAME`)
   - **Trigger:** Recurring Check-in (and/or Enrollment Complete)
   - **Frequency:** Once per computer
   - **Packages tab:** Add your `.pkg` → Action: Install
   - **Maintenance tab:** Check "Update Inventory"
   - **Scope:** All Managed Clients, or a Smart Group targeting specific machines

### Extension Attribute (for version tracking)

The `jamf/ea_version.sh` script reports the installed version back to Jamf. This lets you build Smart Groups to target machines that need updates.

1. Go to **Settings → Computer Management → Extension Attributes → New**
2. Set **Data Type** to String, **Input Type** to Script
3. Paste the contents of `jamf/ea_version.sh`
4. **Important:** Update the `APP_PATH` variable in the script to match your `APP_NAME`

Example Smart Group criteria:
- `MenuBarBot Version` is not `1.0` → machines needing an update
- `MenuBarBot Version` is (blank) → machines without it installed

### Self Service (optional)

In your policy, go to the **Self Service** tab and enable "Make available in Self Service." Set a category, icon, and description so users can install it themselves.

### Uninstall policy

1. Go to **Computers → Policies → New**
2. Add `uninstall.sh` as a **Scripts** payload (not a package)
3. If you're running it through Jamf (where `config.sh` isn't available), pass the app name and bundle ID as script parameters:
   - Parameter 4: Your `APP_NAME` (e.g., `MyITBot`)
   - Parameter 5: Your `APP_IDENTIFIER` (e.g., `com.yourcompany.itbot`)

## Project Structure

```
MenuBarBot/
├── config.sh              # Your configuration (edit this)
├── MenuBarBot.swift        # Main app source
├── build.sh               # Build + package script
├── uninstall.sh           # Uninstall script (local or Jamf)
├── jamf/
│   └── ea_version.sh      # Jamf extension attribute script
├── AppIcon.iconset/        # (optional) Your custom icon PNGs
├── LICENSE
└── README.md
```

## How It Works

The app is a single-file Swift program that uses AppKit's `NSStatusItem` for the menu bar icon and `NSPopover` with a `WKWebView` to display your chatbot. No Xcode project, no SwiftUI, no storyboards — just one Swift file compiled with `swiftc`.

The build script reads your config, injects the values into the Swift source at compile time (via placeholder replacement), and produces a universal binary that runs on both Apple Silicon and Intel Macs.

The LaunchAgent (`/Library/LaunchAgents/`) ensures the app starts automatically when any user logs in. It's installed to `/Library/LaunchAgents/` (not `~/Library/LaunchAgents/`) so it works for all users on the machine.

## Compatibility

- **Minimum:** macOS 14 (Sonoma)
- **Tested:** macOS 15 (Sequoia), macOS 26 (Tahoe)
- **Architecture:** Universal (arm64 + x86_64)

The app uses `NSStatusItem`, `NSPopover`, and `WKWebView` — all stable, non-deprecated AppKit/WebKit APIs that have been around for over a decade. No private APIs, no undocumented behavior.

## Supported Chatbot Platforms

Anything with a URL works. Some platforms we've tested:

- [Zapier Chatbots](https://zapier.com/chatbots)
- [Botpress](https://botpress.com)
- [Tidio](https://tidio.com)
- [Intercom](https://intercom.com)
- [Drift](https://drift.com)
- [HubSpot Chatbot](https://hubspot.com)
- Any custom web app or internal tool

## License

MIT — do whatever you want with it.
