# Fettle feature matrix

This matrix lists each Fettle module, what runs inside the app, what opens a
system or browser surface, and what was verified in this build.

Legend for **Verified**:
- **Automated** – covered by `--self-test` and/or `--integration-test` with
  disposable fixtures.
- **Live scan** – exercised on this Mac during development with real, read-only
  scans.
- **UI reviewed** – light/dark and English/Dutch builds were inspected as
  rendered windows.
- **Live probe** – `--health-probe` read real values on this Mac.
- **UI preview** – rendered the real window contents in light and dark.
- **Not exercised** – implemented, but no safe/available fixture was used.

## Core modules

| Module | Fettle implementation | Runs in app | Opens system/browser surface | Verified |
|---|---|---|---|---|
| Disk Cleanup | Scans `~/Library/Caches`, `~/Library/Logs`, user DiagnosticReports/CrashReporter and recognised temporary files; groups by category/location; Trash is a separate category; large-file scan for user-chosen folders; per-item selection, ignore list, reveal in Finder, move to Trash; separate Empty Trash; skipped list with reasons. Backups, app bundles, personal document folders and system caches are excluded. | Scan, select, ignore, reveal, move to Trash, Empty Trash, large-file scan, external-drive scan | Finder | Automated (scan, ignore, change detection, symlinks, move/empty); live scan (158 real items); UI reviewed |
| Maintenance | Finds broken user-owned symlinks/Finder aliases, invalid personal LaunchAgents (relative programs resolved against `WorkingDirectory`; no program is broken, a missing path is broken unless an installed app owns it, and an existing file is never flagged for its executable bit), broken preference property lists, and leftovers from removed apps. Evidence is shown per finding. Confirmed leftovers require an unowned bundle identifier in at least two standard locations; single-location matches and helper/updater components stay informational, and an installed app from the same vendor suppresses the finding. Repairs move the affected user file to the Trash. | Scan, select, repair, reveal, ignore | Finder | Automated (aliases, LaunchAgents, broken preferences, leftovers, repair); UI reviewed |
| Uninstaller | Lists apps from `/Applications`, `~/Applications` and user-added folders; version, bundle ID, size, source, running state, access errors. Associations matched exactly by bundle identifier (caches, logs, preferences, app support, saved state, containers, WebKit, HTTPStorages, cookies, scripts, LaunchAgents, `SDMHelpData/Other`, Adobe AIR `ELS`). App data is flagged; shared containers are excluded. Multi-app review, running-app quit, vendor uninstaller opening, rescan, and a separate confirmed-leftover scan. | Scan, multi-select, review, quit app, open vendor uninstaller, move app/files to Trash, leftover scan | Finder for reveal | Automated (exact matching, app-data flag, removal); live scan (39 apps); UI reviewed |
| App Updater | Lists installed apps from the same roots as the Uninstaller. For each app it reads `SUFeedURL` and the app's own Sparkle appcast, compares versions component by component, and offers the newest compatible item with release date, size and notes. Mac App Store apps (recognised by `_MASReceipt`) are routed to the App Store; Apple apps are routed to Software Update; apps without a feed are reported honestly. A Review sheet selects which update pages to open. Fettle never downloads or executes an installer. | Scan, select, review, open the vendor page/store/Software Update, copy link, reveal, ignore | Vendor download page, App Store, System Settings → General → Software Update | Automated (appcast parse, version ordering, Sparkle/App Store/Apple detection, ignore, cancellation); live scan (39 apps; 0 updates, 1 App Store, 2 Apple); UI preview (light/dark, English/Dutch) |
| Sleep & Power | Reads `pmset -g custom`, `pmset -g batt` and swap usage. Shows battery and adapter values, only meaningful differences, all settings and sleep/recovery files. Read-only, with a direct link to the live Battery page in Mac Health. | Refresh | Battery Settings; Energy Saver (falls back to Battery); Mac Health | Automated (parser); live read; UI reviewed |
| Extensions | `systemextensionsctl list` for system extensions; `pluginkit` plus bundled `.appex` metadata for Safari extensions; Chrome/Edge/Opera profiles and Firefox `extensions.json` for browser add-ons. Shows provider, host, version and enabled state when available. No direct toggles because macOS/browsers do not expose one to third-party apps. | Scan, open the supported management surface | Login Items & Extensions; Safari; `chrome://extensions`, `edge://extensions`, `opera://extensions`, `about:addons` | Automated (Chromium manifest/state); live system-extension scan; UI reviewed |
| Login Items & Background Activity | User LaunchAgents from `~/Library/LaunchAgents`, parsed for label/program and status via `launchctl`; reversible `launchctl disable`/`bootout` and `enable`/`bootstrap`. Background items via `sfltool dumpbtm`, shown read-only as system-managed. System daemons outside scope. | Scan, enable/disable user agents | Login Items & Extensions | Automated (parsing); live scan (4 user agents, 2 loaded); toggles not executed on the test Mac to avoid changing its login state |
| Privacy Cleanup | Browser/profile/category results for Safari, Chrome, Edge, Opera and Firefox: cache, cookies, site data, browsing history, download history. Requires the browser to be quit for cookies/history; marks those protected while running. Download records are cleared while downloaded files stay; Safari `Downloads.plist` is rewritten as a valid empty list; Chromium/Firefox use their SQLite databases. Recent items are summarised and routed to Finder/System Settings. Passwords never read. | Scan, select, clear selected; quit browser | Password settings in each browser/System Settings; Finder; Desktop & Dock | Automated (scan, download preservation, Safari plist); live scan; UI reviewed |
| Permanent Delete | Separate drag-and-drop/file-picker screen. Exact paths and sizes, bypasses Trash, typed confirmation, per-item results. Refuses system roots, applications, the home folder, its own bundle and protected user data. Symlinks are deleted as links. | Add, review, permanently delete | Finder for reveal | Automated (file/folder deletion, symlink target preservation, protected path refusal); integration test; UI reviewed |

## Overview and preferences

| Preference / surface | Implementation | Verified |
|---|---|---|
| Overview | Disk usage, live Mac Health strip, persisted last scan, module summaries, Cleanup/Activity history tabs, one Scan action, and separate estimated-removable / moved-to-Trash / actual-free-space metrics (Empty Trash and Permanent Delete are not counted as moved to Trash) | UI reviewed; global scan logic reviewed |
| Ignore list | Persistent JSON in `~/Library/Application Support/Fettle`; editable in Settings and from scan results; scans skip matching paths | Automated persistence; UI reviewed |
| Cleanup reminders | Opt-in local notification, 3/7/14/30-day schedule with a weekly default, plus an opt-in low disk space alert at the nearest 10%-of-free-space threshold or a fixed 2–100 GB value | Permission flow implemented; delivery not exercised (needs user permission) |
| Trash reminder | Opt-in threshold; 11 values from 500 MB to 100 GB, defaulting to 2 GB, checked after scans and scheduled | Implemented; delivery not exercised |
| Notifications and sound | Permission request, sound on/off and named system sound; preview button | UI reviewed; sound selection implemented |
| External-drive prompt | Opt-in prompt on `NSWorkspace.didMountNotification`; review-first external scan | Implemented; no physical external drive was attached for this build |
| Appearance | System / light / dark, applied to SwiftUI and the window chrome | UI reviewed in light and dark |
| Language | English and Dutch interface strings built in; follows system by default | Automated string resolution; UI reviewed in both languages |
| Updates | Manual check and optional daily check for Fettle itself; Ed25519 signature over version/build/URL/SHA-256; opens download page only. Separate opt-in daily app-update check and an opt-in “include app updates in Scan”; App Updater is manual by default | Automated signature accept/reject test; updater appcast parsing/status tests; release packaging can embed the feed URL and verification key using FETTLE_FEED_KEY_FILE |
| About | Original branding, version, local-first principles, attribution | UI reviewed |
| Help & Safety | Safety model, keyboard shortcuts, limitations, permissions and permanent-delete caveats | UI reviewed |
| Cleanup history | Local JSON, 200 events, newest first; clear confirmation | Automated persistence; UI reviewed |
| App permission handling | Usage descriptions for Desktop/Documents/Downloads/removable volumes; no admin prompts | Build and live scans verified |

## Mac Health, menu bar and live activity

| Surface | Implementation | Runs in app | Opens system surface | Verified |
|---|---|---|---|---|
| Mac Health overview | Six live pages (CPU, Memory, Disk, Battery, Network, Activity) plus an overview. Readings come from Mach/IOKit, `getifaddrs`, `netstat`, `ioreg`, `diskutil`, `system_profiler` and `pmset`. Trends, status colours and alert cards are computed locally. | Live sampling, pause/resume, refresh, paging | — | Live probe (CPU, memory, volumes, SMART, battery, network, processes); UI preview in light/dark |
| Memory page | `vm_statistics64` for active/wired/compressed/cached/free, `kern.memorystatus_vm_pressure_level` for pressure, `vm.swapusage` for swap. Top memory users come from `proc_pid_rusage` with a resident-size fallback. | Quit Selected Apps review; quit selected apps | Activity Monitor | Automated (parsers, history); integration (Quit Selected Apps on a disposable process); UI preview |
| CPU page | `host_processor_info` deltas, load average, per-core bars, top CPU from `proc_pid_rusage` deltas. Buttons for Quit and Force Quit with identity revalidation. | Quit, force quit, all-processes sheet, responsiveness check | Accessibility settings (opt-in) | Integration (quit/force quit of disposable processes); UI preview; Accessibility path not exercised because permission was not granted |
| Disk page | Mounted-volume list via `FileManager`/`statfs`; APFS physical-store mapping and SMART details via `diskutil info -plist`; I/O rates from `IOBlockStorageDriver` statistics; free-space trend. | Refresh, reveal, Eject All | Disk Utility | Live probe (Apple SSD SMART Verified, 4% wear, 1268 h, 391 cycles); integration (Eject All on a disposable APFS disk image); UI preview |
| Battery page | IOKit power-source descriptions for charge/charging/time; `system_profiler` for condition and maximum capacity; `ioreg` for cycles, voltage and adapter details. | Refresh, open settings | Battery Settings; Sleep & Power | Live probe (29%/86% health/278 cycles/Normal); UI preview |
| Network page | `getifaddrs` for addresses, `netstat -ib` for counters, `route` for the primary interface, `networksetup` for hardware-port names; rates computed between readings. | Refresh, open settings | Network Settings | Live probe (en0, IP, totals, rates); UI preview |
| Activity page | Numeric sample every 60 s, retained seven days (10,080 samples max) in `health-history.json`. 1 h/24 h/7 d ranges and a reporting table. Never stores process names or paths. | Clear history, range and metric pickers | — | Automated (persistence/pruning/clear); UI preview; history observed across launches |
| Alerts | Six live alert kinds: memory pressure, sustained high CPU, low disk, large Trash, external drive, drive health. In-app cards always show; notifications are gated by permission and alert toggles. Cooldowns prevent repeats. | Alert cards, threshold settings | Notification settings | Automated (synthetic snapshot for all six kinds); notifications not delivered because permission was not granted |
| Menu bar popover | `NSStatusItem` + `NSPopover`: live CPU/memory/disk/network, battery/drive/busiest-process summary, alerts, Scan, Quit Selected Apps, Eject All, Settings, Open Fettle and Quit. Optional CPU percentage in the title. | All quick actions | Settings, System Settings | UI preview in light/dark; Settings action exercised through the menu item; Eject All and Quit Selected Apps exercised through the models |
| Background mode | Closing the window leaves the app running when enabled; `showMainWindow` reopens it through the SwiftUI window action. | Toggle, reopen | — | Verified: preview closed the only window and reopened it |
| Open at Login | `SMAppService.mainApp.register()`/`unregister()` with status reporting. | Toggle, status, open Login Items settings | System Settings → Login Items & Extensions | Verified registration and unregistration with a disposable probe; no item left registered |
| Health settings | Monitoring and sample interval, activity-history retention, menu bar visibility/CPU title, background mode, six alert choices, CPU threshold, notification/sound controls. | All settings | — | UI preview; persistence via `UserDefaults` |

## macOS limits and routes

| Limit | Fettle behaviour |
|---|---|
| Full Disk Access required for some Safari/Background Task Management data | Never requested automatically; reported read failures mark the scan partial and identify the skipped path |
| System extensions, background items and macOS login items | Open System Settings → General → Login Items & Extensions; no third-party toggle |
| Browser add-ons | Open the browser's own extensions page; no direct enable/disable |
| App updates | A vendor update is only offered when the app publishes a readable Sparkle appcast. App Store and Apple apps are routed to their supported pages. Fettle never downloads or runs an installer, so the vendor or store still finishes the update. |
| Finder recent items | No public clearing API; routes to Finder and Desktop & Dock, and explains Apple menu → Recent Items → Clear Menu |
| Browser passwords | Never scanned; "Passwords & credentials" opens the browser/System Settings surface |
| Active browser profiles | History/cookies are marked protected until the browser is quit and the scan repeated |
| Emptying Trash | Separate action with its own confirmation; never part of routine cleanup |
| Permanent deletion | Bypasses Trash; cannot defeat SSD wear levelling, APFS snapshots, Time Machine or cloud copies |
| macOS background item dump (`sfltool`) | User LaunchAgents appear while the background query runs; a timeout offers a retry even when no agents exist |
| System-wide memory purge | Requires administrator rights; Fettle does not request them. Quit Selected Apps asks selected apps to quit instead. |
| App responsiveness | Uses the Accessibility API with a short timeout; requires the user to grant Accessibility. Without it, only apps that have not finished launching are reported. |
| SMART on external drives | Depends on the drive/enclosure; "Not supported" means unavailable, not failing. |
| Network counters | Since boot; may wrap after very long uptime. Rates restart after counter resets, absent interfaces, or sampling gaps of a minute or more. |
| Open at Login | Registration is handled by macOS. A rebuilt or moved app may need to be registered again; Fettle reports the exact status and never leaves an item it did not register. |
| Health notifications | Local notifications require the user's permission; in-app alert cards work without it. |
| App distribution | Ad-hoc signed for local use; not notarised |
