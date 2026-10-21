# Veltoret for Windows

**Your movies and shows, as a private cinema.**

Developed by [PNT Apps](https://www.pntapps.com) · [pntapps.com](https://www.pntapps.com)

Veltoret for Windows is the native Windows edition of [Veltoret](https://github.com/pntapps/Veltoret) (Android: [`android/`](../android), Mac: [`mac/`](../mac)). It turns the
video files in your Google Drive, on this PC and on your network shares into a beautiful Movies and TV Shows library,
with posters, cast and episode guides from TMDB, and plays them with a full-featured player.

> Veltoret is a player for your own files. It doesn't find, host or download content; please use it only with media
> you own or have the rights to.

## Download

Get the installer from **[Releases](https://github.com/pntapps/Veltoret/releases)**:
`Veltoret-Setup-<version>-x64.exe` (tags `windows-v…`). It installs for your Windows account without admin rights (or for all users, if you
choose), needs Windows 10 version 2004 or later (64-bit), and includes everything it needs — no .NET or codec packs to
install.

The installer isn't code-signed yet, so Windows SmartScreen may say "Windows protected your PC". Click **More info →
Run anyway** if you downloaded it from this page.

## Features

- **Automatic library**: point it at Movies and TV Shows folders. Release-style names
  (`The.Matrix.1999.1080p.mkv`, `Show S02E05.mkv`, `[Group] Show - 05.mkv`) are parsed and matched on TMDB — the same
  parser as the Android app, with the same test corpus. Scene, P2P and anime naming, daily shows, season folders in
  several languages, category and quality folders, and titles in any script. Anything it can't identify goes to
  **Fix match**.
- **Home**: featured titles, Continue Watching, Next Up, Watchlist, Coming Up, Recently Added, Highly Rated,
  Collections and genre rows.
- **Watchlist and reminders**: "Watch later" on any title; "Remind me" on a movie, show or episode, as a Windows
  notification with the artwork, **Play** and **Snooze**. New-episode alerts on air day for shows on your Watchlist.
- **Search** by title, actor, director, creator or collection, with the reason each result matched, plus voice search
  through Windows speech recognition.
- **Movies & TV Shows**: poster grids with watched / in-progress / 4K filters, genres, sorting and a source filter.
- **Detail pages**: overview, cast, quality badges (4K, HDR, HEVC, Atmos…), versions across sources, season tabs,
  per-episode watched tracking, **More like this** from your own library, collections and trailers (YouTube).
- **Player** (LibVLC):
  - MKV, MP4, WebM, AVI, TS and more, with DTS, DTS-HD, TrueHD, AC3, E-AC3, FLAC and 10-bit HEVC; hardware decoding
    with automatic software fallback.
  - Audio and subtitle tracks named by language and remembered per video and per show. Add subtitles (SRT, VTT,
    ASS/SSA, TTML) with sync adjustment and automatic text-encoding detection; matching subtitle files next to a video
    load automatically.
  - Previous / next episode, in-player episode list, auto-play next, skip intro, resume with "Start over", "Ends at"
    clock, sleep timer, speed 0.25–3×, Fit / Fill / Stretch and zoom, volume boost to 200%, video info panel,
    full screen and an always-on-top **mini player**, full keyboard and mouse control.
- **Folders on this PC**: internal drives, external and USB drives. They work offline and win over cloud copies.
  Google is optional: the app works with local folders alone.
- **Network shares (SMB)**: a NAS, a router with a USB drive or another PC. **Add network server** finds servers on
  your network by itself (or takes an address like `\\192.168.0.10\Movies`), signs in with a username and password or
  as a guest, and streams videos straight from the server with instant seeking. Passwords are encrypted for your
  Windows account (DPAPI).
- **Offline mode**: with no internet the library shows what's on this PC, with posters, details and watch progress.
- **Files**: a full file manager for Drive, this PC and network shares: browse, play, rename, move, delete (Drive to
  trash, this PC to the Recycle Bin), new folder, multi-select, search, storage space per source, background uploads to
  Drive and "Shared with me".
- **ZIP extraction**: season packs uploaded to Drive as `.zip` are unpacked back into Drive, streamed through the PC
  with nothing stored on it, resuming after interruptions.
- **Chromecast**: cast to a Chromecast or Google TV on your network; the PC streams the file (Drive, local and
  network-share files alike) with resume, progress, subtitles and audio-language choice.
- **Play on TV**: with Veltoret on an Android TV, send the title to Veltoret's own player there, with every audio track
  and built-in subtitles. Pair once with the code the TV shows.
- **Multiple Google accounts**, merged into one library.
- **Library scans you can follow**, with live progress and Cancel, every 12 hours and whenever the connection returns.
- **Runs quietly in the notification area** so reminders and scans keep working when the window is closed; optional
  **Start with Windows**.
- Premium dark design with Fraunces and Inter, flat surfaces, no gradients — the same design language as the Android
  app.

## Getting started

1. Install Veltoret and open it. The welcome screens walk you through adding sources.
2. **TMDB key** (free, for posters and details): see [docs/SETUP.md → TMDB key](docs/SETUP.md#tmdb-key).
3. **Google Drive** (optional): Veltoret uses your own Google Cloud OAuth client, so it has no server and nothing passes
   through PNT Apps. It takes about 10 minutes: [docs/SETUP.md → Google Drive](docs/SETUP.md#google-drive).
4. **Folders on this PC** and **network servers** need no setup: add them on the welcome screens or in **Settings**.

When Veltoret first looks for TVs and network servers, Windows asks whether it may use the network: allow it on
**private networks** (needed for Chromecast, Play on TV and server discovery).

## Build from source

Requirements: Windows 10/11 x64, the [.NET 10 SDK](https://dotnet.microsoft.com/download), and for the installer
[Inno Setup 6.7+](https://jrsoftware.org/isinfo.php) (`winget install JRSoftware.InnoSetup`).

```powershell
dotnet build Veltoret.sln
dotnet test tests\Veltoret.Core.Tests
dotnet run --project src\Veltoret.App

# Installer: artifacts\installer\Veltoret-Setup-<version>-x64.exe
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

For development you can supply a TMDB key through the `VELTORET_TMDB_KEY` environment variable instead of entering it
in the app. Never commit keys, OAuth client files or tokens.

## Tech

C# · .NET 10 · WPF · LibVLC (LibVLCSharp) · SQLite (Microsoft.Data.Sqlite + Dapper) · CommunityToolkit.Mvvm ·
SMBLibrary · SharpCompress · Windows toast notifications · Windows speech recognition.

```
src/Veltoret.Core/     Everything testable, no UI
  Data/                SQLite schema (same tables as the Android app), DAOs
  Library/             Filename parser, scanner, watch progress, play targets
  Tmdb/                TMDB API, strict matching, caching
  Storage/ Local/      One file API for every source; folders on this PC
  Drive/ Auth/         Google sign-in (loopback + PKCE), Drive REST, uploads, ZIP extraction
  Smb/                 Network shares: discovery, encrypted server store, streaming
  Cast/ TvLink/ Pairing/   Chromecast (Cast v2), Play on TV, pairing crypto, stream server
  Plans/ Player/       Watchlist, reminders, upcoming episodes, voice; player logic and subtitles
src/Veltoret.App/      WPF app: shell, pages, player window, tray icon, notifications
tests/                 xUnit, including the Android app's unit tests ported one for one
installer/             Inno Setup script, build script and artwork
docs/                  Setup guide and module contracts (shared specs: ../docs/spec)
```

## Official builds and forks

Official Veltoret builds are published by PNT Apps. If you share or publish your own build or fork, give it your own
name, icon and publisher, and don't present it as an official PNT Apps release. Keep the "Developed by PNT Apps"
credit (see [Credit to PNT Apps](#credit-to-pnt-apps--required)) and publish your source code under GPL-3.0.

## Credit to PNT Apps — required

If you use, fork, modify or redistribute Veltoret, you must keep the credit to PNT Apps:

- in your README or main documentation: **"Developed by PNT Apps — https://www.pntapps.com"**, and
- inside the app, where users can see it (for example an About or Settings screen): **"Developed by PNT Apps"**
  linking to https://www.pntapps.com.

You may add your own credits next to it. This is an additional term of the license (GPL-3.0, section 7(b)); see
[NOTICE](../NOTICE).

A modified version must not be presented as the original Veltoret or as an official PNT Apps release, and the names
"PNT Apps" and "Veltoret" and their logos/icons may not be used as the name or icon of your app.

## License

Copyright © 2026 PNT Apps.

Veltoret for Windows is licensed under the [GNU General Public License v3.0](LICENSE) with the additional attribution terms in
[NOTICE](../NOTICE). In short: you may use, study, change and share it, but if you distribute it or a modified version,
you must release your source code under the same GPL-3.0 license (including the attribution terms) and keep the
credit to PNT Apps.

Third-party code:

- [LibVLC](https://www.videolan.org/vlc/libvlc.html) and [LibVLCSharp](https://code.videolan.org/videolan/LibVLCSharp),
  LGPL-2.1 or later.
- [SMBLibrary](https://github.com/TalAloni/SMBLibrary), LGPL-3.0, for network shares.
- [SharpCompress](https://github.com/adamhathcock/sharpcompress), MIT, for ZIP extraction.
- [Dapper](https://github.com/DapperLib/Dapper), Apache 2.0; [Microsoft.Data.Sqlite](https://github.com/dotnet/efcore),
  MIT; [CommunityToolkit.Mvvm](https://github.com/CommunityToolkit/dotnet), MIT; Windows Community Toolkit
  notifications, MIT; [Google.Protobuf](https://github.com/protocolbuffers/protobuf), BSD-3-Clause;
  [Makaretu.Dns.Multicast](https://github.com/jdomnitz/net-mdns), MIT.
- Fonts: [Fraunces](https://github.com/undercasetype/Fraunces) and [Inter](https://rsms.me/inter/), SIL Open Font
  License 1.1 (see [third_party/fonts/OFL.txt](third_party/fonts/OFL.txt)).

## Attribution and trademarks

This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB. Movie and TV
metadata and artwork come from [The Movie Database (TMDB)](https://www.themoviedb.org/).

Google Drive, Chromecast and Google TV are trademarks of Google LLC. Windows is a trademark of Microsoft Corporation.
Veltoret is an independent project and is not affiliated with, endorsed or sponsored by Google, Microsoft or TMDB.
