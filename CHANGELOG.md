# Changelog

Notable changes to Veltoret. Newest first. Detailed history is in the git log.

## Unreleased

### Added
- **Scan a single folder** from Settings, and see each folder's video count, last scan time and any error.
- **Scan progress**: the current step and folder, videos found, new files, TMDB matching, a progress bar
  and a Cancel button. Scans you start keep running when the app is minimized, with a progress
  notification you can cancel from.
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

### Changed
- **Smarter file-name recognition**: release-site names ("www.Site.com - …", "….SiteName.army"),
  audio tags ("(Hindi Dubbed)", "Dual Audio [Hindi + Telugu]"), `S01-E02` / `S01.EP02` / `S01E01-03`,
  daily shows, anime episodes past 999, Japanese episode numbers, scene-style `Show.105`, season folders
  like "Season.2", "Staffel 2" or "Season Three", and category or quality folders ("English Shows",
  "1080p x264") are all understood. Titles in Hindi, Japanese and other scripts now match TMDB.
- When a title isn't found, Veltoret also tries the file's own name and trimmed variants (exact matches only).

### Fixed
- Android TV remote: closing a side panel or picker now returns focus to the row or button that opened
  it (it used to jump to the top of the list); going up a folder in Files or the folder picker focuses
  the folder you came from; coming back from a title in Search focuses that result; Settings opens on the
  first row; returning to the season chips keeps the selected season instead of switching to the nearest
  one; and starting or cancelling a scan no longer drops focus to the navigation rail.
- TV shows in folders like "Show.S01.1080p…" were searched as "Show S01" and never matched; season tags
  (S01, S01-S03, Season 2, Complete) are now dropped from show names, and language tags ("Hindi English",
  "MSubs") from titles.
- Titles with apostrophes ("Don't", "Stine's") now match file names that leave them out.
- Files that couldn't be matched are read again on the next scan, so parser fixes reach existing libraries.
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
