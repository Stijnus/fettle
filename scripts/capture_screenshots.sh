#!/bin/bash
# Capture the README screenshots from the built app.
#
# The app has a hidden --ui-preview mode (Fettle/Support/HealthProbe.swift) that
# renders a real window to a PNG. This script drives it once per screen, in
# English and light appearance, then frames the captures and redraws the brand
# assets with scripts/readme_art.py.
#
# Login Items and Maintenance are captured against a disposable sample home
# (FETTLE_HOME) so the published screenshots never show a real account's app
# names or paths. Every other screen is the real Mac.
#
# Requirements: a built build/Fettle.app, a logged-in GUI session, Python 3 with
# Pillow. Settings are backed up and restored, so your own appearance, language
# and last-scan values survive a run.
#
# Usage:
#   ./scripts/capture_screenshots.sh          # capture everything
#   ./scripts/capture_screenshots.sh overview # capture one screen
#
# Delays are generous because scans read the real Mac. A full run takes a few
# minutes; the Trash and the app-update check dominate it.

set -u
cd "$(dirname "$0")/.." || exit 1

APP="build/Fettle.app/Contents/MacOS/Fettle"
RAW="${RAW_DIR:-/tmp/fettle-screenshots}"; RAW="${RAW%/}"
OUT="docs/screenshots"
BUNDLE_ID="com.fettle.app"
REQUEST="/tmp/fettle-preview-request.json"   # fixed by AppPreview.installIfRequested()
DEMO_HOME="${TMPDIR:-/tmp}"; DEMO_HOME="$(cd "$DEMO_HOME" && pwd -P)/fettle-demo-home"

if [ ! -x "$APP" ]; then
    echo "Build the app first: make" >&2
    exit 1
fi

# name | home | request JSON (without output). home is "real" or "demo".
SCREENS="
overview|real|{\"module\":\"overview\",\"scan\":true,\"delay\":50}
disk-cleanup|real|{\"module\":\"disk\",\"scan\":true,\"delay\":45}
maintenance|demo|{\"module\":\"maintenance\",\"scan\":true,\"delay\":10}
uninstaller|real|{\"module\":\"uninstaller\",\"scan\":true,\"delay\":25}
app-updater|real|{\"module\":\"updater\",\"scan\":true,\"delay\":38}
app-updater-review|real|{\"module\":\"updater\",\"scan\":true,\"review\":true,\"sheet\":true,\"delay\":42}
extensions|real|{\"module\":\"extensions\",\"scan\":true,\"delay\":8}
login-items|demo|{\"module\":\"loginItems\",\"scan\":true,\"delay\":12}
privacy|real|{\"module\":\"privacy\",\"scan\":true,\"delay\":14}
sleep-power|real|{\"module\":\"power\",\"delay\":6}
security|real|{\"module\":\"security\",\"delay\":7}
permanent-delete|real|{\"module\":\"permanentDelete\",\"delay\":6}
mac-health|real|{\"module\":\"health\",\"page\":\"overview\",\"delay\":9}
cpu|real|{\"module\":\"health\",\"page\":\"cpu\",\"delay\":8}
memory|real|{\"module\":\"health\",\"page\":\"memory\",\"delay\":8}
disk-health|real|{\"module\":\"health\",\"page\":\"disk\",\"delay\":8}
battery|real|{\"module\":\"health\",\"page\":\"battery\",\"delay\":8}
network|real|{\"module\":\"health\",\"page\":\"network\",\"delay\":8}
activity|real|{\"module\":\"health\",\"page\":\"activity\",\"delay\":8}
settings|real|{\"settings\":true,\"settingsTab\":\"general\",\"delay\":6}
menu-bar|real|{\"menuBar\":true,\"delay\":8}
"

mkdir -p "$RAW" "$OUT"

# A tiny, believable account: user LaunchAgents (two with a broken definition,
# two valid), and three app identifiers that left preferences behind. Nothing
# here exists on the machine and nothing is outside the demo folder.
make_demo_home() {
    rm -rf "$DEMO_HOME"
    mkdir -p "$DEMO_HOME/Library/LaunchAgents" "$DEMO_HOME/Library/Preferences" \
             "$DEMO_HOME/Library/HTTPStorages" "$DEMO_HOME/Library/Application Support" \
             "$DEMO_HOME/Library/Caches"

    write_agent() {
        cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
$2
</dict></plist>
PLIST
    }
    write_agent "$DEMO_HOME/Library/LaunchAgents/com.acme.helper.plist" \
        '  <key>Label</key><string>com.acme.helper</string>
  <key>Program</key><string>/usr/bin/open</string>'
    write_agent "$DEMO_HOME/Library/LaunchAgents/com.example.backup-sync.plist" \
        '  <key>Label</key><string>com.example.backup-sync</string>
  <key>ProgramArguments</key><array><string>/usr/bin/rsync</string><string>--version</string></array>'
    write_agent "$DEMO_HOME/Library/LaunchAgents/com.example.photo-import.plist" \
        '  <key>Label</key><string>com.example.photo-import</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>-lc</string><string>echo import</string></array>'
    # No Label, so it cannot start.
    write_agent "$DEMO_HOME/Library/LaunchAgents/com.example.legacy-agent.plist" \
        '  <key>ProgramArguments</key><array><string>/bin/sh</string></array>'
    # Points at an app that is no longer installed.
    write_agent "$DEMO_HOME/Library/LaunchAgents/com.example.old-updater.plist" \
        '  <key>Label</key><string>com.example.old-updater</string>
  <key>Program</key><string>/Applications/Example Updater.app/Contents/MacOS/ExampleUpdater</string>'

    for id in com.example.old-editor com.example.legacy-notes com.acme.photo-tools; do
        cat > "$DEMO_HOME/Library/Preferences/$id.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>LastWindow</key><string>main</string></dict></plist>
PLIST
        mkdir -p "$DEMO_HOME/Library/HTTPStorages/$id"
        printf 'demo' > "$DEMO_HOME/Library/HTTPStorages/$id/data"
    done
    mkdir -p "$DEMO_HOME/Library/Caches/com.example.legacy-notes"
    printf 'cache' > "$DEMO_HOME/Library/Caches/com.example.legacy-notes/blob"
    mkdir -p "$DEMO_HOME/Library/Application Support/com.acme.photo-tools"
    printf 'state' > "$DEMO_HOME/Library/Application Support/com.acme.photo-tools/state.json"
}

backup="/tmp/fettle-defaults-backup.plist"
defaults export "$BUNDLE_ID" "$backup" 2>/dev/null

restore() {
    pkill -f "Fettle.app/Contents/MacOS/Fettle" 2>/dev/null
    if [ -f "$backup" ]; then
        defaults delete "$BUNDLE_ID" 2>/dev/null
        defaults import "$BUNDLE_ID" "$backup" 2>/dev/null
        rm -f "$backup"
    fi
    rm -rf "$DEMO_HOME"
}
trap restore EXIT INT TERM

capture() {
    local name="$1" spec="$2" home="${3:-real}" out="$RAW/$1.png" envs=()
    rm -f "$out"
    pkill -f "Fettle.app/Contents/MacOS/Fettle" 2>/dev/null
    for _ in $(seq 1 40); do
        pgrep -f "Fettle.app/Contents/MacOS/Fettle" >/dev/null || break
        sleep 0.25
    done
    pkill -9 -f "Fettle.app/Contents/MacOS/Fettle" 2>/dev/null
    sleep 0.4

    python3 - "$spec" "$out" "$REQUEST" <<'PY'
import json, sys
spec = json.loads(sys.argv[1])
spec["output"] = sys.argv[2]
open(sys.argv[3], "w").write(json.dumps(spec))
PY
    local delay
    delay=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("delay",6))' "$spec")

    if [ "$home" = "demo" ]; then
        envs=(FETTLE_HOME="$DEMO_HOME")
    fi
    env ${envs[@]+"${envs[@]}"} FETTLE_LANG=english FETTLE_APPEARANCE=light "$APP" --ui-preview >/dev/null 2>&1 &
    local pid=$!
    for _ in $(seq 1 $((delay + 30))); do
        [ -f "$out" ] && { sleep 0.4; break; }
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    pkill -f "Fettle.app/Contents/MacOS/Fettle" 2>/dev/null
    sleep 0.3
    if [ -f "$out" ]; then
        printf '  %-20s ok\n' "$name"
    else
        printf '  %-20s FAILED\n' "$name"
        return 1
    fi
}

make_demo_home

only="${1:-}"
failed=0
while IFS='|' read -r name home spec; do
    [ -z "$name" ] && continue
    if [ -n "$only" ] && [ "$only" != "$name" ]; then continue; fi
    capture "$name" "$spec" "$home" || failed=1
done <<< "$SCREENS"

if [ -n "$only" ]; then
    exit "$failed"
fi

if [ "$failed" -ne 0 ]; then
    echo "Some captures failed; keeping the raw files in $RAW" >&2
    exit 1
fi

python3 scripts/readme_art.py screenshots "$RAW" "$OUT"
python3 scripts/readme_art.py brand \
    Fettle/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png docs/brand "$OUT"
echo "Updated $OUT and docs/brand"
