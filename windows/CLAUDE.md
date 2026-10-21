# CLAUDE.md — Veltoret for Windows

A native Windows port (C# / .NET 10 / WPF) of the Android app Veltoret (github.com/pntapps/Veltoret, GPL-3.0).
Same features: a Movies / TV Shows library from Google Drive, folders on this PC and SMB network shares, TMDB
metadata, a full-featured player (LibVLC), Watchlist and reminders, a file manager, ZIP extraction to Drive,
Chromecast, and Play on TV (sending to Veltoret on an Android TV).

**Specs:** `../docs/spec/*.md` (shared by all three apps) describe every Android feature, string and rule in detail. Read the spec for your
area before writing code; it is the source of truth for behaviour and UI text. When a spec is unclear, read the
Android source in `../android/` (this repository holds android/, windows/ and mac/).

## Build and test

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
dotnet build Veltoret.sln -v q -nologo
dotnet test tests\Veltoret.Core.Tests -v q -nologo
dotnet run --project src\Veltoret.App
```

## Layout and module ownership

```
src/Veltoret.Core/          net10.0, no UI. Everything testable lives here.
  Data/                     SQLite (Microsoft.Data.Sqlite + Dapper): Entities, VeltoretDb (schema/migrations), Daos   [shared]
  Storage/Storage.cs        IFileSource + Storage facade (Drive, This PC, SMB)                                       [shared]
  Settings/                 SettingsStore (settings.json)                                                            [shared]
  Library/                  FilenameParser, LibraryScanner, LibraryRepository, WatchRepository, PlayTargets…        [core]
  Tmdb/                     TMDB API client, models, TmdbRepository (pickBest matching)                              [core]
  Local/                    LocalFileSource (folders on this PC)                                                     [core]
  Net/                      Connectivity                                                                             [core]
  Images/                   ImageCache (TMDB artwork disk cache, offline)                                            [core]
  Drive/, Auth/             Google OAuth (loopback+PKCE), Drive REST, uploads, ZIP extraction                        [drive]
  Smb/                      SMB file source (SMBLibrary), discovery, server store                                   [network]
  Cast/, TvLink/, Pairing/  Chromecast (Cast v2), Play on TV client, pairing crypto, stream server                   [network]
  Plans/                    Watchlist, reminders, upcoming episodes, VoiceQuery                                      [plans]
src/Veltoret.App/           net10.0-windows WPF app
  Themes/Tokens.xaml        Design tokens (colors, fonts, type scale)                                                [shared]
  Themes/Controls.xaml      Shared control styles (buttons, chips, cards, scrollbars…)                               [ui]
  Services/AppServices.cs   Wiring with per-module partial files AppServices.<Module>.cs                             [shared]
  Services/IPlaybackLauncher.cs  What Play buttons call                                                              [shared]
  Navigation/Navigator.cs   Routes + page factories                                                                   [shared]
  Shell/, Controls/, Pages/{Home,Library,Details,Search,FixMatch,Onboarding}/                                        [ui]
  Player/                   Player window, view model, LibVLC, subtitles, track memory                               [player]
  Pages/Files/, Accounts/   Files manager, Archives, Google account connect                                          [drive]
  Network/                  Add network server dialog, Network servers section, Cast/Play on TV UI                   [network]
  Pages/Settings/, Plans/, Tray/   Settings page, reminder dialog, toasts, notification-area icon                    [plans]
tests/Veltoret.Core.Tests/  xUnit; port every Android unit test for the code you port
```

**Rules for parallel work.** Write only inside the folders your module owns. Shared files (`[shared]`) may be
extended only additively (new members, new routes, new tokens) — never rename or remove what others use. Wire
your services in your own `Services/AppServices.<Module>.cs` partial (implement the `Init<Module>` /
`Start<Module>` partial methods declared in AppServices.cs) and register your pages there with
`Navigator.Register<TRoute>(...)`. If the build fails in another module's folder, don't fix it — wait a minute and
rebuild, or exclude nothing and report it. Settings sections owned by other modules are UserControls those
modules provide (`Accounts/AccountsSection`, `Network/NetworkServersSection`); the Settings page hosts them.

## Windows product decisions (made for the port)

- The device source is **"This PC"** (account id `"device"`, `Accounts.Device`). File ids are full local paths.
- Deleting a file on This PC sends it to the **Recycle Bin** (the Windows convention); the dialog says so.
  SMB deletes stay permanent; Drive goes to trash by default, as on Android.
- "Only on Wi-Fi" style checks map to **unmetered networks**.
- Veltoret keeps running in the **notification area** when its window is closed (`RunInBackground`, default on),
  so reminders, new-episode alerts and scans keep working; "Quit" in the tray menu exits.
- Picture-in-picture becomes an **always-on-top mini player** window.
- **Touchscreens** (tablets like 2-in-1s): WPF's WM_POINTER touch stack is on (`EnablePointerSupport` in the csproj;
  the legacy stack delivers no touches to LibVLCSharp's overlay window). `Controls/TouchInput` installs drag-to-scroll
  with momentum for every ScrollViewer (`TouchScroll`), room for the touch keyboard (`TouchKeyboard`), and Enter →
  next field. Windows sends the mouse click for a touch *after* the finger lifts, so drags swallow it and the player
  ignores touch-made mouse events (`TouchInput.IsFromTouch`); its gestures live in `PlayerWindow.Touch.cs`.
- **HDR**: `HdrProbe` (Core) reads HDR10/HLG/Dolby Vision from MKV/MP4 headers, else the file name. On an HDR-capable
  display an HDR video turns on Windows HDR before it starts (setting "HDR for HDR videos", default on); the player's
  "HDR" chip toggles it; closing the player restores the display's previous state (`Player/HdrDisplay`).
- Playback goes through LibVLC. Local files play by path; Drive and SMB play through a seekable stream
  (`Storage.OpenRead` → `StreamMediaInput`). Hardware decoding with automatic software fallback.
- Google sign-in: OAuth 2.0 installed-app flow (system browser, loopback redirect, PKCE). Users bring their own
  "Desktop app" OAuth client (JSON imported in Settings) and their own TMDB key, as on Android. No server.
- Play on TV: Windows is the *phone* side only (sends to Veltoret on Android TV). The TV-side listener and the
  TV interface are not ported.
- English (US) only.

## Don't break these (carried over from Android; see the Android CLAUDE.md for the full history)

- **TMDB matching is strict on purpose** (`TmdbRepository.PickBest`). Don't loosen it.
- **FilenameParser** is a line-by-line port. Keep `FilenameParserCorpusTests` identical to the Android corpus;
  add a line for every name that parses wrong. Use `[0-9]` not `\d`, `ToLowerInvariant`, culture-invariant regex.
- **MatchState MANUAL and IGNORED survive rescans**; unchanged UNMATCHED files are re-parsed every scan.
- A folder whose scan was cancelled or failed is never treated as "files gone".
- **Device copies win** (queries order `accountEmail = 'device'` first). Offline, only This PC copies are listed
  and played.
- **Database changes need a migration** (append to `VeltoretDb.Migrations`, bump `Version`); never drop data.
- **Subtitles "Off" means off.** The play/pause button follows "play when ready", spinning while buffering.
- Watched rule: ≥ 92% or < 2 minutes left. Progress keyed by what was watched (`WatchKeys`), not the file.
- **No gradients anywhere** (except TMDB's unmodified logo). Flat surfaces, hairline outlines, amber accent.
  Page backgrounds use `{DynamicResource Brush.Background}` so "Pure black" works.
- Fonts: Fraunces for titles, Inter for everything else.
- **Never log or persist** what a paired device sends; passwords and tokens only in DPAPI-encrypted stores.
- Servers (Cast stream server) answer **home-network addresses only**, behind a random token.

## Public repository rules

- Never commit secrets: no TMDB key (developers use the `VELTORET_TMDB_KEY` environment variable), no OAuth
  client JSON, tokens, or personal paths.
- Keep `LICENSE` (GPL-3.0), `third_party/fonts/OFL.txt`, and TMDB's attribution (logo + "This application uses
  TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.") in Settings → About
  and onboarding. Every dependency must be GPL-3.0 compatible.
- Don't name real piracy or release sites; use made-up examples like `ReleaseSite.at`.
