#!/bin/bash

# =============================================================================
# Build MenuBarBot — Jamf-Deployable Installer Package
# =============================================================================
#
# This script:
#   1. Reads configuration from config.sh
#   2. Injects config values into the Swift source
#   3. Compiles a universal binary (arm64 + x86_64)
#   4. Bundles the app icon (if provided)
#   5. Creates a proper .app bundle in /Applications
#   6. Creates a LaunchAgent so it auto-starts at login for all users
#   7. Builds a flat .pkg installer ready to upload to Jamf Pro
#
# Requirements:
#   - macOS with Xcode Command Line Tools (swiftc, pkgbuild)
#   - config.sh in the same directory (edit this first!)
#
# Optional:
#   - AppIcon.iconset/ folder with icon PNGs (see README for format)
#
# Output:
#   build/<APP_NAME>-<APP_VERSION>.pkg
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
SOURCE_TEMPLATE="${SCRIPT_DIR}/MenuBarBot.swift"

# --- Load config -------------------------------------------------------------

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.sh not found in ${SCRIPT_DIR}"
    echo "Copy config.sh.example to config.sh and edit it."
    exit 1
fi

source "${CONFIG_FILE}"

# Validate required config values
for var in BOT_URL APP_DISPLAY_NAME APP_NAME APP_IDENTIFIER APP_VERSION; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: ${var} is not set in config.sh"
        exit 1
    fi
done

if [[ "${BOT_URL}" == *"example.com"* ]]; then
    echo "ERROR: You need to set BOT_URL in config.sh to your actual chatbot URL."
    exit 1
fi

INSTALL_PATH="/Applications"
BUILD_DIR="${SCRIPT_DIR}/build"
PAYLOAD_DIR="${BUILD_DIR}/payload"
SCRIPTS_DIR="${BUILD_DIR}/scripts"
APP_BUNDLE="${PAYLOAD_DIR}${INSTALL_PATH}/${APP_NAME}.app"

LAUNCH_AGENT_LABEL="${APP_IDENTIFIER}.launcher"
LAUNCH_AGENT_DIR="${PAYLOAD_DIR}/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_DIR}/${LAUNCH_AGENT_LABEL}.plist"

PKG_OUTPUT="${BUILD_DIR}/${APP_NAME}-${APP_VERSION}.pkg"

# Default optional values
POPOVER_WIDTH="${POPOVER_WIDTH:-420}"
POPOVER_HEIGHT="${POPOVER_HEIGHT:-640}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14}"
APP_COPYRIGHT="${APP_COPYRIGHT:-}"

echo "============================================"
echo "  Building ${APP_DISPLAY_NAME} v${APP_VERSION}"
echo "  Bundle ID: ${APP_IDENTIFIER}"
echo "  Bot URL:   ${BOT_URL}"
echo "============================================"
echo ""

# --- Validate ----------------------------------------------------------------

if [[ ! -f "${SOURCE_TEMPLATE}" ]]; then
    echo "ERROR: ${SOURCE_TEMPLATE} not found"
    exit 1
fi

if ! command -v swiftc &>/dev/null; then
    echo "ERROR: swiftc not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

# --- Clean -------------------------------------------------------------------

echo "[1/7] Cleaning previous build..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${PAYLOAD_DIR}${INSTALL_PATH}"
mkdir -p "${SCRIPTS_DIR}"
mkdir -p "${LAUNCH_AGENT_DIR}"

# --- Inject config into Swift source ----------------------------------------

echo "[2/7] Injecting configuration..."

SWIFT_BUILD="${BUILD_DIR}/MenuBarBot.swift"
cp "${SOURCE_TEMPLATE}" "${SWIFT_BUILD}"

# Escape special characters for sed
escape_sed() {
    echo "$1" | sed 's/[&/\]/\\&/g'
}

sed -i '' "s|__BOT_URL__|$(escape_sed "${BOT_URL}")|g"               "${SWIFT_BUILD}"
sed -i '' "s|__POPOVER_WIDTH__|${POPOVER_WIDTH}|g"                    "${SWIFT_BUILD}"
sed -i '' "s|__POPOVER_HEIGHT__|${POPOVER_HEIGHT}|g"                  "${SWIFT_BUILD}"
sed -i '' "s|__APP_DISPLAY_NAME__|$(escape_sed "${APP_DISPLAY_NAME}")|g" "${SWIFT_BUILD}"
sed -i '' "s|__APP_VERSION__|$(escape_sed "${APP_VERSION}")|g"        "${SWIFT_BUILD}"
sed -i '' "s|__APP_COPYRIGHT__|$(escape_sed "${APP_COPYRIGHT}")|g"    "${SWIFT_BUILD}"

echo "       Config injected OK"

# --- Compile -----------------------------------------------------------------

echo "[3/7] Compiling universal binary (arm64 + x86_64)..."

swiftc -framework Cocoa -framework WebKit \
    -O \
    -target arm64-apple-macos${MIN_MACOS_VERSION} \
    -o "${BUILD_DIR}/${APP_NAME}_arm64" \
    "${SWIFT_BUILD}" 2>&1

swiftc -framework Cocoa -framework WebKit \
    -O \
    -target x86_64-apple-macos${MIN_MACOS_VERSION} \
    -o "${BUILD_DIR}/${APP_NAME}_x86_64" \
    "${SWIFT_BUILD}" 2>&1

lipo -create \
    "${BUILD_DIR}/${APP_NAME}_arm64" \
    "${BUILD_DIR}/${APP_NAME}_x86_64" \
    -output "${BUILD_DIR}/${APP_NAME}"

rm "${BUILD_DIR}/${APP_NAME}_arm64" "${BUILD_DIR}/${APP_NAME}_x86_64"
echo "       Universal binary OK"

# --- App Bundle --------------------------------------------------------------

echo "[4/7] Creating app bundle..."

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

# --- Info.plist --------------------------------------------------------------

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_IDENTIFIER}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
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
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>${APP_COPYRIGHT}</string>
</dict>
</plist>
PLIST

# --- LaunchAgent -------------------------------------------------------------

echo "[5/7] Creating LaunchAgent for auto-start at login..."

cat > "${LAUNCH_AGENT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>${INSTALL_PATH}/${APP_NAME}.app</string>
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

echo "[6/7] Creating installer scripts..."

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

# Set correct ownership and permissions
chown -R root:wheel "\${APP_PATH}"
chmod -R 755 "\${APP_PATH}"

chown root:wheel "\${LAUNCH_AGENT}"
chmod 644 "\${LAUNCH_AGENT}"

# Load the LaunchAgent for the currently logged-in user
CURRENT_USER=\$(stat -f "%Su" /dev/console)
if [[ "\${CURRENT_USER}" != "loginwindow" && "\${CURRENT_USER}" != "_mbsetupuser" ]]; then
    CURRENT_UID=\$(id -u "\${CURRENT_USER}")

    # Unload first in case it's already loaded (upgrade scenario)
    launchctl bootout "gui/\${CURRENT_UID}/\${LAUNCH_AGENT##*/}" 2>/dev/null || true
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

echo "[7/7] Building installer package..."

pkgbuild \
    --root "${PAYLOAD_DIR}" \
    --identifier "${APP_IDENTIFIER}" \
    --version "${APP_VERSION}" \
    --scripts "${SCRIPTS_DIR}" \
    --install-location "/" \
    "${PKG_OUTPUT}"

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
