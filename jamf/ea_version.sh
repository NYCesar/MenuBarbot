#!/bin/bash

# =============================================================================
# Jamf Pro Extension Attribute: MenuBarBot Version
# =============================================================================
#
# Add this as a Computer Extension Attribute in Jamf Pro:
#   Settings > Computer Management > Extension Attributes > New
#   - Display Name: MenuBarBot Version
#   - Data Type: String
#   - Input Type: Script
#   - Paste this script
#
# IMPORTANT: Update APP_IDENTIFIER below to match config.sh.
#
# The app is located by bundle identifier rather than by path, so this keeps
# working regardless of what APP_NAME your build used or whether someone
# renamed the .app.
#
# This lets you create Smart Groups like:
#   "MenuBarBot Version" is not "1.0"  -> machines needing an update
#   "MenuBarBot Version" is ""         -> machines without it installed
# =============================================================================

# ---- Change this to match your APP_IDENTIFIER from config.sh ---------------
APP_IDENTIFIER="com.example.menubarbot"
# ---------------------------------------------------------------------------

read_key() {
    /usr/bin/defaults read "$1" "$2" 2>/dev/null
}

find_app_bundle() {
    local app plist
    for app in /Applications/*.app /Applications/Utilities/*.app; do
        plist="${app}/Contents/Info.plist"
        [[ -f "${plist}" ]] || continue
        if [[ "$(read_key "${plist}" CFBundleIdentifier)" == "${APP_IDENTIFIER}" ]]; then
            printf '%s' "${app}"
            return 0
        fi
    done
    return 1
}

APP_PATH="$(find_app_bundle)"

if [[ -z "${APP_PATH}" ]]; then
    echo "<result></result>"
    exit 0
fi

VERSION="$(read_key "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString)"

if [[ -n "${VERSION}" ]]; then
    echo "<result>${VERSION}</result>"
else
    echo "<result>Installed (unknown version)</result>"
fi
