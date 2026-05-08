#!/bin/bash
# Kill Siri & Apple Intelligence Bloatware

echo "Terminating Intelligence & Learning daemons..."

declare -a processes=(
    # The Brains
    "siriknowledged"
    "siriinferenced"
    "siriactionsd"
    "intelligenceplatformd"
    "intelligencecontextd"
    "generativeexperiencesd"
    "SiriTTSService"
    "suggestd"
    
    # The Spies (Learning)
    "coreduetd"
    "knowledge-agent"
    "biomed"
    "biomesyncd"
    "triald"
    "duetexpertd"
    
    # Media Analysis
    "mediaanalysisd"
    "photoanalysisd"
    "mediaanalysisd-access"
    
    # Spotlight / Knowledge related
    "spotlightknowledged"
    "CallIntelligence"
)

# Function to escape regex special characters
escape_regex() {
    printf '%s\n' "$1" | sed 's/[][\.^*+?()|\\${}]/\\&/g'
}

for process in "${processes[@]}"
do
    # pkill -f matches against the full command line
    # -- to prevent process names starting with - from being interpreted as options
    escaped_process=$(escape_regex "$process")
    if pkill -f -- "$escaped_process" 2>/dev/null; then
        echo "  - Killed $process"
    fi
done

echo "Intelligence services terminated."
