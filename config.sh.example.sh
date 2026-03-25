#!/bin/bash

# =============================================================================
# MenuBarBot Configuration
# =============================================================================
# Edit these values to customize the app for your organization.
# All build scripts, the uninstall script, and the Jamf extension attribute
# read from this file — change once, apply everywhere.
# =============================================================================

# The URL your chatbot is hosted at.
# Works with Zapier Chatbots, Botpress, Tidio, Intercom, Drift, or any
# web-hosted chatbot/page.
BOT_URL="https://your-chatbot-url.example.com/"

# What users see in the menu bar tooltip and About dialog
APP_DISPLAY_NAME="My IT Bot"

# Internal app name (no spaces — used for the binary, .app bundle, process name)
APP_NAME="MenuBarBot"

# macOS bundle identifier (reverse-DNS style, must be unique to your org)
APP_IDENTIFIER="com.example.menubarbot"

# Version string shown in About dialog and used in the .pkg filename
APP_VERSION="1.0"

# Copyright line shown in the About dialog
APP_COPYRIGHT="© 2025 Your Organization"

# Popover dimensions (pixels)
POPOVER_WIDTH=420
POPOVER_HEIGHT=640

# Minimum macOS version required (14 = Sonoma, 15 = Sequoia)
MIN_MACOS_VERSION="14"
