#!/bin/bash

# =============================================================================
# Uninstall MenuBarBot
# =============================================================================
# Removes the app, the LaunchAgent, the installer receipt, and the per-user
# WebKit data the app leaves behind. Stops any running instance first.
#
# Usage:
#   Run locally:          sudo ./uninstall.sh
#   Jamf Pro:             Add as a script payload in an uninstall policy
#
# Reads APP_NAME and APP_IDENTIFIER from config.sh if available,
# otherwise falls back to the values passed as Jamf script parameters
# ($4 = APP_NAME, $5 = APP_IDENTIFIER).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"

# Try to load config; fall back to Jamf parameters or defaults
if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
else
    APP_NAME="${4:-MenuBarBot}"
    APP_IDENTIFIER="${5:-com.example.menubarbot}"
fi

APP_PATH="/Applications/${APP_NAME}.app"
LAUNCH_AGENT_LABEL="${APP_IDENTIFIER}.launcher"
LAUNCH_AGENT_PLIST="/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

echo "Uninstalling ${APP_NAME}..."

# Get current console user
CURRENT_USER=$(stat -f "%Su" /dev/console)

# Unload the LaunchAgent for the current user
if [[ "${CURRENT_USER}" != "loginwindow" && "${CURRENT_USER}" != "_mbsetupuser" && "${CURRENT_USER}" != "root" ]]; then
    CURRENT_UID=$(id -u "${CURRENT_USER}")
    launchctl bootout "gui/${CURRENT_UID}/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true
    echo "LaunchAgent unloaded for user ${CURRENT_USER}"
fi

# Kill the running app
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 1

# Remove the LaunchAgent plist
if [[ -f "${LAUNCH_AGENT_PLIST}" ]]; then
    rm -f "${LAUNCH_AGENT_PLIST}"
    echo "Removed ${LAUNCH_AGENT_PLIST}"
fi

# Remove the app
if [[ -d "${APP_PATH}" ]]; then
    rm -rf "${APP_PATH}"
    echo "Removed ${APP_PATH}"
fi

# Forget the installer receipt. Without this the package still shows up in
# `pkgutil --pkgs` after removal, and any receipt-based Jamf Smart Group
# keeps reporting the machine as having the app installed.
if pkgutil --pkg-info "${APP_IDENTIFIER}" &>/dev/null; then
    pkgutil --forget "${APP_IDENTIFIER}" >/dev/null 2>&1 || true
    echo "Forgot package receipt ${APP_IDENTIFIER}"
fi

# Remove per-user data. WKWebView writes here even in non-persistent mode
# (caches and saved state), and these survive deleting the .app.
for USER_HOME in /Users/*; do
    [[ -d "${USER_HOME}" ]] || continue
    case "$(basename "${USER_HOME}")" in
        Shared|Guest) continue ;;
    esac

    rm -rf "${USER_HOME}/Library/WebKit/${APP_IDENTIFIER}"
    rm -rf "${USER_HOME}/Library/Caches/${APP_IDENTIFIER}"
    rm -rf "${USER_HOME}/Library/HTTPStorages/${APP_IDENTIFIER}"
    rm -rf "${USER_HOME}/Library/HTTPStorages/${APP_IDENTIFIER}.binarycookies"
    rm -rf "${USER_HOME}/Library/Saved Application State/${APP_IDENTIFIER}.savedState"
    rm -f  "${USER_HOME}/Library/Preferences/${APP_IDENTIFIER}.plist"
done
echo "Removed per-user application data"

echo "${APP_NAME} uninstalled successfully."
exit 0
