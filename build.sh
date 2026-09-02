#!/bin/bash

# =============================================================================
# Build MenuBarBot — Jamf-Deployable Installer Package
# =============================================================================
#
# This script:
#   1. Reads configuration from config.sh
#   2. Generates build/Config.swift from those values
#   3. Compiles a universal binary (arm64 + x86_64)
#   4. Bundles the app icon (if provided)
#   5. Creates a proper .app bundle destined for /Applications
#   6. Code signs the app (if SIGNING_IDENTITY is set)
#   7. Creates a LaunchAgent so it auto-starts at login for all users
#   8. Builds a flat .pkg installer ready to upload to Jamf Pro
#      (signed with INSTALLER_IDENTITY if set)
#
# The Swift sources are never modified. Configuration is emitted as a
# separate, properly escaped Config.swift into build/, so MenuBarBot.swift
# stays valid Swift you can open in an editor or compile directly.
#
# Requirements:
#   - macOS with Xcode Command Line Tools (swiftc, pkgbuild)
#   - config.sh in the same directory (edit this first!)
#
# Optional:
#   - AppIcon.iconset/ folder with icon PNGs (see README for format)
#   - SIGNING_IDENTITY / INSTALLER_IDENTITY in config.sh for signed output
#
# Output:
#   build/<APP_NAME>-<APP_VERSION>.pkg
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
SOURCE_MAIN="${SCRIPT_DIR}/MenuBarBot.swift"

# --- Escaping helpers --------------------------------------------------------
# Config values are user-supplied text that ends up inside Swift string
# literals and XML. Escape them properly instead of splicing raw.
# sed is used rather than bash ${var//x/y} because bash 5.2 treats '&' in a
# replacement as "the matched text" and macOS ships bash 3.2, which does not.

swift_escape() {
    printf '%s' "$1" | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

xml_escape() {
    printf '%s' "$1" | LC_ALL=C sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

# --- Load config -------------------------------------------------------------

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.sh not found in ${SCRIPT_DIR}"
    echo "Copy config.sh.example to config.sh and edit it."
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Validate required config values
for var in BOT_URL APP_DISPLAY_NAME APP_NAME APP_IDENTIFIER APP_VERSION; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: ${var} is not set in config.sh"
        exit 1
    fi
    # A newline would break the generated Swift literal and the plist.
    if [[ "${!var}" == *$'\n'* ]]; then
        echo "ERROR: ${var} in config.sh must not contain a newline"
        exit 1
    fi
done

if [[ "${BOT_URL}" == *"example.com"* ]]; then
    echo "ERROR: You need to set BOT_URL in config.sh to your actual chatbot URL."
    exit 1
fi

if [[ "${APP_NAME}" == *" "* ]]; then
    echo "ERROR: APP_NAME must not contain spaces (it is the binary and process name)."
    exit 1
fi

# --- Defaults for optional values -------------------------------------------

POPOVER_WIDTH="${POPOVER_WIDTH:-420}"
POPOVER_HEIGHT="${POPOVER_HEIGHT:-640}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14}"
APP_COPYRIGHT="${APP_COPYRIGHT:-}"
PERSISTENT_SESSION="${PERSISTENT_SESSION:-false}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"

for dim in POPOVER_WIDTH POPOVER_HEIGHT; do
    if [[ ! "${!dim}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: ${dim} must be a whole number of pixels (got '${!dim}')"
        exit 1
    fi
done

case "$(printf '%s' "${PERSISTENT_SESSION}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1)   SWIFT_PERSISTENT="true" ;;
    false|no|0|"") SWIFT_PERSISTENT="false" ;;
    *)
        echo "ERROR: PERSISTENT_SESSION must be true or false (got '${PERSISTENT_SESSION}')"
        exit 1
        ;;
esac

INSTALL_PATH="/Applications"
BUILD_DIR="${SCRIPT_DIR}/build"
PAYLOAD_DIR="${BUILD_DIR}/payload"
SCRIPTS_DIR="${BUILD_DIR}/scripts"
APP_BUNDLE="${PAYLOAD_DIR}${INSTALL_PATH}/${APP_NAME}.app"
GENERATED_CONFIG="${BUILD_DIR}/Config.swift"

LAUNCH_AGENT_LABEL="${APP_IDENTIFIER}.launcher"
LAUNCH_AGENT_DIR="${PAYLOAD_DIR}/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_DIR}/${LAUNCH_AGENT_LABEL}.plist"

PKG_OUTPUT="${BUILD_DIR}/${APP_NAME}-${APP_VERSION}.pkg"

echo "============================================"
echo "  Building ${APP_DISPLAY_NAME} v${APP_VERSION}"
echo "  Bundle ID: ${APP_IDENTIFIER}"
echo "  Bot URL:   ${BOT_URL}"
echo "============================================"
echo ""

# --- Validate ----------------------------------------------------------------

if [[ ! -f "${SOURCE_MAIN}" ]]; then
    echo "ERROR: ${SOURCE_MAIN} not found"
    exit 1
fi

if ! command -v swiftc &>/dev/null; then
    echo "ERROR: swiftc not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

# --- Clean -------------------------------------------------------------------

echo "[1/8] Cleaning previous build..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${PAYLOAD_DIR}${INSTALL_PATH}"
mkdir -p "${SCRIPTS_DIR}"
mkdir -p "${LAUNCH_AGENT_DIR}"

# --- Generate Config.swift ---------------------------------------------------

echo "[2/8] Generating Config.swift..."

cat > "${GENERATED_CONFIG}" <<CONFIGSWIFT
// Generated by build.sh from config.sh — do not edit.
// Regenerate by running ./build.sh.

import CoreGraphics

enum Config {
    static let botURL = "$(swift_escape "${BOT_URL}")"
    static let appName = "$(swift_escape "${APP_DISPLAY_NAME}")"
    static let appVersion = "$(swift_escape "${APP_VERSION}")"
    static let appCopyright = "$(swift_escape "${APP_COPYRIGHT}")"
    static let popoverWidth: CGFloat = ${POPOVER_WIDTH}
    static let popoverHeight: CGFloat = ${POPOVER_HEIGHT}
    static let persistentSession = ${SWIFT_PERSISTENT}
}
CONFIGSWIFT

echo "       Config generated OK"

# --- Compile -----------------------------------------------------------------

echo "[3/8] Compiling universal binary (arm64 + x86_64)..."

for arch in arm64 x86_64; do
    swiftc -framework Cocoa -framework WebKit \
        -O \
        -target "${arch}-apple-macos${MIN_MACOS_VERSION}" \
        -o "${BUILD_DIR}/${APP_NAME}_${arch}" \
        "${SOURCE_MAIN}" "${GENERATED_CONFIG}"
done

lipo -create \
    "${BUILD_DIR}/${APP_NAME}_arm64" \
    "${BUILD_DIR}/${APP_NAME}_x86_64" \
    -output "${BUILD_DIR}/${APP_NAME}"

rm "${BUILD_DIR}/${APP_NAME}_arm64" "${BUILD_DIR}/${APP_NAME}_x86_64"
echo "       Universal binary OK"

# --- App Bundle --------------------------------------------------------------

echo "[4/8] Creating app bundle..."

mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod 755 "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# --- Icon --------------------------------------------------------------------

ICONSET_DIR="${SCRIPT_DIR}/AppIcon.iconset"

if [[ -d "${ICONSET_DIR}" ]]; then
    echo "       Building app icon from AppIcon.iconset..."
    iconutil -c icns "${ICONSET_DIR}" -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

    if [[ -f "${ICONSET_DIR}/icon_32x32.png" ]]; then
        cp "${ICONSET_DIR}/icon_32x32.png" "${APP_BUNDLE}/Contents/Resources/menubar_icon.png"
    fi
    echo "       Icon bundled OK"
else
    echo "       No AppIcon.iconset found — using SF Symbol fallback"
    echo "       (See README for how to add a custom icon)"
fi

# --- App Transport Security --------------------------------------------------
# ATS stays fully enabled for https bots. Only when BOT_URL is plaintext http
# do we punch a hole, and only for that one host, rather than switching on
# NSAllowsArbitraryLoads and permitting cleartext everywhere.

ATS_BLOCK=""
if [[ "${BOT_URL}" == http://* ]]; then
    BOT_HOST="${BOT_URL#http://}"
    BOT_HOST="${BOT_HOST%%/*}"   # strip path
    BOT_HOST="${BOT_HOST##*@}"   # strip userinfo
    BOT_HOST="${BOT_HOST%%:*}"   # strip port (IPv6 literals are not supported)

    echo ""
    echo "       WARNING: BOT_URL is plaintext http://. Chat transcripts will"
    echo "       travel unencrypted. Adding a scoped ATS exception for"
    echo "       ${BOT_HOST} only. Use https:// if you possibly can."
    echo ""

    ATS_BLOCK="    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>$(xml_escape "${BOT_HOST}")</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
        </dict>
    </dict>"
fi

# --- Info.plist --------------------------------------------------------------

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$(xml_escape "${APP_NAME}")</string>
    <key>CFBundleDisplayName</key>
    <string>$(xml_escape "${APP_DISPLAY_NAME}")</string>
    <key>CFBundleIdentifier</key>
    <string>$(xml_escape "${APP_IDENTIFIER}")</string>
    <key>CFBundleVersion</key>
    <string>$(xml_escape "${APP_VERSION}")</string>
    <key>CFBundleShortVersionString</key>
    <string>$(xml_escape "${APP_VERSION}")</string>
    <key>CFBundleExecutable</key>
    <string>$(xml_escape "${APP_NAME}")</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_VERSION}.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
        <string>x86_64</string>
    </array>
${ATS_BLOCK}
    <key>NSHumanReadableCopyright</key>
    <string>$(xml_escape "${APP_COPYRIGHT}")</string>
</dict>
</plist>
PLIST

if command -v plutil &>/dev/null; then
    plutil -lint "${APP_BUNDLE}/Contents/Info.plist" >/dev/null
fi

# --- Code signing ------------------------------------------------------------

echo "[5/8] Code signing..."

if [[ -n "${SIGNING_IDENTITY}" ]]; then
    codesign --force --options runtime --timestamp \
        --identifier "${APP_IDENTIFIER}" \
        --sign "${SIGNING_IDENTITY}" \
        "${APP_BUNDLE}"
    codesign --verify --strict --verbose=2 "${APP_BUNDLE}"
    echo "       Signed with: ${SIGNING_IDENTITY}"
else
    echo "       SKIPPED — SIGNING_IDENTITY is not set in config.sh."
    echo "       Unsigned builds install and run, but macOS treats their"
    echo "       TCC/permission grants as disposable and each update can"
    echo "       re-prompt users. Sign production builds."
fi

# --- LaunchAgent -------------------------------------------------------------

echo "[6/8] Creating LaunchAgent for auto-start at login..."

cat > "${LAUNCH_AGENT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(xml_escape "${LAUNCH_AGENT_LABEL}")</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$(xml_escape "${INSTALL_PATH}/${APP_NAME}.app")</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
    </array>
</dict>
</plist>
PLIST

chmod 644 "${LAUNCH_AGENT_PLIST}"
echo "       LaunchAgent: ${LAUNCH_AGENT_LABEL}"

# --- Pre/Post Install Scripts ------------------------------------------------

echo "[7/8] Creating installer scripts..."

# Preinstall: kill any running instance before replacing
cat > "${SCRIPTS_DIR}/preinstall" <<SCRIPT
#!/bin/bash
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 1
exit 0
SCRIPT

# Postinstall: set permissions, load LaunchAgent for current user
cat > "${SCRIPTS_DIR}/postinstall" <<SCRIPT
#!/bin/bash

APP_PATH="/Applications/${APP_NAME}.app"
LAUNCH_AGENT="/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

# Set correct ownership. Strip group/other write rather than chmod -R 755:
# blanket 755 marks plists and images executable, and only the Mach-O in
# Contents/MacOS actually needs the execute bit.
chown -R root:wheel "\${APP_PATH}"
chmod -R go-w "\${APP_PATH}"
chmod 755 "\${APP_PATH}/Contents/MacOS/${APP_NAME}"

chown root:wheel "\${LAUNCH_AGENT}"
chmod 644 "\${LAUNCH_AGENT}"

# Load the LaunchAgent for the currently logged-in user
CURRENT_USER=\$(stat -f "%Su" /dev/console)
if [[ "\${CURRENT_USER}" != "loginwindow" && "\${CURRENT_USER}" != "_mbsetupuser" && "\${CURRENT_USER}" != "root" ]]; then
    CURRENT_UID=\$(id -u "\${CURRENT_USER}")

    # Unload first in case it's already loaded (upgrade scenario)
    launchctl bootout "gui/\${CURRENT_UID}/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true
    sleep 1

    # Bootstrap (load) the LaunchAgent
    launchctl bootstrap "gui/\${CURRENT_UID}" "\${LAUNCH_AGENT}"

    echo "${APP_NAME} LaunchAgent loaded for user \${CURRENT_USER}"
fi

exit 0
SCRIPT

chmod 755 "${SCRIPTS_DIR}/preinstall"
chmod 755 "${SCRIPTS_DIR}/postinstall"

# --- Build .pkg --------------------------------------------------------------

echo "[8/8] Building installer package..."

if [[ -n "${INSTALLER_IDENTITY}" ]]; then
    PKG_TARGET="${BUILD_DIR}/${APP_NAME}-${APP_VERSION}-unsigned.pkg"
else
    PKG_TARGET="${PKG_OUTPUT}"
fi

pkgbuild \
    --root "${PAYLOAD_DIR}" \
    --identifier "${APP_IDENTIFIER}" \
    --version "${APP_VERSION}" \
    --scripts "${SCRIPTS_DIR}" \
    --install-location "/" \
    "${PKG_TARGET}"

if [[ -n "${INSTALLER_IDENTITY}" ]]; then
    productsign --sign "${INSTALLER_IDENTITY}" "${PKG_TARGET}" "${PKG_OUTPUT}"
    rm -f "${PKG_TARGET}"
    pkgutil --check-signature "${PKG_OUTPUT}" >/dev/null
    echo "       Package signed with: ${INSTALLER_IDENTITY}"
else
    echo "       Package is unsigned (INSTALLER_IDENTITY not set in config.sh)"
fi

echo ""
echo "============================================"
echo "  BUILD COMPLETE"
echo "============================================"
echo ""
echo "  Package:  ${PKG_OUTPUT}"
echo "  Size:     $(du -h "${PKG_OUTPUT}" | awk '{print $1}')"
echo ""
echo "  What it installs:"
echo "    /Applications/${APP_NAME}.app"
echo "    /Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
echo ""
echo "============================================"
echo "  JAMF PRO DEPLOYMENT"
echo "============================================"
echo ""
echo "  1. Upload the .pkg to Jamf Pro:"
echo "     Settings > Computer Management > Packages > New"
echo ""
echo "  2. Create a Policy:"
echo "     Computers > Policies > New"
echo "     - Trigger: Recurring Check-in"
echo "     - Frequency: Once per computer"
echo "     - Packages: Add ${APP_NAME}-${APP_VERSION}.pkg"
echo "     - Scope: Target smart group or all managed Macs"
echo ""
echo "  See README.md for full Jamf deployment instructions."
echo "============================================"
