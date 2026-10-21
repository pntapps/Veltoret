# CLAUDE.md — Veltoret for Mac

A native macOS port (Swift 6 toolchain in Swift 5 language mode, SwiftUI + AppKit, macOS 14+) of Veltoret
(`../android`, `../windows` in this repository, GPL-3.0). Same features:
a Movies / TV Shows library from Google Drive, folders on this Mac and SMB network shares, TMDB metadata, a
full-featured player (VLCKit / LibVLC), Watchlist and reminders, a file manager, ZIP extraction to Drive, Chromecast,
and Play on TV (sending to Veltoret on an Android TV).

**Sources of truth, in order:**
1. `../docs/spec/*.md` (shared by all three apps) — every feature, string and rule (written for the Windows port; "This PC" → "This Mac",
   "Click" stays, Windows-only mechanics → the Mac equivalents below).
2. The Windows app: `../windows/src` (C#). Port it **line by line** for logic (parser, scanner, TMDB
   matching, player logic, Drive, Cast, Plans…). Its `docs/CONTRACTS.md` lists the Windows APIs and deviations.
3. The Android app: `../android/app/src` (Kotlin), when the Windows code or spec is unclear.
A change to one app's behaviour, wording or design usually belongs in all three; keep `../docs/spec` true.

## Build and test

Documents/ is iCloud-synced (File Provider adds Finder info that breaks code signing), so **always build with a
scratch path outside the project**. Each parallel worker uses its own:

```bash
cd mac
swift build --scratch-path ~/Library/Caches/VeltoretBuild/<you> --target <YourTarget>
swift test  --scratch-path ~/Library/Caches/VeltoretBuild/<you> --filter <YourTestTarget>
Scripts/build-app.sh            # dist/Veltoret.app (release, VLCKit embedded, ad-hoc signed)
Scripts/fetch-vlckit.sh         # downloads Vendor/VLCKit.xcframework (not committed, 400 MB)
```

**Checking UI without Screen Recording permission:** the app renders its own window to PNGs and quits:
`VELTORET_DATA_DIR=/tmp/v VELTORET_SNAPSHOT_DIR=/tmp/shots VELTORET_SNAPSHOT_ROUTES=home,movies,shows,movie:603,show:1396,search,files,settings,fixmatch dist/Veltoret.app/Contents/MacOS/Veltoret`
(`Sources/Veltoret/DevSnapshots.swift`; seed `/tmp/v/veltoret.db` with sqlite3 for a populated library). Say what
you looked at; VLC video and the traffic lights don't appear in these images.

## Layout and module ownership

```
Package.swift                                                                                   [lead]
Sources/VeltoretKit/          Logic, no UI. Shared foundation + core.
  Data/ Storage/ Settings/ Util/ Services/AppServices.swift  AppPaths.swift                      [shared, lead]
  Services/CoreModule.swift, Library/ Tmdb/ Local/ Net/ Images/                                  [core]
Sources/VeltoretPlayerKit/    MediaFormats, SubtitleEngine, HdrProbe, PlayerPrefsStore, Sidecars, EpisodeNav,
                              PlayerMath/Format, MediaStreamServer (loopback HTTP range server)  [playerkit]
Sources/VeltoretDrive/        Google OAuth (loopback+PKCE), Drive REST, DriveFileSource, uploads, ZIP extraction [drive]
Sources/VeltoretSmb/          SMB (AMSMB2): SmbFileSource, SmbPath, discovery (Bonjour + NetBIOS), server store [smb]
Sources/VeltoretCast/         Chromecast (Cast v2), CastServer, TvLink client, Pairing crypto, SendToTv     [cast]
Sources/VeltoretPlans/        Watchlist, reminders, upcoming episodes, VoiceQuery, notifier protocols        [plans]
Sources/VeltoretUI/           Design system (tokens, fonts, components), Navigator, shell, dialogs, toasts   [ui]
Sources/FeatureLibrary/       Home, Movies, TV Shows, Search, details, collection, Fix match, onboarding     [library-ui]
Sources/FeaturePlayer/        Player window (VLCKit), mini player, PlaybackLauncher                         [player]
Sources/FeatureFiles/         Files manager, Archives, extract dialog, Google accounts UI                   [files-ui]
Sources/FeatureNetwork/       Add network server, servers section, Cast button/panel/remote, Play on TV UI  [network-ui]
Sources/FeatureSettings/      Settings page, reminder dialog, notifications, menu bar item, voice search    [settings-ui]
Sources/Veltoret/             App entry, AppDelegate, wiring (calls every <Module>Module.initialize/start)  [lead]
Tests/<Target>Tests/          XCTest; port every Windows/Android unit test for the code you port
```

**Rules for parallel work.** Write only inside the folders your module owns. Shared files may be extended only
additively (new members) — never rename or remove what others use; tell the lead if you need a shared change.
Each module declares its services as `public static var` in an `extension AppServices` inside its own target
(`AppServices+<Module>.swift`) and wires them in `<Module>Module.initialize()`. If the build fails in a file you
don't own, don't fix it: wait a minute and rebuild (another worker is mid-change). Build your own target with
`--target` so you're blocked as little as possible. **Stub first:** publish your public API (compiling, even if
bodies are simple) early, so modules that depend on you can build; then implement.

## Mac product decisions (made for the port)

- The device source is **"This Mac"** (account id `"device"`, `Accounts.device`). File ids are full POSIX paths.
  The app is not sandboxed (distributed outside the App Store), so plain paths work; the folder picker is NSOpenPanel.
  The This Mac root lists: Home, Movies, Downloads, Desktop and every mounted volume (`/Volumes`, external & USB).
- Deleting a file on This Mac moves it to the **Trash** (`FileManager.trashItem`); the dialog says so. SMB deletes stay
  permanent; Drive goes to trash by default, as on Android.
- "Only on Wi-Fi" checks map to **non-expensive, non-constrained networks** (`NWPathMonitor`).
- Veltoret keeps running with a **menu bar item** when its window is closed (`runInBackground`, default on), so
  reminders, new-episode alerts and scans keep working; "Quit Veltoret" (⌘Q) exits. "Open at login" uses SMAppService.
- Picture-in-picture becomes an **always-on-top mini player** window (floating NSPanel), as on Windows.
- Playback goes through VLCKit 3 (LibVLC). Local files play by path; Drive and SMB play through
  `MediaStreamServer` (loopback HTTP with Range, random token, 127.0.0.1 only) over `Storage.openRead`.
- **Now Playing + media keys**: the player publishes MPNowPlayingInfoCenter and handles MPRemoteCommandCenter.
- Google sign-in: OAuth 2.0 installed-app flow (system browser, loopback redirect, PKCE). Users bring their own
  "Desktop app" OAuth client (JSON imported in Settings) and their own TMDB key, as on Android/Windows. No server.
- Secrets (Google tokens, OAuth client, SMB passwords, paired TV keys) live in the **Keychain** (`AppServices.secrets`).
- Notifications: UserNotifications with **Play** and **Snooze 1 hour** actions, artwork attached.
- Voice search: Speech framework (SFSpeechRecognizer, on-device when available).
- Play on TV: the Mac is the *phone* side only (sends to Veltoret on Android TV); the TV side isn't ported.
- Mac idioms on top of the shared design: hidden title bar with traffic lights over the content, a left sidebar rail,
  full menu bar (File / View / Playback / Go / Window / Help) with standard shortcuts (⌘F search, ⌘, settings,
  ⌘[ back, ⌘1–⌘6 tabs, ⌘R scan library), two-finger swipe back, context menus, drag and drop of folders onto
  Settings / Files to add them.
- English (US) only.

## Don't break these (carried over from Android/Windows)

- **TMDB matching is strict on purpose** (`TmdbRepository.pickBest`). Don't loosen it.
- **FilenameParser** is a line-by-line port. Keep `FilenameParserCorpusTests` identical to the Android/Windows corpus;
  add a line for every name that parses wrong. Use `[0-9]` not `\d`, lowercased with `en_US_POSIX`, NSRegularExpression.
- **MatchState MANUAL and IGNORED survive rescans**; unchanged UNMATCHED files are re-parsed every scan.
- A folder whose scan was cancelled or failed is never treated as "files gone".
- **Device copies win** (queries order `accountEmail = 'device'` first). Offline, only This Mac copies are listed and played.
- **Database changes need a migration** (append to `VeltoretDb.migrations`, bump `version`); never drop data.
- **Subtitles "Off" means off.** The play/pause button follows "play when ready", spinning while buffering.
- Watched rule: ≥ 92% or < 2 minutes left. Progress keyed by what was watched (`WatchKeys`), not the file.
- **No gradients anywhere** (except TMDB's unmodified logo). Flat surfaces, hairline outlines, amber accent.
  Page backgrounds use `Theme.background` (which follows "Pure black").
- Fonts: Fraunces for titles, Inter for everything else (bundled, registered at launch).
- **Never log or persist** what a paired device sends; passwords and tokens only in the Keychain.
- Servers (Cast stream server) answer **home-network addresses only**, behind a random token. The player's
  MediaStreamServer answers 127.0.0.1 only.

## Public repository rules

- Never commit secrets: no TMDB key (developers use the `VELTORET_TMDB_KEY` environment variable), no OAuth client
  JSON, tokens, or personal paths. Never commit `Vendor/VLCKit.xcframework`.
- Keep `LICENSE` (GPL-3.0), `third_party/fonts/OFL.txt`, and TMDB's attribution (logo + "This application uses TMDB and
  the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.") in Settings → About and onboarding.
  Every dependency must be GPL-3.0 compatible.
- Don't name real piracy or release sites; use made-up examples like `ReleaseSite.at`.
