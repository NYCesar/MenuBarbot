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
# IMPORTANT: Update APP_PATH below to match your APP_NAME in config.sh.
#
# This lets you create Smart Groups like:
#   "MenuBarBot Version" is not "1.0"  -> machines needing an update
#   "MenuBarBot Version" is ""         -> machines without it installed
# =============================================================================

# ---- Change this to match your APP_NAME from config.sh --------------------
APP_PATH="/Applications/MenuBarBot.app"
# ---------------------------------------------------------------------------

if [[ -d "${APP_PATH}" ]]; then
    VERSION=$(/usr/bin/defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
    if [[ -n "${VERSION}" ]]; then
        echo "<result>${VERSION}</result>"
    else
        echo "<result>Installed (unknown version)</result>"
    fi
else
    echo "<result></result>"
fi
