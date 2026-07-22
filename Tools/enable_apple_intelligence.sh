#!/bin/bash
#
# Re-enable Apple Intelligence / Siri Background Processes
# =========================================================
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

UID_NUM=$(id -u)

echo -e "${YELLOW}===== Apple Intelligence/Siri Process Enabler =====${NC}"
echo ""

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

echo "Enabling services in SYSTEM domain..."
for service in "${SERVICES[@]}"; do
    launchctl enable "system/$service" 2>/dev/null || true
done

echo "Enabling services in USER domain (gui/$UID_NUM)..."
for service in "${SERVICES[@]}"; do
    launchctl enable "gui/$UID_NUM/$service" 2>/dev/null || true
done

echo ""
echo "Loading plist files..."
PLIST_DIR="/System/Library/LaunchAgents"
for service in "${SERVICES[@]}"; do
    plist="$PLIST_DIR/$service.plist"
    if [ -f "$plist" ]; then
        launchctl load -w "$plist" 2>/dev/null || true
        launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/dev/null || true
    fi
done

echo ""
echo -e "${GREEN}===== Done! =====${NC}"
echo ""
echo "Services have been re-enabled. You may need to restart your Mac"
echo "or log out and back in for all services to start."
