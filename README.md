# Veltoret

**Your movies and shows, as a private cinema.**

Veltoret is an open-source Android app that turns the video files in your Google Drive, and on your
phone, SD card or USB drive, into a beautiful Movies and TV Shows library, with posters, cast and episode guides from TMDB, and plays
them with a full-featured player.

> Veltoret is a player for your own files. It doesn't find, host or download content; please use it
> only with media you own or have the rights to.

## Features

- **Automatic library**: point it at Movies and TV Shows folders. Release-style names
  (`The.Matrix.1999.1080p.mkv`, `Show S02E05.mkv`, `[Group] Show - 05.mkv`) are parsed and matched
  on TMDB. Anything it can't identify goes to **Fix match**.
- **Home**: featured titles, Continue Watching, Next Up, Recently Added, Highly Rated and genre rows.
- **Movies & TV Shows**: poster grids with watched / in-progress / 4K filters, genres and sorting.
- **Detail pages**: overview, cast, quality badges (4K, HDR, HEVC, Atmos…), versions across
  accounts, season tabs, and per-episode watched tracking.
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
- **Files**: a full file manager for Drive and the device: browse, play, rename, move, delete or
  trash, new folder, multi-select, search, plus background uploads and "Shared with me" for Drive.
- **ZIP extraction**: season packs uploaded as `.zip` are found during scans and can be unpacked
  back into Drive with one tap. The archive streams through the phone (nothing is stored on it),
  resumes after interruptions, and the new folder is added to the library automatically.
- **Multiple Google accounts**, merged into one library.
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

### Demo library (for contributors)

Debug builds show **"Explore a demo library"** on the welcome screen. It fills the app with real
TMDB titles backed by placeholder files, so you can work on every screen (phone, tablet, foldable)
without connecting Google Drive. Remove it any time from **Settings** by removing the
"Demo Library" account. Playback isn't available for demo items.

## Roadmap

- Android TV (Compose for TV, D-pad focus)
- Offline downloads
- Chromecast
- Cross-device watch-progress sync via Drive's app-data folder
- Styled ASS/SSA subtitle rendering (libass)

## License

Veltoret is free software under the [GNU General Public License v3.0](LICENSE). You may use, study,
change and share it; versions you distribute must stay under the same license.

Third-party code:

- [AndroidX Media3](https://github.com/androidx/media), Apache License 2.0. The file
  `androidx/media3/extractor/mkv/VeltoretMatroskaExtractor.java` is a modified copy of Media3's
  `MatroskaExtractor`; its header describes the changes.
- [Jellyfin media3-ffmpeg-decoder](https://github.com/jellyfin/jellyfin-androidx-media), GPL-3.0,
  which bundles [FFmpeg](https://ffmpeg.org/).
- Fonts: [Fraunces](https://github.com/undercasetype/Fraunces) and [Inter](https://rsms.me/inter/),
  SIL Open Font License 1.1 (see [third_party/fonts/OFL.txt](third_party/fonts/OFL.txt)).

## Attribution and trademarks

This product uses the TMDB API but is not endorsed or certified by TMDB. Movie and TV metadata and
artwork come from [The Movie Database (TMDB)](https://www.themoviedb.org/).

Google Drive is a trademark of Google LLC. Veltoret is an independent project and is not affiliated
with, endorsed or sponsored by Google or TMDB.
