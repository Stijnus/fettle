# Fettle

> *In fine fettle* — in good health and good condition.

Fettle is a native macOS care utility: disk cleanup, maintenance, an
uninstaller, an app updater, privacy cleanup and live Mac Health monitoring in
one app. It is built with Swift, SwiftUI and AppKit, targets Apple silicon, and
keeps every scan on the Mac. The only network requests are update checks:
Fettle's own release feed, and, when you run App Updater, each installed app's
own update feed. No scan data is sent.

## Contents

- [Requirements](#requirements) · [Build](#build) · [What it does](#what-it-does)
- [Safety model](#safety-model) · [Tests](#tests) · [Limitations](#limitations)
- [Releasing](#releasing) · [Project layout](#project-layout) · [License](#license)

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (built and tested with Xcode 27.2 on macOS 27.3)
- Apple silicon (the release app is arm64)

## Build

Open `Fettle.xcodeproj` in Xcode, choose the `Fettle` scheme and press Run.

From a terminal:

```sh
make          # builds Release and refreshes build/Fettle.app
make test     # runs the self-test and integration test
```

`make` runs the same `xcodebuild` invocation; you can also call Xcode
directly:

```sh
xcodebuild -project Fettle.xcodeproj -scheme Fettle \
  -configuration Release -derivedDataPath .build-release build

open .build-release/Build/Products/Release/Fettle.app
```

The built app lands in `build/Fettle.app` (ignored by git). The project is
signed ad hoc for local use and is not notarised for distribution.

## What it does

- **Overview** – disk usage, live Mac Health strip, last scan, results by
  module, local cleanup and activity history, one read-only Scan action, and
  clear separation between estimated removable bytes, bytes moved to the
  Trash, and macOS's reported free space. When a scan could not read
  something, Overview says the result is incomplete and the module shows the
  skipped path and reason.
- **Disk Cleanup** – user caches, old logs, crash reports, temporary files and
  the current user's Trash, grouped by category and location. A separate large
  file view scans folders you choose. Trash is emptied only through its own
  confirmed action.
- **Maintenance** – broken user-owned aliases, invalid personal LaunchAgents
  (relative programs are resolved against `WorkingDirectory`; no program is
  broken, a missing path is broken unless an installed app owns it, and an
  existing file is never flagged for its executable bit), broken preference
  lists, and confirmed leftovers from removed apps. Every finding carries
  evidence; uncertain items stay informational.
- **Uninstaller** – apps from `/Applications`, `~/Applications` and folders you
  add. Associated files are matched by exact bundle identifier only, including
  the `SDMHelpData` and Adobe AIR `ELS` leftover roots. Apps and
  their files are shown separately, app data is flagged, shared containers are
  excluded. A separate leftover scan covers previously removed apps.
- **App Updater** – checks the update feed each app publishes (Sparkle appcast)
  and identifies App Store and Apple apps. Results show current and latest
  versions, source, release date, update size and release notes. A **Review**
  sheet lets you choose which updates to open. Fettle never downloads or runs
  an installer: it opens the vendor's page, the App Store or Software Update.
  The check is manual unless automatic checks or inclusion in Scan are enabled
  in Settings, and every scanned app can be ignored. After a vendor update,
  Fettle rereads the installed version. Apps without a readable feed get an
  **Open App** action so their own updater can run.
- **Mac Health** – live CPU, memory, disk, battery and network pages, plus a
  persisted Activity page. CPU and memory have trend lines, per-core load, top
  process lists and quit/force-quit with confirmation. Memory shows pressure,
  swap and a Quit Selected Apps review that quits selected apps (never a system
  purge). Disk lists volumes, drive health/SMART data, I/O rates and Eject All.
  Battery shows charge, health, cycles, condition, temperature and adapter.
  Network shows counters, addresses and current rates. Six alert kinds cover
  memory pressure, high CPU, low disk, a large Trash, external drives and drive
  health. An opt-in Accessibility check reports apps that do not respond and
  tells a slow launch apart from a confirmed timeout. Activity history shows
  gaps where Fettle was not running instead of joining the line across them.
- **Menu bar** – a popover with live readings, Scan, Quit Selected Apps, Eject All,
  settings and an at-a-glance battery/drive/busiest-process summary. Background
  mode keeps Fettle available after the window closes, and Open at Login uses
  the supported macOS login-item API.
- **Sleep & Power** – read-only `pmset` view of battery and power-adapter
  settings, differences, sleep/recovery files, a link to the live Battery page,
  and routes into System Settings.
- **Extensions** – system extensions reported by `systemextensionsctl`, Safari
  extensions where discoverable, and Chrome, Edge, Opera and Firefox add-ons
  read from their profiles. Management opens the supported settings surface.
- **Login Items** – user LaunchAgents with reversible enable/disable through
  `launchctl`, plus the macOS background items `sfltool` can report. User
  LaunchAgents appear while macOS is still collecting background items, and
  Retry stays available even when the list comes back empty. System daemons
  are never modified.
- **Privacy** – browser cache, cookies/site data, browsing history and download
  history by browser and profile, with sign-out explanations, download files
  preserved, and passwords never read. Recent items route to Finder and
  Desktop & Dock settings.
- **Permanent Delete** – a separate drag-and-drop screen, exact paths and
  sizes, a typed confirmation, per-item results, and a clear warning about SSD
  wear levelling, APFS snapshots, backups and cloud copies.

Settings include a persistent ignore list, live-monitoring on/off and sample
interval, seven-day numeric activity history, menu bar visibility and CPU
percentage, background mode, Open at Login, opt-in cleanup and Trash reminders
with 3/7/14/30-day intervals and 2 GB default, six health-alert
choices (memory pressure, high CPU threshold, low disk, large Trash, external
drives and drive health), notification/sound choices, an external-drive prompt,
light/dark appearance, English/Dutch interface strings, and manual or opt-in
update checks against an Ed25519-signed release feed.

## Safety model

- Scans only read metadata (names, sizes, dates); contents are not uploaded.
- Selections start empty. Every change is shown and confirmed first.
- Ordinary cleanup and app removal use the Trash. Emptying the Trash and
  Permanent Delete are separate confirmed actions.
- Each item is rechecked immediately before acting; changed, missing or
  out-of-scope items are skipped and reported.
- Paths are canonicalised with `realpath` and checked against approved roots.
  Symbolic links are not followed.
- No administrator password is requested, no macOS protection is bypassed, and
  no credentials, keychains or password databases are read.
- Mac Health readings are read-only. Process actions show the process name and
  revalidate its identity immediately before quitting; force quit is a separate
  confirmed action. Quit Selected Apps only asks apps to quit and measures the
  result; it never requests an administrator password or forces a purge.
- App Updater contacts only the feed URL an app publishes, through a
  cookie-free ephemeral session. It never downloads or runs an installer and
  never reads credentials.
- Ignore list, history, activity history and settings are stored locally.

## Tests

The app contains hidden, non-destructive test modes. They create a disposable
home folder under the system temporary directory and never touch the real
user's files.

```sh
build/Fettle.app/Contents/MacOS/Fettle --self-test
build/Fettle.app/Contents/MacOS/Fettle --integration-test
```

`--self-test` covers scanners, path safety, change detection, Trash and
permanent delete, symlink handling, download-history preservation, extension
parsing, login-item parsing, power parsing, appcast parsing and version order,
updater source detection, health parsers, alert evaluation, activity-history
persistence, process-safety guards, persistence, localisation, signature
verification and permission reporting. `--integration-test` drives
the module models through scan → select → confirm → act with disposable
fixtures, including quitting a disposable process, Quit Selected Apps, and ejecting
a disposable disk image.

`--health-probe` prints a live JSON snapshot of Mac Health without opening a
window. `--ui-preview` renders real window contents to a PNG for development
layout review without Screen Recording permission; it is not part of the
interface.

A JSON copy of the last self-test result is written to the system temporary
folder (`NSTemporaryDirectory()`), or to the path after `--self-test-output`.

## Limitations

See `FEATURE-MATRIX.md` for the module-by-module matrix and the exact limits of
each macOS interface. The main ones:

- Some macOS data needs Full Disk Access. Fettle never requests it
  automatically and reports what it could not read.
- System-managed extensions and login items open System Settings; they cannot be
  toggled by a third-party app.
- Browser add-ons are managed by their browser. Fettle opens the browser's
  extension page.
- App Updater can only offer an update when the app publishes a readable Sparkle
  feed. App Store and Apple apps are routed to their supported update pages, and
  apps without a feed are reported as such. Fettle never installs an update
  itself, so a vendor installer or store page still has to finish the job.
- macOS has no public API to clear Finder recent items; Fettle routes to
  Finder and Desktop & Dock and explains the Apple-menu route.
- Permanent Delete cannot guarantee physical erasure on SSDs, APFS snapshots,
  backups or cloud copies.
- Background item discovery through `sfltool` can be unavailable or slow on some
  macOS builds; user LaunchAgents remain visible.
- The Accessibility responsiveness check is opt-in. Without permission,
  Fettle only reports apps that macOS says have not finished launching.
- Quit Selected Apps cannot perform a system-wide purge without administrator
  rights. It quits selected apps instead and measures the memory macOS reports.
- SMART depends on the drive and enclosure. “Health unavailable” is not a health
  verdict; some external drives need a direct connection.
- Network counters are reported since boot and may wrap after very long uptime.
  Rates restart from a fresh baseline after a counter reset or a long pause.
- Open at Login uses the macOS login-item API. Registration and unregistration
  were exercised on this Mac and left no login item behind. A rebuilt or moved
  app may need to be registered again; the exact status is always shown.
- Activity history exists only while Fettle is running; it keeps one numeric
  reading per minute for seven days and never stores process names.
- Notifications require the user's permission. Official releases can include
  a signed update feed; local builds without a bundled feed need the URL and
  public key in Settings.

## Optional signed update feed

Release builds can ship with a pinned public key and feed URL.

1. On the release machine, create a signing key once, in a new directory
   outside the checkout:

   ```sh
   umask 077
   openssl rand -out fettle-feed.key 32
   ```

   Back up this key securely. Anyone with it can sign updates.
2. Set `FETTLE_FEED_KEY_FILE` to the key's absolute path for every official
   `make release`. The release script embeds the matching public key before
   code signing and writes `dist/feed.json` for the finished ZIP.
3. Upload `dist/feed.json` alongside the ZIP on the matching stable GitHub
   release.

Builds that were distributed before the key was pinned need the feed URL and
public key entered in Settings once. The feed is a JSON object like:

```json
{
  "version": "1.2",
  "build": "2",
  "url": "https://example.com/Fettle.zip",
  "sha256": "…",
  "notes": "What changed",
  "signature": "base64 Ed25519 signature"
}
```

The signature is over the UTF-8 string `version|build|url|sha256` (empty strings
where a field is absent), using an Ed25519 key whose raw 32-byte public key is
entered as base64 in Settings. A feed is only offered when that signature
verifies and the version is newer. Fettle never downloads or installs an
update itself; it opens the download page.

## Releasing

```sh
make release
```

This builds Release, signs the app, and writes to `dist/`:

- `Fettle-<version>.dmg` – drag-to-Applications disk image with the Fettle volume icon
- `Fettle-<version>.zip` – the same app as a zip
- `SHA256SUMS.txt` – checksums for both

The version comes from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the
Xcode project. Bump those first.

**Signing.** `scripts/release.sh` uses `SIGN_IDENTITY` if set, otherwise the
first *Developer ID Application* certificate in your keychain, otherwise an ad
hoc signature. An ad hoc build runs on the Mac that built it; on other Macs,
Gatekeeper blocks it until the user right-clicks the app → **Open**, or runs
`xattr -dr com.apple.quarantine /Applications/Fettle.app`.

**Notarizing (for public distribution).** Requires the Apple Developer Program:

1. Create a *Developer ID Application* certificate in Xcode → Settings →
   Accounts → Manage Certificates.
2. Store notary credentials once (use an app-specific password from
   account.apple.com):
   ```sh
   xcrun notarytool store-credentials fettle-notary \
     --apple-id <your Apple ID> --team-id <TEAMID> --password <app-specific-password>
   ```
3. Build, sign with the hardened runtime, notarize and staple:
   ```sh
   NOTARY_PROFILE=fettle-notary make release
   ```

**Publishing on GitHub.**

```sh
git tag v1.3 && git push origin v1.3
gh release create v1.3 dist/Fettle-1.3.dmg dist/Fettle-1.3.zip dist/SHA256SUMS.txt dist/feed.json \
  --title "Fettle 1.3" --generate-notes
```

## Project layout

```
Fettle.xcodeproj/     Xcode project (scheme: Fettle)
Fettle/
  App/                App entry point, menu bar, commands
  Core/               Models, settings, file safety, localisation
  Scanners/           Disk, maintenance, uninstaller, privacy, health, ...
  Views/              SwiftUI screens
  Support/            Self-test, integration test, probes
  Resources/          Asset catalog and app icon
scripts/make_icon.swift  Draws the app icon (run `make icon`)
scripts/release.sh    Builds the signed app, DMG, zip and checksums (`make release`)
Makefile              make / make test / make clean / make icon / make release
FEATURE-MATRIX.md     Module-by-module implementation and verification matrix
```

## License

[MIT](LICENSE) © 2026 Stijnus
