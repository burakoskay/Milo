#!/bin/bash
#
# Disable Apple Intelligence / Siri Background Processes
# =========================================================
# 
# These processes are deeply integrated into macOS and use XPC event triggers.
# Simply killing them won't work - they respawn via event triggers.
#
# This script attempts to:
# 1. Disable services in BOTH system and user domains
# 2. Bootout running instances
# 3. Kill processes
#
# REQUIREMENTS:
# - SIP must be disabled (csrutil disable in Recovery Mode)
# - Run with sudo
#
# WARNING: This may break Siri, Spotlight suggestions, and other features.
# To re-enable, run: ./enable_apple_intelligence.sh
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

UID_NUM=$(id -u)

echo -e "${YELLOW}===== Apple Intelligence/Siri Process Disabler =====${NC}"
echo ""

# Check SIP status
if csrutil status | grep -q "enabled"; then
    echo -e "${RED}ERROR: System Integrity Protection (SIP) is ENABLED${NC}"
    echo "These system processes cannot be permanently disabled with SIP on."
    echo ""
    echo "To disable SIP:"
    echo "  1. Restart Mac and hold Command+R to enter Recovery Mode"
    echo "  2. Open Terminal from Utilities menu"
    echo "  3. Run: csrutil disable"
    echo "  4. Restart and run this script again"
    exit 1
fi

echo -e "${GREEN}SIP is disabled - proceeding...${NC}"
echo ""

# Services to disable
SERVICES=(
    "com.apple.duetexpertd"
    "com.apple.suggestd"
    "com.apple.spotlightknowledged"
    "com.apple.spotlightknowledged.updater"
    "com.apple.spotlightknowledged.importer"
    "com.apple.siriknowledged"
    "com.apple.siri.inference"
    "com.apple.intelligenceplatformd"
    "com.apple.coreduetd"
    "com.apple.biomed"
    "com.apple.triald"
    "com.apple.mediaanalysisd"
    "com.apple.photoanalysisd"
    "com.apple.BiomeAgent"
    "com.apple.knowledge-agent"
)

# Additional related services
RELATED_SERVICES=(
    "com.apple.suggestd.deliveries"
    "com.apple.suggestd.ipsos"
    "com.apple.suggestd.fides"
    "com.apple.suggestd.events"
    "com.apple.suggestd.mail"
    "com.apple.suggestd.internal"
    "com.apple.suggestd.reminders"
    "com.apple.suggestd.messages"
    "com.apple.suggestd.contacts"
    "com.apple.suggestd.urls"
    "com.apple.duetexpertd.ControlCenter"
    "com.apple.duetexpertd.SettingsActions"
    "com.apple.proactive.ContextualEngine.suggestions.xpc"
    "com.apple.proactive.input.suggester"
)

# Process names to kill
PROCESSES=(
    "duetexpertd"
    "suggestd"
    "spotlightknowledged"
    "siriknowledged"
    "siriinferenced"
    "intelligenceplatformd"
    "coreduetd"
    "biomed"
    "triald"
    "mediaanalysisd"
    "photoanalysisd"
    "BiomeAgent"
    "knowledge-agent"
)

echo "Disabling services in SYSTEM domain..."
for service in "${SERVICES[@]}"; do
    echo -n "  $service: "
    if launchctl disable "system/$service" 2>/dev/null; then
        echo -e "${GREEN}disabled${NC}"
    else
        echo -e "${YELLOW}already disabled or not found${NC}"
    fi
done

echo ""
echo "Disabling services in USER domain (gui/$UID_NUM)..."
for service in "${SERVICES[@]}" "${RELATED_SERVICES[@]}"; do
    echo -n "  $service: "
    if launchctl disable "gui/$UID_NUM/$service" 2>/dev/null; then
        echo -e "${GREEN}disabled${NC}"
    else
        echo -e "${YELLOW}already disabled or not found${NC}"
    fi
done

echo ""
echo "Booting out running services..."
for service in "${SERVICES[@]}" "${RELATED_SERVICES[@]}"; do
    launchctl bootout "gui/$UID_NUM/$service" 2>/dev/null || true
done

echo ""
echo "Unloading plist files with -w flag..."
PLIST_DIR="/System/Library/LaunchAgents"
for service in "${SERVICES[@]}"; do
    plist="$PLIST_DIR/$service.plist"
    if [ -f "$plist" ]; then
        echo -n "  $(basename $plist): "
        if launchctl unload -w "$plist" 2>/dev/null; then
            echo -e "${GREEN}unloaded${NC}"
        else
            echo -e "${YELLOW}already unloaded${NC}"
        fi
    fi
done

echo ""
echo "Killing processes..."
for proc in "${PROCESSES[@]}"; do
    if pgrep -f "$proc" > /dev/null 2>&1; then
        echo -n "  $proc: "
        pkill -9 -f "$proc" 2>/dev/null || true
        echo -e "${GREEN}killed${NC}"
    fi
done

echo ""
echo -e "${GREEN}===== Done! =====${NC}"
echo ""
echo "The services have been disabled. They should not respawn."
echo "If they do, you may need to restart your Mac."
echo ""
echo "To verify, run:"
echo "  launchctl list | grep -E 'duetexpert|suggestd|spotlight'"
echo ""
echo "To re-enable these services later, run:"
echo "  ./enable_apple_intelligence.sh"
