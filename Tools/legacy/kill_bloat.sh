#!/bin/bash
# Kill Background Bloatware Script
# Targets: Adobe, CleanMyMac, Avid, AdGuard, Cloudflare WARP, Disk Drill, UAD, Antelope, Microsoft, Figma, Simulator, Unused Widgets

echo "Stopping background processes..."

# List of processes to kill (case-insensitive search)
declare -a processes=(
    # Adobe
    "Adobe Desktop Service"
    "CCXProcess"
    "AdobeIPCBroker"
    "Core Sync"
    "CCLibrary"
    "Adobe Crash Reporter"
    "Adobe CEF Helper"
    "Creative Cloud"
    "AdobeCRDaemon"
    "Adobe Installer"
    "AdobeUpdateService"
    "Acrobat Update Service"
    "Adobe Callid"
    "AdobeCollabSync"
    "Creative Cloud Helper"
    "AdobeNotificationClient"
    "Adobe Content Synchronizer"
    
    # CleanMyMac
    "CleanMyMac"
    "CleanMyMac X HealthMonitor"
    "CleanMyMac X Menu"
    "com.macpaw.CleanMyMac"
    "CleanMyMac_5_Menu"
    "CleanMyMac_5_HealthMonitor"
    
    # Avid
    "Avid Link"
    "AvidAppManHelper"
    "AvidBackgroundServices"

    # Utilities / Privacy / Helpers
    "cfbackd"               # Disk Drill
    "AdGuard for Safari"    # AdGuard
    "AdGuard Login Helper"
    "Cloudflare WARP"       # Cloudflare WARP
    "LoginLauncherApp"      # Cloudflare Sneaky Login Item
    "figma_agent"           # Figma Font Helper

    # Audio Drivers (UAD & Antelope)
    "com.uaudio.bsd.helper"
    "UA Mixer Engine"
    "UAD Meter & Control Panel"
    "Universal Audio"
    "UA Connect Launcher"   # UAD Sneaky Login Item
    "com.antelopeaudio.daemon"
    "AntelopeLauncher"
    "AntelopeManager"

    # Microsoft
    "ExcelWidget_mac"
    "WordWidget_mac"
    "PowerPointWidget_mac"
    "Microsoft AutoUpdate"
    "Microsoft Update Assistant"
    "Office365Service"

    # Developer Tools
    "SimulatorTrampoline"
    "CoreSimulatorService"

    # Unused Widgets
    "CalendarWidgetExtension"
    "Notes.WidgetExtension"
    "PhotosReliveWidget"
    "PodcastsWidget"
    "RemindersWidgetExtension"
    "ShortcutsWidgetExtension"
    "StocksWidget"
    "TipsWidgetExtension"
    "RecordWidgetExtension"
    "FindMyWidgetItems"
    "FindMyWidgetPeople"
    "HomeWidget"
)

# Function to escape regex special characters
escape_regex() {
    printf '%s\n' "$1" | sed 's/[][\.^*+?()|\\${}]/\\&/g'
}

for process in "${processes[@]}"
do
    # pkill -f matches against the full command line
    # -i for case-insensitive match
    # -- to prevent process names starting with - from being interpreted as options
    escaped_process=$(escape_regex "$process")
    if pkill -i -f -- "$escaped_process" 2>/dev/null; then
        echo "  - Killed $process"
    fi
done

echo "Background processes stopped."
