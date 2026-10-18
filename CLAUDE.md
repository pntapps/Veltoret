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
7. **Keep the docs true, in the same change.** A feature, fix or behavior change isn't done until:
   - **this file** is still accurate: add a rule to **Don't break these** for any bug that could come back
     (what must stay true and why), update **Architecture** for new modules, screens or key classes, and
     fix or delete anything that's no longer true. This file holds instructions only, not history, so keep it short;
   - **`CHANGELOG.md`** has a line under *Unreleased* describing the change for people using the app;
   - **`README.md` / `SETUP.md`** reflect any user-visible feature or setup change.
   Never put secrets, emails, device serials or personal paths in any of these.

## Build and test

Requires Android Studio's JDK (21+). On Windows with Git Bash:

```bash
export JAVA_HOME="/c/Program Files/Android/Android Studio/jbr"
./gradlew :app:compileDebugKotlin              # fast check
./gradlew :app:assembleDebug :app:testDebugUnitTest
./gradlew :app:assembleDebugAndroidTest        # builds device tests
```

- **Unit tests** (`app/src/test`): `FilenameParserTest`, `FilenameParserCorpusTest` (one line per naming
  style; add a line for every name that parses wrong), `PlayTargetsTest`, `DriveStreamingUploadTest`, `RelatedTitlesTest`, `SmbPathTest`, `SmbDiscoveryTest`,
  `PairingCryptoTest`. Run
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
│   ├── storage/         LocalStorage (SAF device folders) + Storage (one facade for Drive, device and SMB)
│   ├── smb/             Network shares: SmbStorage (smbj), SmbServerStore (encrypted passwords), SmbPath, SmbDiscovery
│   ├── pairing/         "Use your phone" on TV: PhoneSetupServer (QR page + Send to TV), SendToTv, PairingCrypto
│   ├── library/         FilenameParser, LibraryScanner, repositories, PlayTargets, SyncWorker (+ scan notification)
│   ├── tmdb/            TMDB API, models, matching (TmdbRepository.pickBest) and caching
│   ├── settings/        DataStore preferences
│   └── demo/            Debug-only demo library
├── player/              PlayerActivity / PlayerScreen / PlayerViewModel, data sources, subtitles
└── ui/                  AppShell + Navigation 3, theme, shared components, one package per screen
app/src/main/java/androidx/media3/extractor/mkv/VeltoretMatroskaExtractor.java   Patched Media3 file
```

Key ideas:

- **Accounts.** A Google account is identified by its email. Device files use the pseudo-account
  `"device"` (`LocalStorage.ACCOUNT`, shown as "This device"); a network share server is `"smb://host"`
  (`SmbPath.isSmb`). Several accounts merge into one library.
- **File ids.** Drive file id for Drive; the SAF **document URI string** for device files;
  `smb://host/share/path` for network shares (the player plays that URI through `SmbDataSource`).
  Code that must work for every source goes through `Storage` (`list`, `search`, `rename`, `remove`,
  `move`, `createFolder`, `read`). Check `Storage.isLocal` / `isSmb` instead of assuming Drive.
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
  through `VeltoretExtractorsFactory`. It (a) seeks to Info and Tracks elements stored after the first
  Cluster (files that otherwise play with no tracks, or fail with "Can't scale timecode prior to
  timecodeScale being set" because the Cues were read before a late Info) and (b) ignores SeekHead entries past the end of the file
  (incomplete downloads crashed with "position out of range"). Changes are marked `// Veltoret`. Keep
  the Apache license header and its modification note. When upgrading Media3, re-copy the upstream file
  and re-apply the marked changes.
- **Media3 is pinned to 1.9.4** to match the prebuilt `org.jellyfin.media3:media3-ffmpeg-decoder` (1.9.0+1).
  That FFmpeg build is **audio only** (DTS, TrueHD, AC3, E-AC3, FLAC, ALAC). There is no FFmpeg video
  decoding; video uses MediaCodec, with a software-decoder fallback. Don't claim otherwise in UI or docs.
- **Subtitles "Off" means off.** Track selection ignores the file's DEFAULT flag when subtitles are off
  (`setIgnoredTextSelectionFlags`) but still shows forced subtitles.
- **The play/pause button follows `playWhenReady`, not `isPlaying`**, and spins while the player is
  buffering (`PlayerScreen`; the TV player uses the same rule). `isPlaying` is false while a video loads,
  which showed ▶ on a video that was about to start. The slow-loading hint is `PlayerLoading.kt`.
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
- **`FilenameParser` regexes run on Android's ICU engine.** Escape `}` and similar characters, and write
  non-ASCII as `\x{hhhh}`; `FilenameParserDeviceTest` exists because the JVM accepted a pattern that crashed
  on devices.
- **TMDB fallbacks stay strict.** `movieCandidates` / `showCandidates` give the parser's guess first, then
  other folder/file titles, then trimmed variants marked `exactOnly` (exact title, close year). Trimmed
  variants must keep two words or a year. `LibraryScanner` tries at most `MAX_CANDIDATES` per title.
- **Show folder = nearest folder that names something.** Season folders, category folders ("English
  Shows") and quality folders ("480p x264") are skipped (`isNoiseFolder`); only plural category words
  count, so a show called "Show" or "Film" still works.
- **Release-site names are stripped only with a lowercase domain ending** (`SITE_PREFIX` / `SITE_SUFFIX`),
  so dotted titles like "The.Office.US" and "The.Fault.in.Our.Stars" survive.
- **`normalizeForCompare` keeps every script** (it strips only Latin accents); stripping all non-ASCII
  made Hindi and Japanese titles empty and unmatchable.
- **Show names drop season tags** (`SEASON_TAG`: "S01", "S01-S03", "Season 2", "Complete") because show
  folders are often named "Show.S01.1080p…"; `normalizeForCompare` deletes apostrophes ("Don't" == "Dont").
  Both were real "needs a match" bugs; keep the `FilenameParserTest` cases passing.
- **Unchanged UNMATCHED files are re-parsed on every scan** (`LibraryScanner.parsesDifferently`) and go back
  to PENDING only if the guess changed, so parser fixes reach existing libraries without re-querying TMDB
  for every unmatched file on every scan. MANUAL and IGNORED files are never re-parsed.
- **Scans the user starts run as a foreground job** (`SyncWorker.runNow(..., notify = true)`, `dataSync`
  type, notification channel `library-scan`) so they survive minimizing. Periodic and automatic scans
  stay plain background work: Android refuses foreground services started from the background.
  Cancel goes through `SyncWorker.cancel` → `LibraryScanner.cancel()`; it stops at the next checkpoint,
  and a folder that was cut short is never treated as "files gone" (nothing is deleted).
- **"More like this" shows only library titles** (`LibraryRepository.relatedMovies` / `relatedShows` over
  `movies()` / `shows()`, so offline it lists device copies only). TMDB's ids are stored per title in
  `recommendations` (kept for titles not owned yet), refreshed monthly by full scans and on opening a page;
  `catalog.prune()` removes rows for titles that left the library. Same type only: movies → movies, shows → shows.
- **Database changes need a migration.** Bump the version in `VeltoretDatabase`, add an `AutoMigration` or a
  manual `Migration`, and commit the new schema JSON in `app/schemas`. Never use destructive fallback;
  users would lose their libraries and watch history.

**Network shares (SMB)**
- **No socket read timeout in `SmbStorage`'s `SmbConfig`** (`withSoTimeout`). The player stops reading for a
  minute or more once its buffer is full; a read timeout on that idle connection killed smbj's packet
  reader while `isConnected` stayed true, so playback took 30–60 s to start and seeks hung. Request timeouts
  (`withTimeout`) are fine. Failed player reads mark the host `broken` so the retry reconnects.
- **SMB ids contain the host** (`smb://host/share/…`) because `media_files.driveId` is a primary key across
  all sources. Renaming or moving changes the id (like device files): forget the old ids and rescan.
- **Deleting on a share is permanent** (no trash); Files and TV Files must say so, as for device files.
  ZIP extraction and uploads are Drive-only: never offer them for `smb://` sources.
- **Release builds shrink with R8** (`optimization { enable = true }`). smbj, mbassador and dcerpc need the
  rules in `app/src/main/keepRules/rules.keep`; run `./gradlew :app:assembleRelease` after adding or
  upgrading any library, since R8 errors only show up there.
- **Passwords** live only in `SmbServerStore` (prefs file `smb_servers`, AES-GCM with an Android Keystore
  key) and are excluded from backups in `backup_rules.xml` / `data_extraction_rules.xml`.
- **Android 17 needs `ACCESS_LOCAL_NETWORK`** (Nearby devices) for any LAN traffic, including connecting.
  Ask through `rememberLocalNetworkAccess` before scanning for or connecting to servers.
- SMB titles are "needs the network" like Drive (`canPlayNow`); away from home they fail with a clear message.
- Adding a server: `AddServerViewModel` (shared) behind `AddServerDialog` (phone/tablet Settings) and
  `TvAddServerScreen` (TV Settings and onboarding); phone/tablet onboarding also uses `AddServerDialog`. Keep the logic in the view model. On TV the Connect
  button stays enabled while connecting (a disabled button drops the remote's focus) and ↓ from the
  Username/Guest chips goes to the next field or Connect, not the nearest button.
- **"Use your phone" (`data/pairing`)**: `PhoneSetupServer` is a tiny HTTP server that runs **only while
  the TV panel is open** (started/stopped by `TvPhoneSetupPanel`), accepts only home-network addresses,
  and serves the QR page at `/s/<random token>` (plain HTTP: browsers can't encrypt to a TV, so docs must
  say the password crosses the Wi-Fi unencrypted once) and `/pair` for **Send to TV** (`SendToTv` on the
  phone): fresh P-256 ECDH per attempt, the 6-digit code stretched with PBKDF2 into the AES-GCM key, and a
  **new code after every wrong try**. Both paths call `AddServerViewModel.attempt`, which returns the
  message the phone shows. Never log or persist what a phone sends.
- **`SendToTv` talks HTTP over a plain `Socket`, not OkHttp.** Android blocks cleartext `http://` in
  OkHttp/HttpURLConnection (no network security config allows it), which made every send fail with
  "Couldn't reach the TV" while the browser QR page worked. Discovery checks each found TV with `GET /pair`
  and keeps one entry per host: a reopened panel re-registers and stale announcements ("Mi Box (2)")
  linger on the network.
- **TV full-screen panels must fit 1080p without scrolling**; put Close/status and key buttons at the top
  (the add-server form and "Use your phone" panel both ran off the bottom before).
- `TvFolderPicker` won't pick a server's top level (its list of shares), like the "This TV" root.

**Offline mode**
- `Connectivity` (in `data/net`) exposes `online`. Offline, `LibraryRepository.movies()` / `shows()` /
  `episodeFiles()` return only titles and episodes with a device copy, and `PlaybackResolver` and the
  player prefer or substitute device copies (`LibraryRepository.deviceCopy`). Screens use
  `rememberOnline()` / `canPlayNow()` from `ui/util/Online.kt`. New lists of playable things must respect this.
- Offline scans skip Drive folders and TMDB rather than failing; coming back online triggers a rescan
  (`VeltoretApp`).
- After each online scan `ArtworkPrefetch` warms Coil's disk cache with the exact poster/backdrop URLs the
  screens use. If you change an image size in a screen, update `ArtworkPrefetch` too, or that artwork
  won't be available offline.

**Android TV (`ui/tv`, `player/TvPlayerScreen.kt`)**
- One APK. `Context.isTv()` (leanback feature or TV UI mode) makes `MainActivity` show `TvApp` /
  `TvOnboarding` and `PlayerActivity` show `TvPlayerScreen`; phones and tablets are unaffected. Screens
  reuse the phone ViewModels; only the UI differs. Don't call phone screens from TV code or vice versa.
- Every focusable thing is a `TvSurface` (or `TvButton`/`TvChip`/`TvListItem`/cards built on it) so focus
  looks the same everywhere. Each screen requests initial focus with `focusSoon()` (plain
  `requestFocus()` in the first frame can be dropped, leaving the remote with nothing focused).
  If the first item depends on data that loads later, request focus again when it arrives.
- Side panels and pickers hand focus back to the item that opened them: `TvSurface` records itself in
  `TvFocusMemory`, and `TvSidePanel` / `TvFolderPicker` call `ReturnFocusWhenClosed()`. Any new full-screen
  `Dialog` must call it too. Screens refocus their list only when `awaitReturn()` fails (opener gone).
- Going back up a folder (Files, folder picker) focuses the folder you came out of. Coming back from a
  detail page focuses the card that opened it (Home, grids, Search). Rows whose items act on focus
  (season chips) use `focusProperties { enter }` so entering them lands on the selected item.
- Home and detail pages draw artwork with `TvBackdrop` (full-screen picture + flat `VColors.BackdropDim`,
  no gradient) using the default `w1280` backdrop URL that `ArtworkPrefetch` caches; keep text in the
  left column at most ~560dp wide so it stays readable.
- Rows/grids use `PivotScrolling` so focus stays at a fixed spot. Text fields need `tvTextFieldExit()`,
  otherwise ↑/↓ are trapped inside the field.
- A focused item that changes with state (e.g. the Settings scan row while scanning) must stay one
  composable with changing text/actions; swapping it for another composable drops focus to the rail.
- Back order: content → rail → Home → exit. The rail's `focusProperties` keep ↑/↓ inside it.
- TVs have no real folder picker (`MediaLibrary.folderPickerAvailable` is false; only a stub answers).
  "Videos on this TV" asks for `READ_MEDIA_VIDEO` and browses MediaStore by path (`ms:` folder ids,
  `content://media/` file ids, read-only). Phones keep using SAF.
- Test TV changes on a Google TV emulator with the D-pad only (`adb shell input keyevent KEYCODE_DPAD_*`):
  check focus is always visible, never lost, and Back behaves.

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
- **Extraction needs free Drive space ≈ the ZIP's size** (the ZIP is removed only at the end; trashed files
  still count). `ExtractDialog` checks `DriveRepository.freeBytes` and won't start when it can't fit (unless an
  earlier attempt's folder exists). A full Drive is `DriveStorageFullException` (403 `storageQuotaExceeded`):
  `ExtractWorker` fails at once instead of retrying, since each retry downloads the whole ZIP again.

**UI and design**
- **Smooth scrolling: never read an animation value during composition in list items.** Read it inside
  `graphicsLayer { }` / draw blocks (`rememberPulse` returns a `State`; `pressScale` reads in the layer),
  otherwise every loading poster recomposes every frame. `entrance` plays once (saved state) because lazy
  lists replayed it each time a row scrolled back into view. Judge smoothness on a **release** build:
  debug Compose is several times slower (Home on a Samsung tablet: ~10% janky frames in debug, ~2% in release).
- Dark, cinematic design with **no gradients anywhere**: flat surfaces, hairline outlines, amber accent.
  Use the `VColors` tokens and shared components (`Components.kt`, `Motion.kt`).
- **Use `MaterialTheme.colorScheme.background` for page backgrounds, never `VColors.Background`.**
  "Pure black" mode changes the theme background; hard-coded colors show as lighter bands.
- Fonts: Fraunces for titles, Inter for everything else.
- Check new screens at all three width classes, phone and tablet, portrait and landscape.
- The player keeps the system bars hidden (immersive), including while sheets are open.

## Public repository rules

- **Never commit secrets.** The TMDB key lives only in git-ignored `local.properties` (`tmdb.apiKey=…`)
  and is compiled into debug builds as `BuildConfig.BUNDLED_TMDB_KEY`. Release builds include it **only**
  when the maintainer sets `tmdb.embedInRelease=true` in `local.properties` for APKs shared privately
  (SETUP.md "Share" section); public builds never contain a key. Release signing comes from git-ignored
  `keystore.properties`. Never commit `*.jks`, `*.keystore`, `keystore.properties`, APKs/AABs or
  `app/release/`; those built APKs may contain the key. Each user registers their own
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
