# CLAUDE.md

Guidance for Claude Code (and humans) working in this repository. Read this first, every session.

Veltoret is an open-source (GPL-3.0) Android app that turns videos in Google Drive **and** on the device
(internal storage, SD card, USB) into a Movies / TV Shows library with TMDB metadata, plays them with a
Media3 player, and manages the files. `README.md` lists the features; `SETUP.md` is the user setup guide.

## Ground rules: understand before you change

This app has many features that depend on each other and were tuned on real devices. Before any change
(feature, fix or refactor):

1. **Read the code you'll touch and its callers.** Search for every use of a function or class before
   changing its signature or behavior. Don't assume; check how it works today.
2. **Read the "Don't break these" section below.** Most of it records real bugs that were fixed. If your
   change touches one of those areas, keep the behavior or explain why it must change.
3. **Keep changes scoped to the request.** Don't remove, rename or "simplify" features, settings, screens or
   comments that weren't part of the request. If something looks unused, search before deleting it.
4. **Match the surrounding code**: naming, comment density, Compose patterns and the design system.
5. **Verify**: build and run the unit tests (commands below). For UI or player changes, check on a device
   or emulator and say what you tested. If you couldn't test something, say so plainly.
6. **Ask when a change is destructive or ambiguous**: database schema changes, deleting files or data,
   changing how files are matched, or anything that affects users' existing libraries.

## Build and test

Requires Android Studio's JDK (21+). On Windows with Git Bash:

```bash
export JAVA_HOME="/c/Program Files/Android/Android Studio/jbr"
./gradlew :app:compileDebugKotlin              # fast check
./gradlew :app:assembleDebug :app:testDebugUnitTest
./gradlew :app:assembleDebugAndroidTest        # builds device tests
```

- **Unit tests** (`app/src/test`): `FilenameParserTest`, `PlayTargetsTest`, `DriveStreamingUploadTest`. Run
  them after any change to parsing, play targets or uploads, and add cases for new behavior.
- **Device tests** (`app/src/androidTest`): **do not run `connectedAndroidTest`**. It uninstalls the app
  afterwards, which wipes the tester's library, accounts and folder permissions, and it runs on every
  connected device. Install both APKs and run a class by hand instead:
  ```bash
  adb -s <serial> install -r app/build/outputs/apk/debug/app-debug.apk
  adb -s <serial> install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
  adb -s <serial> shell am instrument -w -e class com.pntapps.veltoret.MediaFormatsDeviceTest \
      com.pntapps.veltoret.test/androidx.test.runner.AndroidJUnitRunner
  ```
  Real tests: `FilenameParserDeviceTest` (Android's ICU regex differs from the JVM's), `MediaFormatsDeviceTest`,
  `SubtitleEngineDeviceTest`. Probes that only log to logcat: `FfmpegSupportProbe`, `DumpMediaHeaderProbe`,
  `SafSeekProbe`. Uninstall `com.pntapps.veltoret.test` from someone's device when you're done.
- Debug builds log every media read (tag `VeltoretIO`) and track lists (tag `VeltoretPlayer`). Use them to
  diagnose playback before guessing.

## Architecture

Single `app` module, manual dependency injection, no Hilt.

```
app/src/main/java/com/pntapps/veltoret/
├── AppContainer.kt      Creates and wires every repository, API and worker dependency (start here)
├── MainActivity.kt      Theme, width class, onboarding vs AppShell
├── data/
│   ├── auth/            Google sign-in via Play services AuthorizationClient; token cache
│   ├── db/              Room: Entities, Daos, VeltoretDatabase (schemas exported to app/schemas)
│   ├── drive/           Drive REST (Retrofit), DriveRepository, UploadWorker, ExtractWorker (ZIPs)
│   ├── storage/         LocalStorage (SAF device folders) + Storage (one facade for Drive and device)
│   ├── library/         FilenameParser, LibraryScanner, repositories, PlayTargets, SyncWorker
│   ├── tmdb/            TMDB API, models, matching (TmdbRepository.pickBest) and caching
│   ├── settings/        DataStore preferences
│   └── demo/            Debug-only demo library
├── player/              PlayerActivity / PlayerScreen / PlayerViewModel, data sources, subtitles
└── ui/                  AppShell + Navigation 3, theme, shared components, one package per screen
app/src/main/java/androidx/media3/extractor/mkv/VeltoretMatroskaExtractor.java   Patched Media3 file
```

Key ideas:

- **Accounts.** A Google account is identified by its email. Device files use the pseudo-account
  `"device"` (`LocalStorage.ACCOUNT`, shown as "This device"). Several accounts merge into one library.
- **File ids.** Drive file id for Drive; the SAF **document URI string** for device files. Code that must
  work for both goes through `Storage` (`list`, `search`, `rename`, `remove`, `move`, `createFolder`, `read`).
  Check `Storage.isLocal(account)` instead of assuming Drive.
- **Library pipeline.** `SyncWorker` → `LibraryScanner` walks the library folders (`storage.list`), parses
  names with `FilenameParser`, stores `MediaFileEntity` rows, then matches pending files on TMDB.
  `MatchState`: `PENDING`, `MATCHED`, `UNMATCHED`, `MANUAL` (Fix match; never overwritten by a rescan),
  `IGNORED` (user said "not a movie or show"; survives rescans).
- **Navigation.** Navigation 3 with one back stack and a `Navigator` class (`ui/navigation`).
- **Layouts.** `LocalWidthClass` (Compact / Medium / Expanded) and `gutter()` drive phone, tablet and
  foldable layouts. Landscape tablets use the nav rail and two-column screens.

## Don't break these

Each rule below exists because breaking it caused a real bug.

**Player and playback**
- **Never enable `setConstantBitrateSeekingAlwaysEnabled`.** Drive URLs have no file extension, so the
  MP3/ADTS sniffers claim MKV files and play nothing. Plain `setConstantBitrateSeekingEnabled(true)` is fine.
- **Keep `BufferedDataSource` wrapping the data source.** Media3 reads the MKV index a few bytes at a time.
  For device files every read is a FUSE system call; without the buffer, opening a 2–3 GB movie took
  20–30 seconds on a Samsung tablet. With it, about 1–2 seconds.
- **`VeltoretMatroskaExtractor`** is a modified copy of Media3 1.9.4's `MatroskaExtractor`, registered
  through `VeltoretExtractorsFactory`. It (a) seeks to a Tracks element stored after the first Cluster
  (files that otherwise play with no tracks) and (b) ignores SeekHead entries past the end of the file
  (incomplete downloads crashed with "position out of range"). Changes are marked `// Veltoret`. Keep
  the Apache license header and its modification note. When upgrading Media3, re-copy the upstream file
  and re-apply the marked changes.
- **Media3 is pinned to 1.9.4** to match the prebuilt `org.jellyfin.media3:media3-ffmpeg-decoder` (1.9.0+1).
  That FFmpeg build is **audio only** (DTS, TrueHD, AC3, E-AC3, FLAC, ALAC). There is no FFmpeg video
  decoding; video uses MediaCodec, with a software-decoder fallback. Don't claim otherwise in UI or docs.
- **Subtitles "Off" means off.** Track selection ignores the file's DEFAULT flag when subtitles are off
  (`setIgnoredTextSelectionFlags`) but still shows forced subtitles.
- **Per-video track memory** (`PlayerPrefs` / `TrackMemory`, keyed by file id) restores the chosen audio and
  subtitle tracks; the per-show language is the fallback. Keep both working when you touch track selection.
- **Track labels** go through `MediaFormats.cleanLabel` / `trackTitles`. Release-site names
  ("name.tld" with a lowercase ending) are hidden; real labels ("SDH", "Dub.Intl", "DTS-HD.MA") are kept.
  Update `MediaFormatsDeviceTest` when changing this.

**Library and matching**
- **TMDB matching is strict on purpose** (`TmdbRepository.pickBest`). A partial title match only counts if
  the names are close in length or the year matches, and a short year-less name only matches a title
  with a real vote count. Loosening this lets random clips ("vids.mp4") become featured junk titles.
- **Device copies win**: Room queries order device files first (`accountEmail = 'device'`), then by quality.
- **`FilenameParser` regexes run on Android's ICU engine.** Escape `}` and similar characters;
  `FilenameParserDeviceTest` exists because the JVM accepted a pattern that crashed on devices.
- **Database changes need a migration.** Bump the version in `VeltoretDatabase`, add an `AutoMigration` or a
  manual `Migration`, and commit the new schema JSON in `app/schemas`. Never use destructive fallback;
  users would lose their libraries and watch history.

**Device storage (SAF)**
- Device folders are granted with `ACTION_OPEN_DOCUMENT_TREE` and **persisted URI permissions**; there is no
  broad storage permission. Release a permission (`LocalStorage.release`) only when no library folder
  still needs it.
- Deleting a device file is **permanent** (Drive goes to trash). The UI must keep saying so.
- Document URIs can change when a file is renamed; `rename` returns the new id, and the scanner must
  forget the old one.

**Drive**
- Uploads are resumable with unknown size (`Content-Range: bytes a-b/*`); `DriveStreamingUploadTest`
  covers it.
- ZIP extraction streams download → unzip → upload with no temp files and supports Keep / Trash /
  Delete for the archive afterwards. Don't buffer whole archives in memory or on disk.

**UI and design**
- Dark, cinematic design with **no gradients anywhere**: flat surfaces, hairline outlines, amber accent.
  Use the `VColors` tokens and shared components (`Components.kt`, `Motion.kt`).
- **Use `MaterialTheme.colorScheme.background` for page backgrounds, never `VColors.Background`.**
  "Pure black" mode changes the theme background; hard-coded colors show as lighter bands.
- Fonts: Fraunces for titles, Inter for everything else.
- Check new screens at all three width classes, phone and tablet, portrait and landscape.
- The player keeps the system bars hidden (immersive), including while sheets are open.

## Public repository rules

- **Never commit secrets.** The TMDB key lives only in git-ignored `local.properties` (`tmdb.apiKey=…`)
  and is compiled into **debug builds only** as `BuildConfig.DEV_TMDB_KEY`. Each user registers their own
  Google OAuth client (package name + SHA-1) as described in `SETUP.md`; nothing Google-specific is in
  the repo. Don't add real SHA-1 fingerprints, emails, device serials or personal file paths to code,
  tests or docs.
- Keep `.idea/` ignored except `.idea/codeStyles/`.
- Don't name real piracy or release sites in code, tests or docs; use made-up examples like
  `ReleaseSite.at`.
- Keep license and attribution notices intact: `LICENSE` (GPL-3.0), the Apache header and modification
  note in `VeltoretMatroskaExtractor.java`, `third_party/fonts/OFL.txt`, and TMDB's "uses the TMDB API
  but is not endorsed or certified by TMDB" wording in the README and the app's About section. Any new
  dependency must be GPL-3.0 compatible.
- Commit messages: a short summary line, then what changed and why.

## Product decisions already made

Don't reverse these without the maintainer:

- English (US) only. Phone, tablet and foldable first; Android TV, offline downloads and Chromecast later.
- Users bring their own TMDB key and Google Cloud OAuth client; the app has no server.
- Google is optional; device-only use is fully supported.
- No software video decoding library: modern devices decode 10-bit HEVC in hardware.
