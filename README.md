# Veltoret

**Your movies and shows, as a private cinema.**

Developed by [PNT Apps](https://www.pntapps.com) · [pntapps.com](https://www.pntapps.com)

Veltoret is an open-source Android app that turns the video files in your Google Drive, and on your
phone, SD card or USB drive, into a beautiful Movies and TV Shows library, with posters, cast and episode guides from TMDB, and plays
them with a full-featured player.

> Veltoret is a player for your own files. It doesn't find, host or download content; please use it
> only with media you own or have the rights to.

## Features

- **Automatic library**: point it at Movies and TV Shows folders. Release-style names
  (`The.Matrix.1999.1080p.mkv`, `Show S02E05.mkv`, `[Group] Show - 05.mkv`) are parsed and matched
  on TMDB. The parser understands scene, P2P and anime naming, release-site names, audio-language
  tags, daily shows (`Show.2024.03.15`), season folders in several languages, category and quality
  folders, and titles in any script. When the first guess doesn't match, it tries the file's own
  title and trimmed variants before giving up. Anything it can't identify goes to **Fix match**.
- **Home**: featured titles, Continue Watching, Next Up, Recently Added, Highly Rated and genre rows.
- **Movies & TV Shows**: poster grids with watched / in-progress / 4K filters, genres, sorting,
  and a source filter (this device, a Google account or a network server).
- **Detail pages**: overview, cast, quality badges (4K, HDR, HEVC, Atmos…), versions across
  accounts, season tabs, per-episode watched tracking, and **More like this**: TMDB's
  recommendations that are already in your library. **Trailers** open in YouTube.
- **Player** (Media3):
  - MKV, MP4, WebM, AVI, TS and more, including MKVs that store their track list at the end of the
    file (a patched Media3 MKV extractor; plain Media3 plays these silently).
  - Extra audio codecs via FFmpeg: DTS, DTS-HD, TrueHD, AC3, E-AC3, FLAC, ALAC. Video uses the
    device's decoders, with automatic fallback to Android's software decoders, and clear messages
    when a format (e.g. 10-bit HEVC) isn't supported by the device.
  - Audio and subtitle tracks named by language, remembered per show. Add subtitles from Drive or the
    device (SRT, VTT, ASS/SSA, TTML) with **sync adjustment** and automatic text-encoding detection;
    matching subtitle files next to a video load automatically.
  - Gestures: brightness, volume (with boost to 200%), seek, pinch to zoom, double-tap to skip
    (taps add up), hold for 2× speed. Speed 0.25–3×, Fit / Fill / Stretch, rotate, lock.
  - Previous / next episode, in-player episode list, auto-play next, skip intro, resume prompt with
    "Start over", "Ends at" clock, sleep timer, picture-in-picture with controls, video info panel,
    keyboard shortcuts (Space/K, J/L, M, N/P).
- **Files on this device**: add folders from internal storage, an SD card or a USB drive with the
  system folder picker (no broad storage permission). They join the same library, play instantly
  and work offline. When a title exists both on the device and in Drive, the device copy is played.
  Google is optional: the app works with device folders alone.
- **Network shares (SMB)**: folders shared by a router with a USB drive, a NAS or a Windows PC.
  **Settings → Add network server** finds servers on your Wi-Fi by itself (or takes a typed or pasted
  address like `\\192.168.0.10\Movies`), signs in with a username and password or as a guest, and
  adds Movies and TV Shows folders like any other source. Videos stream straight from the server with
  instant seeking; passwords are stored encrypted on the device. Works on the same network only,
  on phones, tablets and Android TV, from Settings or first-run setup. On TV, **Use your phone** skips
  typing with the remote: scan a QR code with any phone and fill in a page, or send a saved server
  from Veltoret on your phone or tablet with a 6-digit code (encrypted).
- **Offline mode**: with no internet the library shows what's stored on this device, with posters,
  details and watch progress (artwork is cached after each scan). Drive-only titles step aside until
  you're back online, then the library catches up by itself.
- **Files**: a full file manager for Drive, the device and network shares: browse, play, rename, move, delete or
  trash (or delete Drive files permanently), new folder, multi-select, search, used and free storage
  space for each source, plus background uploads and "Shared with me" for Drive.
  It lists only what Veltoret can use: folders, videos, subtitles and ZIPs (folders and videos on TV).
- **ZIP extraction**: season packs uploaded as `.zip` are found during scans and can be unpacked
  back into Drive with one tap, after checking there's room for it in Drive. The archive streams through the phone (nothing is stored on it),
  resumes after interruptions, and the new folder is added to the library automatically.
- **Multiple Google accounts**, merged into one library.
- **Library scans you can follow**: scan everything or a single folder from Settings, with live progress
  (current folder, videos found, new files, TMDB matching), a progress bar and Cancel. Scans keep running
  when the app is minimized, with progress in a notification. Each folder shows its video count, when it
  was last scanned, and why it couldn't be read if something went wrong.
- **Android TV / Google TV**: the same APK installs on TVs and switches to a remote-first interface:
  a navigation rail, full-screen artwork behind Home and detail pages that follows focus, poster rows
  that keep focus in a fixed spot,
  side panels for choices, and a player built for the D-pad (OK pauses, ← → seek with acceleration,
  ↓ shows the controls, media keys work, Fit / Fill / Stretch picture size). Google Drive sign-in works with the TV's Google account;
  videos on the TV's own storage and USB drives come from the TV's media library.
- Adaptive layouts for phones, tablets and foldables. Premium dark theme, no gradients.

## Tech

Kotlin · Jetpack Compose (Material 3) · Navigation 3 · Room · WorkManager · DataStore ·
Retrofit + OkHttp + kotlinx.serialization · Coil 3 · Media3 ExoPlayer (+ Jellyfin FFmpeg decoder) ·
Play services AuthorizationClient.

```
app/src/main/java/com/pntapps/veltoret/
├── data/
│   ├── auth/      Google Drive authorization & token cache
│   ├── db/        Room entities and DAOs
│   ├── drive/     Drive REST API, repository, resumable uploads
│   ├── library/   Filename parser, scanner, watch progress, play targets
│   ├── settings/  DataStore preferences
│   ├── storage/   Device folders (Storage Access Framework) and a common file API
│   └── tmdb/      TMDB API and metadata caching
├── player/        PlayerActivity, ViewModel, Compose controls, Drive data source
└── ui/            Theme, components, navigation and feature screens
```

## Getting started

Follow the **[Setup Guide](SETUP.md)**. It takes about 15 minutes, costs nothing, and walks you
through building the app, connecting your own Google Cloud project for Drive access, and adding
a free TMDB key for posters.

Want to give the app to friends and family? The guide's
**[Share section](SETUP.md#-share-veltoret-with-friends-and-family-optional)** covers the release
key, Google sign-in for other people, an optional built-in TMDB key, and installing the APK.

### Demo library (for contributors)

Debug builds show **"Explore a demo library"** on the welcome screen. It fills the app with real
TMDB titles backed by placeholder files, so you can work on every screen (phone, tablet, foldable)
without connecting Google Drive. Remove it any time from **Settings** by removing the
"Demo Library" account. Playback isn't available for demo items.

What changed recently: see **[CHANGELOG.md](CHANGELOG.md)**.

## Roadmap

- Android TV (Compose for TV, D-pad focus)
- Offline downloads
- Chromecast
- Cross-device watch-progress sync via Drive's app-data folder
- Styled ASS/SSA subtitle rendering (libass)

## Developer

Veltoret is developed by **PNT Apps**.

- Website: [pntapps.com](https://www.pntapps.com)
- About us: [pntapps.com/about](https://www.pntapps.com/about)
- Privacy policy: [pntapps.com/privacy](https://www.pntapps.com/privacy)

## License

Veltoret is free software under the [GNU General Public License v3.0](LICENSE). You may use, study,
change and share it; versions you distribute must stay under the same license.

Third-party code:

- [AndroidX Media3](https://github.com/androidx/media), Apache License 2.0. The file
  `androidx/media3/extractor/mkv/VeltoretMatroskaExtractor.java` is a modified copy of Media3's
  `MatroskaExtractor`; its header describes the changes.
- [Jellyfin media3-ffmpeg-decoder](https://github.com/jellyfin/jellyfin-androidx-media), GPL-3.0,
  which bundles [FFmpeg](https://ffmpeg.org/).
- [smbj](https://github.com/hierynomus/smbj), Apache License 2.0, for network shares, and
  Rapid7's [dcerpc](https://github.com/rapid7/smbj-rpc), BSD 3-Clause, to list a server's shared folders.
- [ZXing](https://github.com/zxing/zxing), Apache License 2.0, to draw QR codes on TV.
- Fonts: [Fraunces](https://github.com/undercasetype/Fraunces) and [Inter](https://rsms.me/inter/),
  SIL Open Font License 1.1 (see [third_party/fonts/OFL.txt](third_party/fonts/OFL.txt)).

## Attribution and trademarks

<img src="https://www.themoviedb.org/assets/v4/logos/v2/blue_short-8e7b30f73a4020692ccca9c88bafe5dcb6f8a62a4c6bc55cd9ba82bb2cd95f6c.svg" alt="TMDB" height="16">

This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB. Movie and TV metadata and
artwork come from [The Movie Database (TMDB)](https://www.themoviedb.org/).

Google Drive is a trademark of Google LLC. Veltoret is an independent project and is not affiliated
with, endorsed or sponsored by Google or TMDB.
