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

for process in "${processes[@]}"
do
    if pkill -f "$process" 2>/dev/null; then
        echo "  - Killed $process"
    fi
done

echo "Intelligence services terminated."
