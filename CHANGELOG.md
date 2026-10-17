# Changelog

Notable changes to Veltoret. Newest first. Detailed history is in the git log.

## Unreleased

### Added
- **Android TV / Google TV**: a remote-first interface in the same APK, with a navigation rail, a Home
  header that follows focus, poster rows and grids, detail pages, search, files, settings and first-run
  setup, plus a D-pad player (OK pauses, ← → seek, media keys, side panels for audio, subtitles, speed
  and episodes). Videos on the TV's storage and USB drives are read from the TV's media library.
- **Offline mode**: with no internet the library shows what's stored on the device, with posters and
  details; Drive-only titles return when you're back online.
- **Sharing with friends and family**: optional built-in TMDB key for private release builds, release
  signing from `keystore.properties`, and a step-by-step guide in SETUP.md.
- **Videos on the device**: folders on internal storage, SD cards and USB drives, with Google optional.
- **Ignore** for files that aren't movies or shows.

### Fixed
- Device videos took 20–30 s to start on some devices; now about 1–2 s.
- Incomplete MKV downloads failed with "position out of range"; they now play what's there.
- Short or vague file names matched obscure TMDB titles.
- Release-site names showed as audio and subtitle track labels.
- Play on a fully watched show from Home did nothing; it now restarts at episode 1.
- Pure black mode left lighter bands on some screens; the portrait-tablet hero layout was cramped.

## 0.1.0

First version: Google Drive library matched with TMDB, Media3 player (MKV and more, FFmpeg audio,
subtitles with sync, per-video track memory), Drive file manager with uploads and ZIP extraction,
multiple Google accounts, and layouts for phones, tablets and foldables.
