# Fettle brand assets

| File | Use |
| --- | --- |
| [`hero.png`](hero.png) | README header banner (2000×760) — wordmark, tagline and a real app window |
| [`logo.png`](logo.png) | Horizontal lockup for light backgrounds (655×220, transparent) |
| [`logo-white.png`](logo-white.png) | Horizontal lockup for dark backgrounds (655×220, transparent) |
| [`social-preview.png`](social-preview.png) | GitHub repository social preview / link card (1280×640) |

The app icon lives in the app itself:
`Fettle/Resources/Assets.xcassets/AppIcon.appiconset/` (drawn by `make icon`).

## GitHub social preview

GitHub has no API for the repository social preview. Set it once, by hand:

1. Open **github.com/Stijnus/fettle/settings** → **Social preview**.
2. **Edit** → upload [`social-preview.png`](social-preview.png).
3. Save. The card is used for repository links on GitHub, Slack, X and elsewhere.

Keep the upload under 1 MB and at 1280×640 — the file here is already in that shape.

## Palette and type

| Token | Value | Where |
| --- | --- | --- |
| Midnight | `#071F1D` | Banner background |
| Deep teal | `#0C3B37` | Banner gradient, sidebar |
| Teal | `#1FB59A` | Primary accent, badges |
| Mint | `#5BE8B0` | Highlight on the app icon |
| Ink | `#0E1B1A` | Wordmark on light backgrounds |
| Warm paper | `#F6F5F3` | Window chrome in screenshots |

Type is SF Pro (the macOS system font), semibold for the wordmark, medium for the
tagline and regular for supporting copy.

## Regenerating

```sh
make art
```

This captures every screen through the app's hidden `--ui-preview` mode, frames each
capture as a macOS window, and redraws the banner, lockups and social preview from
the app icon. Login Items and Maintenance are captured against a disposable sample
home (`FETTLE_HOME`) so the published screenshots never show a real account's app
names or paths; the menu bar's busiest-process name is blurred. It needs a logged-in GUI session and Python 3 with Pillow; your
Fettle settings are backed up and restored around the run.
