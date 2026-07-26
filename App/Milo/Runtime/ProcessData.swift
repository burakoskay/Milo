import Foundation

// MARK: - Data definitions for process targets, descriptions, and vendor mapping
// Separated from ProcessManager logic for maintainability.

enum ProcessData {

    // MARK: - Friendly Descriptions (keyed by lowercased process name)

    static let friendlyDescriptions: [String: String] = [
        // ───────────────────────────────────────────────────────────────
        // Adobe Creative Cloud (Comprehensive)
        // ───────────────────────────────────────────────────────────────
        "adobe desktop service": "Adobe · Background sync & licensing",
        "ccxprocess": "Adobe · Creative Cloud experience host",
        "adobeipcbroker": "Adobe · Inter-process communication broker",
        "core sync": "Adobe · File sync for Creative Cloud libraries",
        "cclibrary": "Adobe · Creative Cloud libraries helper",
        "adobe crash reporter": "Adobe · Crash telemetry uploader",
        "adobe cef helper": "Adobe · Chromium Embedded Framework helper",
        "creative cloud": "Adobe · Main Creative Cloud app",
        "adobecrdaemon": "Adobe · Background crash handler",
        "adobe installer": "Adobe · Silent installer/updater",
        "adobeupdateservice": "Adobe · Auto-update service",
        "acrobat update service": "Adobe · Acrobat auto-update",
        "adobe callid": "Adobe · Licensing call-home",
        "adobecollabsync": "Adobe · Collaboration sync service",
        "creative cloud helper": "Adobe · Helper for Creative Cloud menu",
        "adobenotificationclient": "Adobe · Desktop notifications",
        "adobe content synchronizer": "Adobe · Asset sync between apps",
        "adobegcclient": "Adobe · Genuine software check",
        "adoberesourcesynchronizer": "Adobe · Resource sync service",
        "node": "Adobe · Node.js backend (Creative Cloud)",
        "logtransport2": "Adobe · Log upload service",
        "armsvc": "Adobe · ARM service helper",
        "acrodist": "Adobe · Acrobat Distiller",
        "adobearm": "Adobe · ARM helper",
        "acrotray": "Adobe · Acrobat system tray",
        "adobeextensions": "Adobe · Extension manager",
        "adobepdapp": "Adobe · PDF application helper",
        "sparkipc": "Adobe · Spark IPC service",
        "beamsyncagent": "Adobe · Beam sync agent",
        "agsservice": "Adobe · Genuine service",
        "accfindersync": "Adobe · Finder sync badge overlay",
        "adobe context menu extension": "Adobe · Right-click menu injection",
        "adobe crash processor": "Adobe · Crash telemetry processor",
        "com.adobe.acc.installer.v2": "Adobe · Privileged installer daemon (root)",

        // ───────────────────────────────────────────────────────────────
        // Google Chrome & Services
        // ───────────────────────────────────────────────────────────────
        "google chrome helper": "Google · Chrome renderer process",
        "google chrome helper (gpu)": "Google · Chrome GPU process",
        "google chrome helper (renderer)": "Google · Chrome renderer",
        "google software update": "Google · Silent updater",
        "googleupdater": "Google · Update service",
        "googledrivefs": "Google · Drive file stream",
        "google drive": "Google · Drive sync client",
        "keystone": "Google · Software update framework",
        "crashpad_handler": "Google · Crash reporting",

        // ───────────────────────────────────────────────────────────────
        // Spotify
        // ───────────────────────────────────────────────────────────────
        "spotify": "Spotify · Music streaming app",
        "spotify helper": "Spotify · Helper process",
        "spotifywebhelper": "Spotify · Web helper",

        // ───────────────────────────────────────────────────────────────
        // Slack
        // ───────────────────────────────────────────────────────────────
        "slack": "Slack · Messaging app",
        "slack helper": "Slack · Helper process",
        "slack helper (gpu)": "Slack · GPU renderer",
        "slack helper (renderer)": "Slack · Content renderer",

        // ───────────────────────────────────────────────────────────────
        // Discord
        // ───────────────────────────────────────────────────────────────
        "discord": "Discord · Voice & chat app",
        "discord helper": "Discord · Helper process",
        "discord helper (gpu)": "Discord · GPU renderer",
        "discord helper (renderer)": "Discord · Content renderer",

        // ───────────────────────────────────────────────────────────────
        // Zoom
        // ───────────────────────────────────────────────────────────────
        "zoom.us": "Zoom · Video conferencing",
        "caphost": "Zoom · Screen capture host",
        "cpthost": "Zoom · Audio host",
        "zoomautoupdater": "Zoom · Auto-update service",

        // ───────────────────────────────────────────────────────────────
        // Dropbox
        // ───────────────────────────────────────────────────────────────
        "dropbox": "Dropbox · File sync client",
        "dropbox_start": "Dropbox · Startup helper",
        "dbfseventsd": "Dropbox · File system events",
        "dropboxmacupdate": "Dropbox · Update service",

        // ───────────────────────────────────────────────────────────────
        // OneDrive
        // ───────────────────────────────────────────────────────────────
        "onedrive": "OneDrive · Microsoft cloud sync",
        "onedriveupdater": "OneDrive · Update service",
        "onedrivestandaloneupdater": "OneDrive · Standalone updater",
        "filesynchelper": "OneDrive · Finder integration",

        // ───────────────────────────────────────────────────────────────
        // Box
        // ───────────────────────────────────────────────────────────────
        "box": "Box · Cloud file storage",
        "box sync": "Box · File synchronization",
        "boxdrive": "Box · Drive integration",

        // ───────────────────────────────────────────────────────────────
        // JetBrains IDEs
        // ───────────────────────────────────────────────────────────────
        "jetbrains toolbox": "JetBrains · IDE manager",
        "fsnotifier": "JetBrains · File system watcher",
        "idea": "JetBrains · IntelliJ IDEA",
        "webstorm": "JetBrains · WebStorm IDE",
        "pycharm": "JetBrains · PyCharm IDE",
        "clion": "JetBrains · CLion IDE",
        "datagrip": "JetBrains · DataGrip database tool",
        "phpstorm": "JetBrains · PhpStorm IDE",
        "rubymine": "JetBrains · RubyMine IDE",
        "goland": "JetBrains · GoLand IDE",
        "rider": "JetBrains · Rider .NET IDE",

        // ───────────────────────────────────────────────────────────────
        // VS Code & Electron Apps
        // ───────────────────────────────────────────────────────────────
        "code helper": "VS Code · Helper process",
        "code helper (gpu)": "VS Code · GPU process",
        "code helper (renderer)": "VS Code · Renderer process",
        "electron": "Electron · App framework runtime",
        "electron helper": "Electron · Helper process",

        // ───────────────────────────────────────────────────────────────
        // Browsers
        // ───────────────────────────────────────────────────────────────
        "firefox": "Firefox · Web browser",
        "firefox helper": "Firefox · Helper process",
        "safari": "Safari · Web browser",
        "safari web content": "Safari · Content renderer",
        "safaribookmarkssyncagent": "Safari · Bookmarks sync",
        "safaridavclient": "Safari · WebDAV client",
        "safarilauncher": "Safari · Launch helper",
        "arc": "Arc · Browser",
        "arc helper": "Arc · Helper process",
        "brave browser helper": "Brave · Helper process",
        "opera helper": "Opera · Helper process",
        "microsoft edge helper": "Edge · Helper process",
        "vivaldi helper": "Vivaldi · Helper process",

        // ───────────────────────────────────────────────────────────────
        // Sketch & Design Tools
        // ───────────────────────────────────────────────────────────────
        "sketch": "Sketch · Design tool",
        "sketchmirrorhelper": "Sketch · Mirror helper",
        "com.bohemiancoding.sketch3.helper": "Sketch · Background helper",
        "figma": "Figma · Design tool",
        "figma_agent": "Figma · Font helper agent",

        // ───────────────────────────────────────────────────────────────
        // Notion & Productivity
        // ───────────────────────────────────────────────────────────────
        "notion": "Notion · Productivity app",
        "notion helper": "Notion · Helper process",
        "evernote": "Evernote · Note-taking app",
        "evernote helper": "Evernote · Helper process",
        "todoist": "Todoist · Task manager",
        "trello": "Trello · Kanban board",
        "asana": "Asana · Project management",
        "linear": "Linear · Issue tracker",

        // ───────────────────────────────────────────────────────────────
        // CleanMyMac
        // ───────────────────────────────────────────────────────────────
        "cleanmymac": "CleanMyMac · Main app",
        "cleanmymac x healthmonitor": "CleanMyMac · System health monitor",
        "cleanmymac x menu": "CleanMyMac · Menu bar helper",
        "com.macpaw.cleanmymac": "CleanMyMac · Background agent",
        "cleanmymac_5_menu": "CleanMyMac 5 · Menu bar helper",
        "cleanmymac_5_healthmonitor": "CleanMyMac 5 · Health monitor",
        "com.macpaw.cleanmymac5.agent": "CleanMyMac 5 · Background agent",

        // ───────────────────────────────────────────────────────────────
        // Avid / Pro Tools
        // ───────────────────────────────────────────────────────────────
        "avid link": "Avid · Account & update manager",
        "avidappmanhelper": "Avid · App management helper",
        "avidbackgroundservices": "Avid · Background services",
        "pro tools": "Avid · Pro Tools DAW",
        "digidesign daemon": "Avid · Legacy daemon",
        "avid application manager": "Avid · App manager",

        // ───────────────────────────────────────────────────────────────
        // Utilities / VPNs / Misc
        // ───────────────────────────────────────────────────────────────
        "cfbackd": "Disk Drill · Background recovery scanner",
        "adguard for safari": "AdGuard · Safari content blocker",
        "adguard login helper": "AdGuard · Launch-at-login helper",
        "adguard vpn helper": "AdGuard · VPN helper daemon",
        "cloudflare warp": "Cloudflare WARP · VPN client",
        "loginlauncherapp": "Cloudflare WARP · Login launcher",
        "blender-thumbnailer": "Blender · Thumbnail generator",
        "nordvpn": "NordVPN · VPN client",
        "nordvpn helper": "NordVPN · Helper daemon",
        "expressvpn": "ExpressVPN · VPN client",
        "private internet access": "PIA · VPN client",
        "surfshark": "Surfshark · VPN client",
        "1password": "1Password · Password manager",
        "1password helper": "1Password · Helper process",
        "lastpass": "LastPass · Password manager",
        "dashlane": "Dashlane · Password manager",
        "bitwarden": "Bitwarden · Password manager",

        // ───────────────────────────────────────────────────────────────
        // Audio Drivers & Licensing (UAD, Antelope, Waves, iLok, etc.)
        // ───────────────────────────────────────────────────────────────
        "com.uaudio.bsd.helper": "Universal Audio · Kernel helper",
        "ua mixer engine": "Universal Audio · DSP mixer engine",
        "uad meter & control panel": "Universal Audio · Metering & control",
        "universal audio": "Universal Audio · Main helper",
        "ua connect launcher": "Universal Audio · Connect auto-launcher",
        "com.antelopeaudio.daemon": "Antelope Audio · Device daemon",
        "antelopelauncher": "Antelope Audio · Auto-launcher",
        "antelopemanager": "Antelope Audio · Device manager",
        "waveslocalserver": "Waves · Local license server",
        "wavespluginsserver": "Waves · Plugin host server",
        "wavescentralhelper": "Waves · Central helper",
        "licensedaemon": "iLok · License authorization daemon",
        "ilokassistant": "iLok · License assistant",
        "paceprotectservice": "PACE · Protection service",
        "native instruments": "NI · Native Instruments helper",
        "ni service center": "NI · Service Center",
        "kontaktserver": "NI · Kontakt library server",
        "rolandcloud": "Roland · Cloud service",
        "izotope": "iZotope · Product portal",
        "soundtoys": "Soundtoys · Plugin helper",
        "slate digital": "Slate · Plugin helper",
        "fabfilter": "FabFilter · Plugin helper",
        "spectrasonics": "Spectrasonics · Library helper",
        "arturia": "Arturia · Software Center",
        "arturia software center": "Arturia · Update & license manager",
        "focusritecontrol": "Focusrite · Audio interface control",
        "presonusdevicemonitor": "PreSonus · Device monitor",
        "motu pro audio control": "MOTU · Audio interface control",

        // ───────────────────────────────────────────────────────────────
        // Logic Pro & GarageBand Helpers
        // ───────────────────────────────────────────────────────────────
        "logicprohelper": "Logic Pro · Helper process",
        "ausoundserver": "Logic · Audio unit server",
        "midiserver": "macOS · MIDI server daemon",
        "coreaudio": "macOS · Core Audio daemon",

        // ───────────────────────────────────────────────────────────────
        // Microsoft Office
        // ───────────────────────────────────────────────────────────────
        "excelwidget_mac": "Microsoft Excel · Notification Center widget",
        "wordwidget_mac": "Microsoft Word · Notification Center widget",
        "powerpointwidget_mac": "Microsoft PowerPoint · Notification Center widget",
        "microsoft autoupdate": "Microsoft · Silent auto-update service",
        "microsoft update assistant": "Microsoft · Update assistant",
        "office365service": "Microsoft 365 · Background sync service",
        "microsoft onenote": "Microsoft · OneNote helper",
        "microsoft outlook": "Microsoft · Outlook helper",
        "microsoft teams": "Microsoft · Teams app",
        "teams helper": "Microsoft · Teams helper",
        "teamsauditservice": "Microsoft · Teams audit",

        // ───────────────────────────────────────────────────────────────
        // Developer Tools
        // ───────────────────────────────────────────────────────────────
        "simulatortrampoline": "Xcode · iOS Simulator launcher",
        "coresimulatorservice": "Xcode · iOS Simulator backend",
        "xcode": "Apple · Xcode IDE",
        "xcrun": "Xcode · Command line tools",
        "sourcekit": "Xcode · Swift language server",
        "instruments": "Xcode · Profiling tool",
        "git": "Git · Version control",
        "gitx": "GitX · Git GUI client",
        "tower": "Tower · Git GUI client",
        "sourcetree": "Sourcetree · Git GUI client",
        "github desktop": "GitHub · Desktop client",
        "docker": "Docker · Container runtime",
        "docker desktop": "Docker · Desktop app",
        "com.docker.vmnetd": "Docker · Network daemon",

        // ───────────────────────────────────────────────────────────────
        // Database Tools
        // ───────────────────────────────────────────────────────────────
        "postgres": "PostgreSQL · Database server",
        "mysql": "MySQL · Database server",
        "mongodb": "MongoDB · Database server",
        "redis-server": "Redis · Cache server",
        "tableplus": "TablePlus · Database GUI",
        "sequelpro": "Sequel Pro · MySQL GUI",

        // ───────────────────────────────────────────────────────────────
        // Apple Widgets (usually harmless, but use CPU)
        // ───────────────────────────────────────────────────────────────
        "calendarwidgetextension": "Apple Calendar · Widget extension",
        "notes.widgetextension": "Apple Notes · Widget extension",
        "photosrelivewidget": "Apple Photos · Memories widget",
        "podcastswidget": "Apple Podcasts · Widget extension",
        "reminderswidgetextension": "Apple Reminders · Widget extension",
        "shortcutswidgetextension": "Apple Shortcuts · Widget extension",
        "stockswidget": "Apple Stocks · Widget extension",
        "tipswidgetextension": "Apple Tips · Widget extension",
        "recordwidgetextension": "Voice Memos · Widget extension",
        "findmywidgetitems": "Find My · Items widget",
        "findmywidgetpeople": "Find My · People widget",
        "homewidget": "Apple Home · Widget extension",
        "weatherwidgetextension": "Weather · Widget extension",
        "screentime": "Screen Time · Usage monitor",
        "news": "Apple News · Widget extension",
        "newswidget": "Apple News · Widget",
        "batteryhealthwidget": "Battery · Health widget",
        "musicwidget": "Apple Music · Widget",
        "homeenergywidgetsextension": "Apple Home · Energy widget extension",
        "voicememossettingswidgetextension": "Voice Memos · Settings widget extension",
        "batteriesavocadowidgetextension": "Battery · Widget extension",
        "worldclockwidget": "Clock · World clock widget extension",
        "weatherwidget": "Weather · Widget extension",
        "screentimewidgetextension": "Screen Time · Widget extension",
        "screentimewidgetintentsextension": "Screen Time · Widget intents extension",
        "journalwidgets": "Journal · Widget extension",
        "journalwidgetssecure": "Journal · Secure widget extension",

        // ───────────────────────────────────────────────────────────────
        // Apple Intelligence / Siri / Telemetry
        // ───────────────────────────────────────────────────────────────
        "siriknowledged": "Siri · Knowledge graph indexer",
        "siriinferenced": "Siri · On-device inference engine",
        "siriactionsd": "Siri · Shortcut actions handler",
        "intelligenceplatformd": "Apple Intelligence · ML platform daemon",
        "intelligencecontextd": "Apple Intelligence · Context collector",
        "generativeexperiencesd": "Apple Intelligence · Generative AI service",
        "sirittsservice": "Siri · Text-to-speech service",
        "suggestd": "macOS · App & content suggestions",
        "coreduetd": "macOS · Usage pattern learning",
        "knowledge-agent": "macOS · Personal knowledge agent",
        "biomed": "macOS · Health/biometric data collector",
        "biomesyncd": "macOS · Biome (activity) sync",
        "triald": "Apple · A/B experiment & diagnostics",
        "duetexpertd": "macOS · Predictive app preloading",
        "mediaanalysisd": "macOS · Photo/video ML analysis",
        "photoanalysisd": "Photos · Face & scene recognition",
        "mediaanalysisd-access": "macOS · Media analysis helper",
        "spotlightknowledged": "Spotlight · Personal data indexer",
        "callintelligence": "Phone · Call transcription/analysis",
        "studentd": "Screen Time · Education focus tracking",
        "appstoreagent": "App Store · Background storefront and Arcade tasks",
        "appstorecomponentsd": "App Store · Component and Arcade sync service",
        "amsengagementd": "App Store · Engagement telemetry",
        "apsd": "Apple · Push notification daemon",
        "parsec-fbf": "Apple · Analytics daemon",
        "analyticsd": "Apple · Analytics daemon",
        "symptomsd": "Apple · Diagnostics daemon",
        "diagnosticd": "Apple · Diagnostics collection",
        "reportcrash": "Apple · Crash reporter",
        "spindump": "Apple · Hang reporter",
        "tailspind": "Apple · System trace daemon",
        "awdd": "Apple · Wireless diagnostics",
        "biomeagent": "macOS · Biome event stream agent",
        "contextstored": "macOS · Context store daemon",
        "contextstoreagent": "macOS · Context store agent",
        "intelligenceplatformcomputeservice": "Apple Intelligence · Compute service",
        "saextensionorchestrator": "Siri · Extension orchestration service",
        "biomeselfingestor": "macOS · Biome ingestion extension",
        "intelligenceflowd": "Apple Intelligence · Flow coordinator",
        "intelligencetasksd": "Apple Intelligence · Task scheduler",
        "knowledgeconstructiond": "macOS · Knowledge construction daemon",
        "callintelligenced": "Phone · Call intelligence daemon"
    ]

    // MARK: - Launch Item Descriptions (matched by substring)

    static let launchItemDescriptions: [String: String] = [
        // Adobe
        "adobe": "Adobe · Auto-start service for Creative Cloud apps",
        "com.adobe": "Adobe · Background service or updater",
        "adobegc": "Adobe · Genuine software verification",
        "adobearm": "Adobe · Adobe Reader update manager",
        "ccxprocess": "Adobe · Creative Cloud experience host",
        "adoberesourcesynchronizer": "Adobe · Cloud resource sync",
        // Google
        "google": "Google · Auto-update or sync service",
        "com.google": "Google · Background helper service",
        "keystone": "Google · Software update framework",
        "googledrive": "Google Drive · File sync service",
        // Cloud Storage
        "dropbox": "Dropbox · File sync auto-start",
        "com.dropbox": "Dropbox · Background sync service",
        "onedrive": "OneDrive · Microsoft cloud sync",
        "com.microsoft.onedrive": "OneDrive · Auto-update helper",
        "box": "Box · Cloud storage sync",
        // Communication
        "slack": "Slack · Auto-launch helper",
        "discord": "Discord · Auto-launch on login",
        "zoom": "Zoom · Auto-update service",
        "us.zoom": "Zoom · Meeting client helper",
        "teams": "Microsoft Teams · Background helper",
        "skype": "Skype · Auto-launch service",
        "telegram": "Telegram · Auto-launch helper",
        "signal": "Signal · Auto-launch service",
        "whatsapp": "WhatsApp · Desktop auto-start",
        // Spotify & Streaming
        "spotify": "Spotify · Auto-launch helper",
        "com.spotify": "Spotify · Background service",
        // CleanMyMac / MacPaw
        "macpaw": "CleanMyMac · Background cleanup agent",
        "cleanmymac": "CleanMyMac · System monitoring service",
        // Pro Audio
        "uaudio": "Universal Audio · Audio interface driver",
        "com.uaudio": "Universal Audio · Hardware helper service",
        "antelope": "Antelope Audio · Audio interface service",
        "waves": "Waves Audio · Plugin server",
        "com.waves": "Waves · Local licensing service",
        "pace": "iLok/PACE · License protection daemon",
        "com.paceap": "iLok/PACE · Software licensing service",
        "ilok": "iLok · License management",
        "native-instruments": "Native Instruments · Kontakt/NI helper",
        "com.native-instruments": "Native Instruments · Service center",
        "steinberg": "Steinberg · Cubase/Nuendo helper",
        "com.steinberg": "Steinberg · eLicenser service",
        "avid": "Avid · Pro Tools helper service",
        "com.avid": "Avid · Application manager",
        "digidesign": "Avid (Digidesign) · Legacy Pro Tools service",
        "focusrite": "Focusrite · Audio interface control",
        "presonus": "PreSonus · Audio interface helper",
        "motu": "MOTU · Audio interface service",
        "roland": "Roland · Roland Cloud service",
        "arturia": "Arturia · Software center helper",
        "izotope": "iZotope · Product portal helper",
        // Microsoft
        "microsoft": "Microsoft · Office auto-update or helper",
        "com.microsoft": "Microsoft · Background sync or updater",
        "office365": "Microsoft 365 · Subscription service",
        "mau": "Microsoft AutoUpdate · Update helper",
        // Developer Tools
        "docker": "Docker · Containerization daemon",
        "com.docker": "Docker · VM network helper",
        "jetbrains": "JetBrains · Toolbox auto-start",
        "com.jetbrains": "JetBrains · IDE helper service",
        "github": "GitHub · Desktop helper",
        "com.github": "GitHub · Credential helper",
        "sublime": "Sublime Text · Helper service",
        "vscode": "VS Code · Auto-update helper",
        // Design Tools
        "figma": "Figma · Font helper for local fonts",
        "sketch": "Sketch · Mirror or helper service",
        "com.bohemiancoding": "Sketch · Cloud sync helper",
        "invision": "InVision · Design sync helper",
        "zeplin": "Zeplin · Design handoff helper",
        // Password Managers
        "1password": "1Password · Browser helper",
        "com.agilebits": "1Password · Auto-lock service",
        "lastpass": "LastPass · Browser extension helper",
        "dashlane": "Dashlane · Auto-fill helper",
        "bitwarden": "Bitwarden · Desktop helper",
        // VPNs & Security
        "cloudflare": "Cloudflare WARP · VPN auto-start service",
        "adguard": "AdGuard · Ad-blocking helper service",
        "nordvpn": "NordVPN · VPN helper daemon",
        "expressvpn": "ExpressVPN · VPN auto-connect",
        "surfshark": "Surfshark · VPN helper service",
        "tunnelblick": "Tunnelblick · OpenVPN helper",
        "wireguard": "WireGuard · VPN tunnel service",
        "privateinternetaccess": "PIA · VPN daemon",
        "mullvad": "Mullvad · VPN service",
        "protonvpn": "ProtonVPN · VPN helper",
        "little-snitch": "Little Snitch · Network monitor",
        "com.obdev": "Little Snitch · Firewall helper",
        "lulu": "LuLu · Open-source firewall",
        // Backup & Utilities
        "backblaze": "Backblaze · Cloud backup service",
        "carbonite": "Carbonite · Backup agent",
        "crashplan": "CrashPlan · Backup daemon",
        "arq": "Arq · Backup scheduler",
        "chronosync": "ChronoSync · Sync scheduler",
        "istat": "iStat Menus · System monitor",
        "bartender": "Bartender · Menu bar organizer",
        "alfred": "Alfred · Launcher helper",
        "raycast": "Raycast · Launcher service",
        "karabiner": "Karabiner · Keyboard customizer",
        "bettertouchtool": "BetterTouchTool · Input customizer",
        "magnet": "Magnet · Window manager",
        "rectangle": "Rectangle · Window manager",
        "hammerspoon": "Hammerspoon · Automation helper",
        "keyboard-maestro": "Keyboard Maestro · Automation",
        // Browsers
        "brave": "Brave · Browser updater",
        "firefox": "Firefox · Background updater",
        "opera": "Opera · Browser helper",
        "vivaldi": "Vivaldi · Browser updater",
        "arc": "Arc · Browser helper"
    ]

    // MARK: - Kill List Targets

    static let bloatTargets = [
        // Adobe Creative Cloud
        "Adobe Desktop Service", "CCXProcess", "AdobeIPCBroker", "Core Sync", "CCLibrary",
        "Adobe Crash Reporter", "Adobe CEF Helper", "Creative Cloud", "AdobeCRDaemon",
        "Adobe Installer", "AdobeUpdateService", "Acrobat Update Service", "Adobe Callid",
        "AdobeCollabSync", "Creative Cloud Helper", "AdobeNotificationClient", "Adobe Content Synchronizer",
        "AdobeGCClient", "AdobeResourceSynchronizer", "LogTransport2", "armsvc", "AcroDist",
        "AdobeARM", "AcroTray", "AdobeExtensions", "AdobePDApp", "SparkIPC", "BeamSyncAgent", "AGSService",
        "ACCFinderSync", "Adobe Context Menu Extension", "Adobe Crash Processor",
        "com.adobe.acc.installer.v2",
        // Google
        "Google Software Update", "GoogleUpdater", "GoogleDriveFS", "Google Drive",
        "Keystone", "crashpad_handler",
        // Spotify
        "Spotify Helper", "SpotifyWebHelper",
        // Slack
        "Slack Helper", "Slack Helper (GPU)", "Slack Helper (Renderer)",
        // Discord
        "Discord Helper", "Discord Helper (GPU)", "Discord Helper (Renderer)",
        // Zoom
        "CptHost", "CapHost", "ZoomAutoUpdater",
        // Dropbox
        "Dropbox_start", "dbfseventsd", "DropboxMacUpdate",
        // OneDrive
        "OneDriveUpdater", "OneDriveStandaloneUpdater", "FileSyncHelper",
        // Box
        "Box Sync", "BoxDrive",
        // JetBrains
        "JetBrains Toolbox", "fsnotifier",
        // VS Code / Electron
        "Code Helper", "Code Helper (GPU)", "Code Helper (Renderer)", "Electron Helper",
        // Browsers (Helpers only, not main apps)
        "SafariBookmarksSyncAgent", "SafariLaunchAgent",
        // Design Tools
        "SketchMirrorHelper", "com.bohemiancoding.sketch3.helper", "figma_agent",
        // Productivity App Helpers
        "Notion Helper", "Evernote Helper",
        // CleanMyMac
        "CleanMyMac", "CleanMyMac X HealthMonitor", "CleanMyMac X Menu", "com.macpaw.CleanMyMac",
        "CleanMyMac_5_Menu", "CleanMyMac_5_HealthMonitor", "com.macpaw.CleanMyMac5.Agent",
        // Avid / Pro Tools
        "Avid Link", "AvidAppManHelper", "AvidBackgroundServices",
        "Digidesign Daemon", "Avid Application Manager",
        // User-trust tools such as password managers, VPNs, firewalls, and backup
        // agents are intentionally excluded from the default kill profile.
        // Audio Software & Licensing
        "com.uaudio.bsd.helper", "UA Mixer Engine", "UAD Meter & Control Panel", "Universal Audio",
        "UA Connect Launcher", "com.antelopeaudio.daemon", "AntelopeLauncher", "AntelopeManager",
        "WavesLocalServer", "WavesPluginServer", "WavesCentralHelper", "licenseDaemon",
        "iLokAssistant", "PACEProtectService", "Native Instruments", "NI Service Center",
        "KontaktServer", "RolandCloud", "iZotope", "Soundtoys", "Slate Digital",
        "FabFilter", "Spectrasonics", "Arturia", "Arturia Software Center",
        "FocusriteControl", "PreSonusDeviceMonitor", "MOTU Pro Audio Control",
        // Microsoft
        "ExcelWidget_mac", "WordWidget_mac", "PowerPointWidget_mac", "Microsoft AutoUpdate",
        "Microsoft Update Assistant", "Office365Service", "Teams Helper", "TeamsAuditService",
        // Developer Tools
        "SimulatorTrampoline", "CoreSimulatorService", "SourceKit", "com.docker.vmnetd",
        // Widgets (Apple)
        "CalendarWidgetExtension", "Notes.WidgetExtension", "PhotosReliveWidget", "PodcastsWidget",
        "RemindersWidgetExtension", "ShortcutsWidgetExtension", "StocksWidget", "TipsWidgetExtension",
        "RecordWidgetExtension", "FindMyWidgetItems", "FindMyWidgetPeople", "HomeWidget",
        "WeatherWidgetExtension", "NewsWidget", "BatteryHealthWidget", "MusicWidget",
        "HomeEnergyWidgetsExtension", "VoiceMemosSettingsWidgetExtension",
        "BatteriesAvocadoWidgetExtension", "WorldClockWidget", "WeatherWidget",
        "ScreenTimeWidgetExtension", "ScreenTimeWidgetIntentsExtension",
        "JournalWidgets", "JournalWidgetsSecure",
        // Misc
        "blender-thumbnailer", "simdiskimaged", "SimLaunchHost.arm64"
    ]

    static let intelligenceTargets = [
        "siriknowledged", "siriinferenced", "siriactionsd", "intelligenceplatformd",
        "intelligencecontextd", "generativeexperiencesd", "SiriTTSService", "suggestd",
        "coreduetd", "knowledge-agent", "biomed", "biomesyncd", "triald", "duetexpertd",
        "mediaanalysisd", "photoanalysisd", "mediaanalysisd-access", "spotlightknowledged",
        "CallIntelligence", "studentd", "amsengagementd", "BiomeAgent",
        "contextstored", "ContextStoreAgent", "IntelligencePlatformComputeService",
        "SAExtensionOrchestrator", "BiomeSELFIngestor", "intelligenceflowd",
        "intelligencetasksd", "knowledgeconstructiond", "callintelligenced"
    ]

    static let widgetBundleIDs = [
        "com.apple.Home.HomeWidget.Interactive",
        "com.apple.Home.HomeWidgetIntentsExtension",
        "com.apple.Home.HomeEnergyWidgets",
        "com.apple.DiagnosticExtensions.HomeEnergyDiagnosticExtension",
        "com.apple.VoiceMemos.VoiceMemosSettingsWidget",
        "com.apple.VoiceMemos.RecordWidget",
        "com.apple.findmy.FindMyWidgetPeople",
        "com.apple.findmy.FindMyWidgetItems",
        "com.apple.Batteries.BatteriesAvocadoWidgetExtension",
        "com.apple.clock.WorldClockWidget",
        "com.apple.weather.widget",
        "com.apple.ScreenTimeWidgetApplication.ScreenTimeWidgetExtension",
        "com.apple.ScreenTimeWidgetApplication.ScreenTimeWidgetIntentsExtension",
        "com.apple.podcasts.widget",
        "com.apple.journal.widgets",
        "com.apple.journal.widgets.secure",
        "com.apple.stocks.widget",
        "com.apple.tips.Widget",
        "com.apple.Notes.WidgetExtension",
        "com.apple.CalendarWidget.IntentsExtension",
        "com.apple.iCal.CalendarWidgetExtension",
        "com.apple.reminders.WidgetExtension",
        "com.apple.shortcuts.ShortcutsWidget",
        "com.apple.shortcuts.ShortcutLiveActivityWidget"
    ]

    static let extraWidgetExecutableNames = [
        "HomeEnergyWidgetsExtension",
        "VoiceMemosSettingsWidgetExtension",
        "BatteriesAvocadoWidgetExtension",
        "WorldClockWidget",
        "WeatherWidget",
        "ScreenTimeWidgetExtension",
        "ScreenTimeWidgetIntentsExtension",
        "JournalWidgets",
        "JournalWidgetsSecure"
    ]

    // MARK: - Launchd-Managed Processes

    static let launchdManagedProcesses: [String: LaunchdProcess] = [
        // Apple Intelligence & Siri
        "biomeagent": LaunchdProcess(
            label: "com.apple.BiomeAgent",
            plistPath: "/System/Library/LaunchAgents/com.apple.BiomeAgent.plist",
            processName: "BiomeAgent",
            isSystem: true,
            relatedLabels: ["com.apple.biomesyncd"]
        ),
        "contextstored": LaunchdProcess(
            label: "com.apple.contextstored",
            plistPath: "/System/Library/LaunchDaemons/com.apple.contextstored.plist",
            processName: "contextstored",
            isSystem: true,
            relatedLabels: []
        ),
        "contextstoreagent": LaunchdProcess(
            label: "com.apple.ContextStoreAgent",
            plistPath: "/System/Library/LaunchAgents/com.apple.ContextStoreAgent.plist",
            processName: "ContextStoreAgent",
            isSystem: true,
            relatedLabels: []
        ),
        "duetexpertd": LaunchdProcess(
            label: "com.apple.duetexpertd",
            plistPath: "/System/Library/LaunchAgents/com.apple.duetexpertd.plist",
            processName: "duetexpertd",
            isSystem: true,
            relatedLabels: ["com.apple.duetexpertd.ControlCenter", "com.apple.duetexpertd.SettingsActions"]
        ),
        "suggestd": LaunchdProcess(
            label: "com.apple.suggestd",
            plistPath: "/System/Library/LaunchAgents/com.apple.suggestd.plist",
            processName: "suggestd",
            isSystem: true,
            relatedLabels: [
                "com.apple.suggestd.deliveries", "com.apple.suggestd.ipsos",
                "com.apple.suggestd.fides", "com.apple.suggestd.events",
                "com.apple.suggestd.mail", "com.apple.suggestd.internal",
                "com.apple.suggestd.reminders", "com.apple.suggestd.messages",
                "com.apple.suggestd.contacts", "com.apple.suggestd.urls",
                "com.apple.suggestd.spotlightknowledged"
            ]
        ),
        "spotlightknowledged": LaunchdProcess(
            label: "com.apple.spotlightknowledged",
            plistPath: "/System/Library/LaunchAgents/com.apple.spotlightknowledged.plist",
            processName: "spotlightknowledged",
            isSystem: true,
            relatedLabels: [
                "com.apple.spotlightknowledged.updater",
                "com.apple.spotlightknowledged.importer"
            ]
        ),
        "siriknowledged": LaunchdProcess(
            label: "com.apple.siriknowledged",
            plistPath: "/System/Library/LaunchAgents/com.apple.siriknowledged.plist",
            processName: "siriknowledged",
            isSystem: true,
            relatedLabels: []
        ),
        "siriinferenced": LaunchdProcess(
            label: "com.apple.siriinferenced",
            plistPath: "/System/Library/LaunchAgents/com.apple.siriinferenced.plist",
            processName: "siriinferenced",
            isSystem: true,
            relatedLabels: []
        ),
        "intelligenceplatformd": LaunchdProcess(
            label: "com.apple.intelligenceplatformd",
            plistPath: "/System/Library/LaunchAgents/com.apple.intelligenceplatformd.plist",
            processName: "intelligenceplatformd",
            isSystem: true,
            relatedLabels: []
        ),
        "intelligenceflowd": LaunchdProcess(
            label: "com.apple.intelligenceflowd",
            plistPath: "/System/Library/LaunchAgents/com.apple.intelligenceflowd.plist",
            processName: "intelligenceflowd",
            isSystem: true,
            relatedLabels: []
        ),
        "intelligencetasksd": LaunchdProcess(
            label: "com.apple.intelligencetasksd",
            plistPath: "/System/Library/LaunchAgents/com.apple.intelligencetasksd.plist",
            processName: "intelligencetasksd",
            isSystem: true,
            relatedLabels: []
        ),
        "coreduetd": LaunchdProcess(
            label: "com.apple.coreduetd",
            plistPath: "/System/Library/LaunchDaemons/com.apple.coreduetd.plist",
            processName: "coreduetd",
            isSystem: true,
            relatedLabels: []
        ),
        "knowledgeconstructiond": LaunchdProcess(
            label: "com.apple.knowledgeconstructiond",
            plistPath: "/System/Library/LaunchAgents/com.apple.knowledgeconstructiond.plist",
            processName: "knowledgeconstructiond",
            isSystem: true,
            relatedLabels: []
        ),
        "callintelligenced": LaunchdProcess(
            label: "com.apple.callintelligenced",
            plistPath: "/System/Library/LaunchAgents/com.apple.callintelligenced.plist",
            processName: "callintelligenced",
            isSystem: true,
            relatedLabels: []
        ),
        "biomed": LaunchdProcess(
            label: "com.apple.biomed",
            plistPath: "/System/Library/LaunchAgents/com.apple.biomed.plist",
            processName: "biomed",
            isSystem: true,
            relatedLabels: []
        ),
        "triald": LaunchdProcess(
            label: "com.apple.triald",
            plistPath: "/System/Library/LaunchAgents/com.apple.triald.plist",
            processName: "triald",
            isSystem: true,
            relatedLabels: []
        ),
        "mediaanalysisd": LaunchdProcess(
            label: "com.apple.mediaanalysisd",
            plistPath: "/System/Library/LaunchAgents/com.apple.mediaanalysisd.plist",
            processName: "mediaanalysisd",
            isSystem: true,
            relatedLabels: []
        ),
        "photoanalysisd": LaunchdProcess(
            label: "com.apple.photoanalysisd",
            plistPath: "/System/Library/LaunchAgents/com.apple.photoanalysisd.plist",
            processName: "photoanalysisd",
            isSystem: true,
            relatedLabels: []
        ),
        // Third-party launchd-managed
        "licensedaemon": LaunchdProcess(
            label: "com.paceap.eden.licensed",
            plistPath: "/Library/LaunchDaemons/com.paceap.eden.licensed.plist",
            processName: "licenseDaemon",
            isSystem: false,
            relatedLabels: ["com.paceap.eden.licensed.agent"]
        ),
        // Adobe Services (LaunchAgents - user domain)
        "adobe desktop service": LaunchdProcess(
            label: "com.adobe.AdobeDesktopService",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeDesktopService.plist",
            processName: "Adobe Desktop Service",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeCreativeCloud", "com.adobe.ccxprocess", "com.adobe.acc.installer.v2"]
        ),
        "ccxprocess": LaunchdProcess(
            label: "com.adobe.ccxprocess",
            plistPath: "/Library/LaunchAgents/com.adobe.ccxprocess.plist",
            processName: "CCXProcess",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeCreativeCloud", "com.adobe.AdobeDesktopService"]
        ),
        "creative cloud": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "Creative Cloud",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeDesktopService", "com.adobe.ccxprocess"]
        ),
        "creative cloud helper": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "Creative Cloud Helper",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeDesktopService", "com.adobe.ccxprocess"]
        ),
        // Adobe child processes — map to parent LaunchAgent so disabling kills the whole tree
        "adobeipcbroker": LaunchdProcess(
            label: "com.adobe.AdobeDesktopService",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeDesktopService.plist",
            processName: "AdobeIPCBroker",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeCreativeCloud", "com.adobe.ccxprocess"]
        ),
        "cclibrary": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "CCLibrary",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeDesktopService"]
        ),
        "adobe cef helper": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "Adobe CEF Helper",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeDesktopService"]
        ),
        "adobecrdaemon": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "AdobeCRDaemon",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeDesktopService"]
        ),
        "adobe crash reporter": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "Adobe Crash Reporter",
            isSystem: false,
            relatedLabels: []
        ),
        "adobenotificationclient": LaunchdProcess(
            label: "com.adobe.AdobeDesktopService",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeDesktopService.plist",
            processName: "AdobeNotificationClient",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeCreativeCloud"]
        ),
        "logtransport2": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "LogTransport2",
            isSystem: false,
            relatedLabels: []
        ),
        "adobecollabsync": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "AdobeCollabSync",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeDesktopService"]
        ),
        "adobe content synchronizer": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "Adobe Content Synchronizer",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeDesktopService"]
        ),
        "adoberesourcesynchronizer": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "AdobeResourceSynchronizer",
            isSystem: false,
            relatedLabels: []
        ),
        "adobe installer": LaunchdProcess(
            label: "com.adobe.acc.installer.v2",
            plistPath: "/Library/LaunchDaemons/com.adobe.acc.installer.v2.plist",
            processName: "Adobe Installer",
            isSystem: false,
            relatedLabels: []
        ),
        "adobegcclient": LaunchdProcess(
            label: "com.adobe.GC.Invoker-1.0",
            plistPath: "/Library/LaunchAgents/com.adobe.GC.Invoker-1.0.plist",
            processName: "AdobeGCClient",
            isSystem: false,
            relatedLabels: ["com.adobe.GC.AGM"]
        ),
        "agsservice": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "AGSService",
            isSystem: false,
            relatedLabels: []
        ),
        "adobearm": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "AdobeARM",
            isSystem: false,
            relatedLabels: []
        ),
        "adobe callid": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "Adobe Callid",
            isSystem: false,
            relatedLabels: []
        ),
        "adobeupdateservice": LaunchdProcess(
            label: "com.adobe.acc.installer.v2",
            plistPath: "/Library/LaunchDaemons/com.adobe.acc.installer.v2.plist",
            processName: "AdobeUpdateService",
            isSystem: false,
            relatedLabels: []
        ),
        "acrobat update service": LaunchdProcess(
            label: "com.adobe.acc.installer.v2",
            plistPath: "/Library/LaunchDaemons/com.adobe.acc.installer.v2.plist",
            processName: "Acrobat Update Service",
            isSystem: false,
            relatedLabels: []
        ),
        "core sync": LaunchdProcess(
            label: "com.adobe.AdobeDesktopService",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeDesktopService.plist",
            processName: "Core Sync",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeCreativeCloud"]
        ),
        "accfindersync": LaunchdProcess(
            label: "com.adobe.AdobeDesktopService",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeDesktopService.plist",
            processName: "ACCFinderSync",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeCreativeCloud", "com.adobe.CoreSync.helper"]
        ),
        "adobe context menu extension": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "Adobe Context Menu Extension",
            isSystem: false,
            relatedLabels: ["com.adobe.AdobeDesktopService"]
        ),
        "adobe crash processor": LaunchdProcess(
            label: "com.adobe.AdobeCreativeCloud",
            plistPath: "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist",
            processName: "Adobe Crash Processor",
            isSystem: false,
            relatedLabels: []
        ),
        "com.adobe.acc.installer.v2": LaunchdProcess(
            label: "com.adobe.acc.installer.v2",
            plistPath: "/Library/LaunchDaemons/com.adobe.acc.installer.v2.plist",
            processName: "com.adobe.acc.installer.v2",
            isSystem: false,
            relatedLabels: []
        ),
        // Google Services
        "keystone": LaunchdProcess(
            label: "com.google.keystone.agent",
            plistPath: "~/Library/LaunchAgents/com.google.keystone.agent.plist",
            processName: "Keystone",
            isSystem: false,
            relatedLabels: ["com.google.keystone.daemon"]
        ),
        "google software update": LaunchdProcess(
            label: "com.google.keystone.agent",
            plistPath: "~/Library/LaunchAgents/com.google.keystone.agent.plist",
            processName: "Google Software Update",
            isSystem: false,
            relatedLabels: []
        ),
        "googledrivefs": LaunchdProcess(
            label: "com.google.drivefs.helper",
            plistPath: "~/Library/LaunchAgents/com.google.drivefs.helper.plist",
            processName: "GoogleDriveFS",
            isSystem: false,
            relatedLabels: []
        ),
        // Dropbox
        "dropbox": LaunchdProcess(
            label: "com.dropbox.DropboxMacUpdate.agent",
            plistPath: "~/Library/LaunchAgents/com.dropbox.DropboxMacUpdate.agent.plist",
            processName: "Dropbox",
            isSystem: false,
            relatedLabels: ["com.getdropbox.dropbox"]
        ),
        // Microsoft
        "microsoft autoupdate": LaunchdProcess(
            label: "com.microsoft.update.agent",
            plistPath: "/Library/LaunchAgents/com.microsoft.update.agent.plist",
            processName: "Microsoft AutoUpdate",
            isSystem: false,
            relatedLabels: ["com.microsoft.autoupdate.helper"]
        ),
        "onedriveupdater": LaunchdProcess(
            label: "com.microsoft.OneDriveUpdaterDaemon",
            plistPath: "/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist",
            processName: "OneDriveUpdater",
            isSystem: false,
            relatedLabels: []
        ),
        "office365service": LaunchdProcess(
            label: "com.microsoft.office.licensing.helper",
            plistPath: "/Library/LaunchDaemons/com.microsoft.office.licensing.helper.plist",
            processName: "Office365Service",
            isSystem: false,
            relatedLabels: []
        ),
        // Spotify
        "spotify helper": LaunchdProcess(
            label: "com.spotify.webhelper",
            plistPath: "~/Library/LaunchAgents/com.spotify.webhelper.plist",
            processName: "Spotify Helper",
            isSystem: false,
            relatedLabels: []
        ),
        // Zoom
        "zoomautoupdater": LaunchdProcess(
            label: "us.zoom.ZoomDaemon",
            plistPath: "/Library/LaunchDaemons/us.zoom.ZoomDaemon.plist",
            processName: "ZoomAutoUpdater",
            isSystem: false,
            relatedLabels: []
        ),
        // Docker
        "com.docker.vmnetd": LaunchdProcess(
            label: "com.docker.vmnetd",
            plistPath: "/Library/LaunchDaemons/com.docker.vmnetd.plist",
            processName: "com.docker.vmnetd",
            isSystem: false,
            relatedLabels: ["com.docker.socket"]
        ),
        // JetBrains
        "jetbrains toolbox": LaunchdProcess(
            label: "com.jetbrains.toolbox",
            plistPath: "~/Library/LaunchAgents/com.jetbrains.toolbox.plist",
            processName: "JetBrains Toolbox",
            isSystem: false,
            relatedLabels: []
        ),
        // Universal Audio
        "com.uaudio.bsd.helper": LaunchdProcess(
            label: "com.uaudio.bsd.helper",
            plistPath: "/Library/LaunchDaemons/com.uaudio.bsd.helper.plist",
            processName: "com.uaudio.bsd.helper",
            isSystem: false,
            relatedLabels: []
        ),
        "ua connect launcher": LaunchdProcess(
            label: "com.uaudio.UAConnectLauncher",
            plistPath: "~/Library/LaunchAgents/com.uaudio.UAConnectLauncher.plist",
            processName: "UA Connect Launcher",
            isSystem: false,
            relatedLabels: []
        ),
        // Waves Audio
        "waveslocalserver": LaunchdProcess(
            label: "com.waves.WavesLocalServer",
            plistPath: "~/Library/LaunchAgents/com.waves.WavesLocalServer.plist",
            processName: "WavesLocalServer",
            isSystem: false,
            relatedLabels: ["com.waves.MaxxAudioAgent"]
        ),
        // Antelope Audio
        "com.antelopeaudio.daemon": LaunchdProcess(
            label: "com.antelopeaudio.AFXDaemon",
            plistPath: "/Library/LaunchDaemons/com.antelopeaudio.AFXDaemon.plist",
            processName: "com.antelopeaudio.daemon",
            isSystem: false,
            relatedLabels: []
        ),
        // CleanMyMac / MacPaw
        "cleanmymac": LaunchdProcess(
            label: "com.macpaw.CleanMyMac4.Agent",
            plistPath: "~/Library/LaunchAgents/com.macpaw.CleanMyMac4.Agent.plist",
            processName: "CleanMyMac",
            isSystem: false,
            relatedLabels: ["com.macpaw.CleanMyMac4.HealthMonitor", "com.macpaw.CleanMyMac4.Menu"]
        ),
        // Avid Pro Tools
        "avid link": LaunchdProcess(
            label: "com.avid.avidlink.AvidLinkService",
            plistPath: "~/Library/LaunchAgents/com.avid.avidlink.AvidLinkService.plist",
            processName: "Avid Link",
            isSystem: false,
            relatedLabels: []
        )
    ]

    // MARK: - Vendor Pattern Matching

    static let vendorPatterns: [String: [String]] = [
        // Creative Software
        "Adobe": ["adobe", "ccx", "acrobat", "creative cloud", "acrob", "logtransport", "armsvc", "sparkipc", "beamsync", "ags"],
        "Autodesk": ["autodesk", "maya", "autocad", "fusion", "adsk", "adp"],
        "Blender": ["blender"],
        // Cloud Storage
        "Google": ["google", "keystone", "crashpad", "gdrive", "googledrive"],
        "Dropbox": ["dropbox", "dbfsevent"],
        "OneDrive": ["onedrive", "filesync"],
        "Box": ["box sync", "boxdrive"],
        // Communication
        "Slack": ["slack"],
        "Discord": ["discord"],
        "Zoom": ["zoom", "cpthost", "caphost"],
        "Microsoft Teams": ["teams"],
        // Microsoft
        "Microsoft": ["microsoft", "office", "excel", "word", "powerpoint"],
        // Apple
        "Apple": [
            "calendar", "notes", "photos", "podcasts", "reminders", "shortcuts", "stocks", "tips", "findmy",
            "home", "siri", "intelligence", "spotlight", "biome", "duet", "media", "knowledge", "student",
            "ams", "safari", "weather", "news", "battery", "music", "record"
        ],
        // Audio & Pro Audio
        "Universal Audio": ["uaudio", "ua connect", "ua mixer", "uad"],
        "Avid": ["avid", "digidesign"],
        "Waves": ["waves"],
        "Native Instruments": ["native instruments", "ni service", "kontakt"],
        "Steinberg": ["steinberg", "cubase", "nuendo", "dorico", "halion"],
        "iLok/PACE": ["licensedaemon", "ilok", "pace"],
        "Antelope": ["antelope"],
        "Focusrite": ["focusrite"],
        "PreSonus": ["presonus"],
        "MOTU": ["motu"],
        "Roland": ["roland"],
        "iZotope": ["izotope"],
        "Soundtoys": ["soundtoys"],
        "Slate Digital": ["slate digital"],
        "FabFilter": ["fabfilter"],
        "Spectrasonics": ["spectrasonics"],
        "Arturia": ["arturia"],
        // Streaming
        "Spotify": ["spotify"],
        // Developer Tools
        "JetBrains": ["jetbrains", "fsnotifier"],
        "VS Code": ["code helper"],
        "Electron": ["electron helper"],
        "Docker": ["docker"],
        "Xcode": ["simulator", "sourcekit", "coresimulator"],
        // Design
        "Figma": ["figma"],
        "Sketch": ["sketch", "bohemiancoding"],
        // Productivity
        "Notion": ["notion"],
        "Evernote": ["evernote"],
        // System Utilities
        "CleanMyMac": ["cleanmymac", "macpaw"]
    ]

    // MARK: - Launch Item Scan Keywords

    static let launchItemKeywords = [
        // Creative Software
        "adobe", "autodesk", "maxon",
        // Cloud Storage
        "google", "dropbox", "onedrive", "box", "icloud",
        // Communication
        "slack", "discord", "zoom", "teams", "skype", "telegram", "signal", "whatsapp",
        // Streaming
        "spotify", "deezer",
        // Utilities
        "macpaw", "cleanmymac", "ccleaner",
        // Pro Audio
        "uaudio", "antelope", "waves", "pace", "ilok", "native-instruments", "steinberg",
        "avid", "digidesign", "focusrite", "presonus", "motu", "roland", "arturia", "izotope",
        // Microsoft
        "microsoft", "office365",
        // Developer Tools
        "docker", "jetbrains", "github", "sublime", "vscode",
        // Design
        "figma", "sketch", "bohemiancoding", "invision", "zeplin",
        // Password managers, VPNs, firewalls, and backup tools are not shown by default.
        // System Utilities
        "istat", "bartender", "alfred", "raycast", "karabiner", "bettertouchtool",
        "magnet", "rectangle", "hammerspoon", "keyboard-maestro",
        // Browsers
        "brave", "firefox", "opera", "vivaldi", "arc"
    ]
}
