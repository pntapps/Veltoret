# Veltoret for Mac

**Your movies and shows, as a private cinema.**

Developed by [PNT Apps](https://www.pntapps.com) · [pntapps.com](https://www.pntapps.com)

Veltoret for Mac is the native macOS edition of [Veltoret](https://github.com/pntapps/Veltoret) (Android) and
[Veltoret for Windows](https://github.com/pntapps/Veltoret-Windows). It turns the video files in your Google Drive,
on this Mac and on your network shares into a beautiful Movies and TV Shows library, with posters, cast and episode
guides from TMDB, and plays them with a full-featured player.

> Veltoret is a player for your own files. It doesn't find, host or download content; please use it only with media
> you own or have the rights to.

## Requirements

macOS 14 Sonoma or later, Apple silicon or Intel.

## Features

- **Automatic library**: point it at Movies and TV Shows folders. Release-style names
  (`The.Matrix.1999.1080p.mkv`, `Show S02E05.mkv`, `[Group] Show - 05.mkv`) are parsed and matched on TMDB — the same
  parser as the Android and Windows apps, with the same test corpus. Anything it can't identify goes to **Fix match**.
- **Home**: featured titles, Continue Watching, Next Up, Watchlist, Coming Up, Recently Added, Highly Rated,
  Collections and genre rows.
- **Watchlist and reminders**: "Watch later" on any title; "Remind me" on a movie, show or episode, as a macOS
  notification with the artwork, **Play** and **Snooze 1 hour**. New-episode alerts on air day for shows on your
  Watchlist.
- **Search** by title, actor, director, creator or collection, with the reason each result matched, plus voice search
  (on-device speech recognition).
- **Movies & TV Shows**: poster grids with watched / in-progress / 4K filters, genres, sorting and a source filter.
- **Detail pages**: overview, cast, quality badges (4K, HDR, HEVC, Atmos…), versions across sources, season tabs,
  per-episode watched tracking, **More like this** from your own library, collections and trailers.
- **Player** (VLCKit / LibVLC):
  - MKV, MP4, WebM, AVI, TS and more, with DTS, TrueHD, AC3, E-AC3, FLAC and 10-bit HEVC; hardware decoding
    (VideoToolbox) with automatic software fallback.
  - Audio and subtitle tracks named by language and remembered per video and per show. Add subtitles (SRT, VTT,
    ASS/SSA, TTML) with sync adjustment and automatic text-encoding detection; matching subtitle files next to a video
    load automatically.
  - Previous / next episode, episode list, auto-play next, skip intro, resume with "Start over", "Ends at" clock, sleep
    timer, speed 0.25–3×, Fit / Fill / Stretch and zoom (pinch on the trackpad), volume boost to 200%, video info,
    native full screen and an always-on-top **mini player**.
  - **Now Playing and media keys** (Control Center, keyboard and headphone controls), and a **Playback** menu with
    every command and its shortcut.
- **Folders on this Mac**: internal disks, external and USB drives. They work offline and win over cloud copies.
  Google is optional: the app works with local folders alone. Drag a folder from Finder onto Settings or Files to add it.
- **Network shares (SMB)**: a NAS, a router with a USB drive or another computer. **Add network server** finds servers
  on your network by itself, signs in with a username and password or as a guest, and streams videos straight from
  the server with instant seeking. Passwords are kept in your Keychain.
- **Offline mode**: with no internet the library shows what's on this Mac, with posters, details and watch progress.
- **Files**: a full file manager for Drive, this Mac and network shares: browse, play, rename, move, delete (Drive to
  trash, this Mac to the Trash), new folder, multi-select, search, Quick Look, Show in Finder, storage space per source,
  background uploads to Drive (drag files in from Finder) and "Shared with me".
- **ZIP extraction**: season packs uploaded to Drive as `.zip` are unpacked back into Drive, streamed through the Mac
  with nothing stored on it, resuming after interruptions.
- **Chromecast**: cast to a Chromecast or Google TV on your network; the Mac streams the file (Drive, local and
  network-share files alike) with resume, progress, subtitles and audio-language choice.
- **Play on TV**: with Veltoret on an Android TV, send the title to Veltoret's own player there. Pair once with the
  code the TV shows.
- **Multiple Google accounts**, merged into one library.
- **Library scans you can follow**, with live progress and Cancel, every 12 hours and whenever the connection returns.
- **Runs quietly in the menu bar** so reminders and scans keep working when the window is closed; optional **Open at
  login**.
- **A real Mac app**: menu bar with standard shortcuts (⌘F search, ⌘, settings, ⌘[ back, ⌘1–⌘6 sections, ⌘R scan),
  two-finger swipe back, right-click menus, "Open With → Veltoret" from Finder.
- Premium dark design with Fraunces and Inter, flat surfaces, no gradients — the same design language as the Android
  and Windows apps.

## Getting started

1. Open Veltoret. The welcome screens walk you through adding sources.
2. **TMDB key** (free, for posters and details): see [docs/SETUP.md → TMDB key](docs/SETUP.md#tmdb-key).
3. **Google Drive** (optional): Veltoret uses your own Google Cloud OAuth client, so it has no server and nothing passes
   through PNT Apps. It takes about 10 minutes: [docs/SETUP.md → Google Drive](docs/SETUP.md#google-drive).
4. **Folders on this Mac** and **network servers** need no setup: add them on the welcome screens or in **Settings**.

When Veltoret first looks for TVs and network servers, macOS asks whether it may find devices on your local network:
click **Allow** (needed for Chromecast, Play on TV and server discovery).

## Build from source

Requirements: macOS 14+, Xcode 16 or later (Swift 6 toolchain).

```bash
Scripts/fetch-vlckit.sh                       # downloads VLCKit (LibVLC for macOS) into Vendor/, once
Scripts/build-app.sh                          # → dist/Veltoret.app (release, VLCKit embedded, ad-hoc signed)
swift test --scratch-path ~/Library/Caches/VeltoretBuild/dev
```

If the project lives in an iCloud-synced folder (Desktop or Documents), always pass a `--scratch-path` outside it:
iCloud adds Finder information to build products, which breaks code signing. `build-app.sh` does this for you.

For distribution, set `VELTORET_SIGN_IDENTITY="Developer ID Application: …"` before `build-app.sh`, then notarize
the app. For development you can supply a TMDB key through the `VELTORET_TMDB_KEY` environment variable instead of
entering it in the app. Never commit keys, OAuth client files or tokens.

Developer aids: `VELTORET_DATA_DIR=/tmp/v` runs the app on a separate data folder;
`VELTORET_SNAPSHOT_DIR=/tmp/shots VELTORET_SNAPSHOT_ROUTES=home,movies,settings` renders those pages to PNG files and
quits (no Screen Recording permission needed).

## Tech

Swift · SwiftUI + AppKit · VLCKit (LibVLC) · SQLite (system library) · AMSMB2 (libsmb2) · Network.framework ·
CryptoKit · UserNotifications · Speech · MediaPlayer · ServiceManagement.

```
Sources/VeltoretKit/        Data (SQLite, same schema as Android/Windows), Storage, Settings, Keychain,
                            Library (parser, scanner, repositories), TMDB, This Mac, connectivity, image cache
Sources/VeltoretPlayerKit/  Media formats, subtitles, HDR probe, track memory, loopback stream server
Sources/VeltoretDrive/      Google sign-in (loopback + PKCE), Drive REST, uploads, ZIP extraction
Sources/VeltoretSmb/        Network shares: discovery, server store, streaming
Sources/VeltoretCast/       Chromecast (Cast v2), cast server, Play on TV, pairing crypto
Sources/VeltoretPlans/      Watchlist, reminders, upcoming episodes, voice queries
Sources/VeltoretUI/         Design system, navigation, dialogs, main window shell
Sources/Feature*/           Library pages, player, Files, network & cast UI, settings & notifications
Sources/Veltoret/           App entry, menus, wiring
Tests/                      XCTest, including the Android/Windows unit tests ported one for one
docs/                       Setup guide, porting specs, module contracts
```

## Official builds and forks

Official Veltoret builds are published by PNT Apps. If you share or publish your own build or fork, give it your own
name and publisher, don't use the PNT Apps name, and don't present it as an official PNT Apps release.

## License

Veltoret for Mac is free software under the [GNU General Public License v3.0](LICENSE). You may use, study, change
and share it; versions you distribute must stay under the same license.

Third-party code:

- [VLCKit](https://code.videolan.org/videolan/VLCKit) / LibVLC, LGPL-2.1 or later.
- [AMSMB2](https://github.com/amosavian/AMSMB2) and libsmb2, LGPL-2.1, for network shares.
- [SQLite](https://sqlite.org), public domain (the macOS system library).
- Fonts: [Fraunces](https://github.com/undercasetype/Fraunces) and [Inter](https://rsms.me/inter/), SIL Open Font
  License 1.1 (see [third_party/fonts/OFL.txt](third_party/fonts/OFL.txt)).

## Attribution and trademarks

This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB. Movie and TV
metadata and artwork come from [The Movie Database (TMDB)](https://www.themoviedb.org/).

Google Drive, Chromecast and Google TV are trademarks of Google LLC. Mac and macOS are trademarks of Apple Inc.
Veltoret is an independent project and is not affiliated with, endorsed or sponsored by Google, Apple or TMDB.
