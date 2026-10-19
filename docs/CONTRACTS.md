# Cross-module contracts

Modules are built in parallel. These names and signatures are fixed so modules can call each other before the
other side exists. Implement exactly what your module provides; call only what's listed for the others. If you
need something that isn't here, add it to your own module and note it at the end of this file
(append-only, under "Additions").

All services are reached through `Veltoret.App.Services.AppServices.<Property>`. Each module declares its
properties in its own partial `src/Veltoret.App/Services/AppServices.<Module>.cs`.

## Core module (`[core]`) provides

```csharp
// AppServices.Core.cs
public static TmdbRepository Tmdb;            // Veltoret.Core.Tmdb
public static LibraryScanner Scanner;         // Veltoret.Core.Library
public static LibraryRepository Library;      // Veltoret.Core.Library
public static WatchRepository Watch;          // Veltoret.Core.Library (exists)
public static PlaybackResolver Resolver;      // Veltoret.Core.Library (exists)
public static Connectivity Connectivity;      // Veltoret.Core.Net
public static ImageCache Images;              // Veltoret.Core.Images
public static ScanScheduler Scans;            // Veltoret.Core.Library
```

- `TmdbRepository`: `Task<List<TmdbMovieSummary>> SearchMovies(string q, int? year = null)`, `SearchShows(...)`
  → `List<TmdbTvSummary>`, `FindMovie(title, year, exactOnly)`, `FindShow(...)`, `EnsureMovie(int id)`,
  `EnsureShow(int id, IReadOnlySet<int> seasons)`, `EnsureRecommendations(string type, int id)`,
  `Task<string?> Trailer(string type, int id)` (YouTube key), `Task<TmdbCollection> Collection(int id)`,
  `Task ValidateKey()` (throws `TmdbKeyMissingException` / `HttpRequestException`), static `PickTrailer`.
- `LibraryScanner`: `ScanState State`, `event Action<ScanState> StateChanged`, `Task ScanAll()`,
  `Task Scan(IReadOnlySet<long>? folderIds)`, `void Cancel()`, `Task ApplyManualMatch(IReadOnlyList<string> fileIds, MediaKind kind, int tmdbId)`,
  `Task Ignore(IReadOnlyList<string> ids)`, `Task Restore(IReadOnlyList<string> ids)`,
  `Task OnFileRenamed(string oldId, string newId, string newName)`, `Task OnFilesRemoved(IReadOnlyList<string> ids)`.
  `ScanState` mirrors Android's (Running, Phase, FilesFound, ToMatch, Matched, Error, LastFinishedAt, FolderIds,
  FoldersTotal, FoldersDone, DoneFolderIds, CurrentFolderId, CurrentFolder, CurrentPath, NewFiles, Identified,
  Cancelled, FolderErrors, `Covers(id)`, `Waiting(id)`, `Progress`).
- `LibraryRepository` (offline-aware: offline returns only titles/episodes with a This PC copy):
  `Task<List<MovieRow>> Movies()`, `Task<List<ShowRow>> Shows()`, `Task<List<MediaFileEntity>> EpisodeFiles()`,
  `Task<List<MovieRow>> RelatedMovies(int movieId)`, `Task<List<ShowRow>> RelatedShows(int showId)`,
  `Task<List<TitleSource>> MovieSources()`, `Task<List<TitleSource>> ShowSources()`,
  `Task<MediaFileEntity?> DeviceCopy(MediaFileEntity file)`, `Task AddFolder(string account, string folderId, string name, LibraryType type)`,
  `Task RemoveFolder(long folderId)`, `Task RemoveAccount(string account)` (folders, files, subtitles, archives, prune).
- `Connectivity`: `bool IsOnline`, `bool IsMetered`, `event Action<bool> OnlineChanged`.
- `ImageCache`: `Task<string?> GetFile(string? url, CancellationToken ct = default)` → local cached file path
  (downloads once; works offline from disk), `Task Prefetch(IEnumerable<string> urls)`.
- `ScanScheduler`: `void Start()` (every 12 h + on reconnect + `RunNow`), `Task RunNow(IReadOnlySet<long>? folderIds = null)`.
- `LocalFileSource : IFileSource` registered with `Storage` for account `"device"`.

## UI module (`[ui]`) provides

- `Themes/Controls.xaml`, merged in App.xaml, with these style keys (all modules use them):
  `Button.Primary` (amber filled), `Button.Secondary` (surface + hairline), `Button.Text`, `Button.Icon`
  (round, takes a Path/geometry or Segoe Fluent Icons glyph as Content), `Chip` (ToggleButton), `TextBox`,
  `PasswordBox`, `ComboBox`, `CheckBox`, `Toggle` (ToggleButton switch), `ProgressBar`, `Slider`, `ListItem`,
  `Card` (Border style), `Divider`, `ScrollViewer` (thin dark scrollbars, implicit), `MenuItem`/`ContextMenu`.
- `Veltoret.App.Controls.DialogWindow` — a borderless dark modal window base: `DialogWindow.Show(Window owner, string title, FrameworkElement content, params DialogButton[] buttons)`
  and subclassable for custom dialogs. `Veltoret.App.Controls.Confirm.Ask(owner, title, message, confirmText, danger: bool) → bool`.
- `Veltoret.App.Controls.FolderPickerDialog.Pick(Window owner, string account) → Task<(string Id, string Name)?>`
  — browses any source through `Storage` (This PC uses the native `Microsoft.Win32.OpenFolderDialog`).
- `Veltoret.App.Controls.AsyncImage` — an Image that loads a URL through `AppServices.Images`.
- `Veltoret.App.Controls.Toast.Show(string message, string? actionText = null, Action? action = null)` — in-app snackbar.
- The shell (`MainWindow`): nav rail (Home, Movies, TV Shows, Search, Files, Settings), page host bound to
  `AppServices.Navigator`, Back (button + Alt+Left + mouse back button), title bar.
- Pages registered for: HomeRoute, MoviesRoute, ShowsRoute, SearchRoute, MovieDetailRoute, ShowDetailRoute,
  CollectionRoute, FixMatchRoute, OnboardingRoute.

## Player module (`[player]`) provides

- `AppServices.Playback : IPlaybackLauncher` (see Services/IPlaybackLauncher.cs).
- `Veltoret.App.Player.PlayerWindow` (full window player; F11/double-click full screen; mini player).
- `Veltoret.App.Player.PlayerPrefs` (track memory).
- Hooks for Cast: `PlayerWindow.Current` (static, nullable), `double PositionSeconds`, `void PauseForCast()`,
  `void ResumeAfterCast(long positionMs)`, and a placeholder area `CastButtonHost` (ContentControl) in the top bar
  where the network module puts its cast button.

## Drive module (`[drive]`) provides

```csharp
public static GoogleAuthService GoogleAuth;   // Veltoret.Core.Auth
public static DriveRepository Drive;          // Veltoret.Core.Drive
public static TransferService Transfers;      // uploads + ZIP extraction jobs (Veltoret.Core.Drive)
```
- `GoogleAuthService`: `bool HasClient`, `void ImportClientJson(string path)`, `Task<AccountEntity> SignIn(CancellationToken ct)`,
  `Task SignOut(string email)`, `Task<string> AccessToken(string email, CancellationToken ct)`.
- `DriveFileSource : IFileSource` registered with Storage for Google account emails.
- UI: `Veltoret.App.Accounts.AccountsSection` (UserControl for Settings: Google accounts, connect/remove,
  OAuth client import), `Veltoret.App.Accounts.ConnectGoogle.Run(Window owner) → Task<AccountEntity?>` (used by onboarding),
  Pages for FilesRoute and ArchivesRoute, `Veltoret.App.Pages.Files.ExtractDialog`.

## Network module (`[network]`) provides

```csharp
public static SmbServerStore SmbServers;      // Veltoret.Core.Smb
public static CastController Cast;            // Veltoret.Core.Cast (Chromecast + Play on TV)
```
- `SmbFileSource : IFileSource` for `smb://host` accounts.
- UI: `Veltoret.App.Network.AddServerDialog.Show(Window owner) → Task<string?>` (returns the server account id),
  `Veltoret.App.Network.NetworkServersSection` (UserControl for Settings), `Veltoret.App.Network.CastButton`
  (UserControl; placed in the player's `CastButtonHost` and on Home), `Veltoret.App.Network.PlayOnTvSection`
  (UserControl for Settings: paired TVs, pair with code).

## Plans module (`[plans]`) provides

```csharp
public static PlansRepository Plans;          // Veltoret.Core.Plans
public static UpcomingService Upcoming;       // Veltoret.Core.Plans
```
- `PlansRepository`: `Task<bool> IsInWatchlist(string type, int id)`, `Task SetWatchlist(string type, int id, bool on)`,
  `Task<List<WatchlistEntity>> Watchlist()`, `Task<List<ReminderEntity>> RemindersFor(string type, int id)`,
  `Task<long> AddReminder(string type, int id, int? season, int? episode, string title, DateTimeOffset at)`,
  `Task RemoveReminder(long id)`, `Task Restore()`.
- `Veltoret.Core.Plans.VoiceQuery` (port of Android VoiceQuery).
- UI: `Veltoret.App.Plans.ReminderDialog.Show(Window owner, string type, int id, int? season, int? episode, string title, string? airDate) → Task<bool>`,
  the Settings page (registered for SettingsRoute) hosting the other modules' sections, the notification-area
  icon, Windows toasts (Play / Snooze 1 hour), `Veltoret.App.Plans.VoiceSearch.Listen() → Task<string?>`
  (Windows speech; null when unavailable).

## Additions

- (lead) The Drive module's account UI lives in namespace `Veltoret.App.AccountsUi` (not `Veltoret.App.Accounts`,
  which would hide `Veltoret.Core.Storage.Accounts` inside `Veltoret.App.*`). Never create a namespace named
  `Accounts` under `Veltoret.App`.

- (lead) `Veltoret.App.App.ShowMainWindow()` shows/focuses the main window (tray, toasts, second launch);
  `App.StartedInBackground` is true with `--background` (the window isn't shown at start); `App.Log(Exception)`
  appends to `%LOCALAPPDATA%\Veltoret\logs\errors.log`. Single instance is handled in App.
- (lead) Icons: `pack://application:,,,/Assets/Veltoret.ico` (window/tray), `pack://application:,,,/Assets/Images/logo-256.png`.
- (network/SMB) `AppServices.SmbFiles : SmbFileSource` (registered with Storage) and `AppServices.SmbDiscovery` besides
  `SmbServers`. `SmbFileSource.Test(server, password)`, `Disconnect(account)`, `DisconnectAll()`. `SmbServerStore`:
  `Servers`, `Server(account)`, `Save(server, password)`, `Remove(account)`, `Password(account)` (null = sign in again),
  `event Changed`; file `AppPaths.Secrets\smb_servers.json` (DPAPI, entropy "veltoret-smb"). `SmbPath` (ids),
  `SmbErrors.Describe(e)` (user sentences), `SmbAccounts.AddServerAccount/EnsureServerAccounts` (account rows,
  back-filled at InitSmb). `SmbFileSource.OpenRead` returns `SmbReadStream` (seekable, thread-safe, 1 MiB chunks,
  2-chunk read-ahead, reconnects once on a dropped connection; also `ReadAt(position, buf, off, count)`).
- (network/SMB) `AddServerDialog.Show(owner, SmbServer? editing)` overload = "Sign in again" for a saved server. After a
  successful sign-in the dialog itself offers the typed folder and "Choose a folder…" (FolderPickerDialog) with
  Movies / TV Shows buttons (`Library.AddFolder` then `Scans.RunNow({id})`), then "Done"; it returns the account id
  even if no folder was added. Cancel before signing in returns null.
- (network/SMB) `NetworkServersSection` shows each saved server as a full panel (name, `\\host · user`, its library
  folders with remove, "Add library folder", "Sign in again", "Remove" with the spec's confirm text) plus
  "Add network server". The Settings page should therefore not render a second generic panel for `smb://` accounts.
  Removing an SMB account from elsewhere must go through `NetworkServersSection.ConfirmAndRemove(owner, account)` or
  `NetworkServersSection.RemoveServer(account)` (library rows + password + connection).
- (network/SMB) Deviations: guest = user "Guest" with an empty password via NTLM (SMBLibrary); no port other than 445
  (SMBLibrary's SMB2Client has no port parameter); a quick TCP probe (8 s) runs before connecting so "server off" fails
  fast; SMB1-only servers fail with "The server doesn't support this". Requests on one connection are serialized.

- (core) `LibraryRepository.AddFolder` returns `Task<long?>` (new folder id, null when already in the library) and adds
  the "This PC" account row for `device` folders. Extra read methods (Android parity): `Movie/MovieFiles/Show/Seasons/
  Episodes/ShowFiles/Credits/Unmatched/Ignored/FolderCounts/AllEpisodes/Archives/ForgetArchive/File/Episode/
  SubtitlesBeside/Search/NextEpisodeFile/PreviousEpisodeFile/AccountList/Folders/EnsureDeviceAccount`. These are plain
  queries: re-run on `Db.Changed` / `Connectivity.OnlineChanged`. `RemoveAccount` clears library rows + the account row
  only; tokens/passwords are the Drive/SMB modules' job.
- (core) `ScanScheduler`: also `RequestAutomatic()` (dropped while a scan is queued/running; use after renames, moves,
  extraction, Fix match), `Cancel()` (stops the running scan, drops queued ones), `bool Busy`. `RunNow` = user scan
  (queued; the Task completes when that scan finishes). Periodic = hourly check, scan when `LastScanAt` is 12 h old
  (onboarding complete only); back online → automatic scan. Prefetches artwork after online, non-cancelled scans.
- (core) `LibraryScanner`: `IsBusy`; `StateChanged` fires on the scanning thread (marshal to the UI dispatcher).
  `OnFileRenamed(oldId, newId, newName)`: same id → name updated (re-parsed next scan); new id → the row moves to the
  new id keeping its match. Scan is skipped (returns) while another scan runs.
- (core) `Connectivity`: `Start()`, `Task<bool> Refresh()`, `Set(bool)`, settable hooks `SystemCheck` (Func<bool?>, NCSI)
  and `MeteredCheck` (Func<bool>) — the App wires both from Windows.Networking.Connectivity in AppServices.Core.cs.
  `OnlineChanged` fires on a background thread.
- (core) `ImageCache`: `PathFor(url)`, `IsCached(url)`, `Trim()`; cache dir is `AppPaths.ImageCache` (`images`), file
  name = SHA-1 hex of the URL, 512 MB LRU (trimmed to 90%). `AppServices.Artwork : ArtworkPrefetch` (`Urls()`, `Run()`).
- (core) `AppServices.LocalFiles : LocalFileSource` (`Root = "device-root"`, `FolderMime`, `Normalize(path)`,
  `DriveName(DriveInfo)`), plus `Veltoret.Core.Local.MimeTypes.ForName(name)`. Root lists ready Fixed + Removable drives
  ("Data (D:)" / "Local Disk (C:)" / "USB Drive (E:)"); hidden/system entries are skipped; folders first, then by name.
  Remove and DeletePermanently both go to the Recycle Bin (SHFileOperation, FOF_ALLOWUNDO); on drives without a Recycle
  Bin Windows deletes permanently.
- (core) `TmdbKeyMissingException` derives from `HttpRequestException`. `TmdbRepository.PickBest(...)` and `YearOf` are
  public static; `TmdbClient.Json` (snake_case options) and `TmdbClient.BuildUrl` are public for tests.
- (core) Fixed `MediaFileDao.ShowSeasons()` (Dapper couldn't construct the positional `ShowSeason` record from SQLite
  Int64 columns); signature unchanged.

- (plans) `PlansRepository` also has `Reminders()` (all, soonest first), `AddReminder(type, id, season, episode, title,
  long atMs, bool addToWatchlist)`, `Snooze(type, id, season, episode, title)` (now + 1 h, never touches the watchlist),
  `Fire(id)` (fire-once: posts only when its DELETE removed the row; keeps the row while Windows notifications are off),
  `RescheduleAll()`, settable `Notifier : IPlanNotifier` and `Alarms : IReminderAlarms`. Re-query on
  `Db.Changed` ("watchlist", "reminders"); there is no separate PlansChanged event.
- (plans) `Veltoret.Core.Plans.Plans` (static rules: `QuickTimes`, `AirLabel`, `IsUpcoming`, `ReminderLabel`, `Due`,
  `ToMillis`, `StillAiring`, `Parse`), `OpenTarget` record, `PlanFormat` (`EpisodeCode`, `Runtime`, `Relative`, `Date`),
  `ReminderScheduler` (in-process timer; re-checks at least every 30 min), `UpcomingService` (`Start()`, `OnOnline()`,
  `Run()`; alerted keys in `AppSettings.AlertedEpisodes` as `"yyyy-MM-dd|showId:season:episode"`, `null` printed as
  "null", newest 200 kept).
- (plans) Reminder scheduling = option 1 of spec 5.3 only (in-process timer while Veltoret runs in the notification
  area + `Restore()` at every start, on resume and on clock changes). No scheduled toasts.
- (plans) `Veltoret.App.Plans.ToastNotifier.Open(OpenTarget)` (UI thread) shows the main window, navigates to the
  title and plays it when `Play`; `ToastNotifier.CanPostNow()` = Windows notifications on for Veltoret.
  `ToastNotificationManagerCompat.OnActivated` is hooked in `InitPlans` (before the window shows).
- (plans) **App.OnStartup (lead):** treat `ToastNotificationManagerCompat.WasCurrentProcessToastActivated()` like
  `--background` (don't show the window at start): the activation handler itself shows the window for open/play and
  stays hidden for "Snooze 1 hour". `--background` is already handled.
- (plans) Main window closing: `StartPlans` hooks `Application.Current.MainWindow.Closing` — with `RunInBackground`
  it cancels and hides the window (tray "Quit" and Windows sign-out still exit); without it, `Closed` shuts the app
  down. The tray icon (`Veltoret.App.Tray.TrayIcon`, Shell_NotifyIcon P/Invoke, Assets/Veltoret.ico) offers
  Open Veltoret / Scan library / Quit. "Start with Windows" writes `HKCU\...\Run\Veltoret = "<exe>" --background`
  (re-synced at every start).
- (plans) Settings hosts other modules' sections by type name (reflection), so a missing section doesn't break the
  build: `Veltoret.App.Accounts.AccountsSection`, `Veltoret.App.Network.NetworkServersSection`,
  `Veltoret.App.Network.PlayOnTvSection`, `Veltoret.App.Controls.TmdbAttribution` (falls back to the notice text).
  Settings renders panels for This PC and Google accounts' library folders; `smb://` accounts are left to
  NetworkServersSection. "Double-tap seek" is labelled "Seek step" on Windows. Windows-only "App" group: "Keep
  running in the notification area", "Start with Windows".
- (plans) `Veltoret.App.Pages.Settings.Appearance.Apply(bool oledBlack)` swaps `Application.Current.Resources["Brush.Background"]`
  (applied at start and on every settings change).

- (drive) **Namespace change: the account UI lives in `Veltoret.App.AccountsUi`** (folder `src/Veltoret.App/Accounts/`):
  `Veltoret.App.AccountsUi.AccountsSection` and `Veltoret.App.AccountsUi.ConnectGoogle.Run(Window? owner, string? reconnectEmail = null)`.
  A namespace `Veltoret.App.Accounts` would shadow `Veltoret.Core.Storage.Accounts` for every file under `Veltoret.App.*`
  (C# finds the namespace member before the using directive), breaking `Accounts.IsLocal(...)` in ~11 files of other
  modules. **Settings must host `"Veltoret.App.AccountsUi.AccountsSection"`** (the reflection name), onboarding calls
  `Veltoret.App.AccountsUi.ConnectGoogle.Run(owner)`.
- (drive) `AccountsSection`: `bool ShowAccounts` (default true; set false when the host already renders Google account
  panels — accounts that need reconnecting are still listed with "Reconnect"), "Add Google account", and the
  "Google sign-in" panel (import/change the Desktop client JSON, link to docs/SETUP.md). Removing a Google account from
  elsewhere must use `AccountsSection.ConfirmAndRemove(owner, account)` (dialog text per source + `Library.RemoveAccount`
  + `GoogleAuth.SignOut`, which deletes the stored refresh token). `AccountsSection.RemoveDialog(owner, account)` = the
  dialog only. `ConnectGoogle.ImportClient(owner)`, `ConnectGoogle.OpenGuide()`, `ConnectGoogle.SetupUrl`.
- (drive) `AppServices.DriveFiles : DriveFileSource` (registered with Storage for every account that is not "device"
  and not smb://). Root `"root"` ("My Drive"); folder id `DriveFileSource.SharedRoot = "shared"` lists "Shared with me".
  `OpenRead` returns `DriveRangeStream` (seekable, read-only, HTTP Range per (re)open with a fresh token, 2 MB read-ahead,
  forward seeks < 4 MB read through, reconnects twice on a dropped connection; sync `Read` works on any thread).
- (drive) `GoogleAuthService` (Core.Auth): `HasClient`, `Client` (`OAuthClient` with `MaskedId`), `ImportClientJson(path)`
  (throws `FormatException` with a user message), `SetClient`, `RemoveClient`, `SignIn(ct, loginHint = null)` (throws
  `ConnectException` with `Title`/`Message`/`SetupProblem` — the spec 2.3 strings), `SignOut(email)`, `AccessToken(email, ct)`
  (throws `AuthRequiredException` after `invalid_grant`, `GoogleSetupException` for `invalid_client`), `Invalidate`,
  `NeedsReconnect(email)` (no stored sign-in), events `ReconnectNeeded(email)` and `Changed`. Secrets via `ISecretStore`
  (`DpapiSecretStore` under `AppPaths.Secrets`: `google-client.bin`, `google-<sha256(email)>.bin`). The loopback redirect
  is a `TcpListener` on 127.0.0.1 (not HttpListener: no http.sys URL ACL needed). SignIn upserts the `AccountEntity`
  (keeps the original `addedAt` on reconnect).
- (drive) `DriveRepository` (Core.Drive): `ListChildren/ListSharedWithMe/Search/Get/Rename/Move/Trash/DeletePermanently/
  CreateFolder/About/FreeBytes/Space/Download/OpenRange/Upload`, `MediaUrl(id)`, `CreateHttpClient(tokens)`
  (`DriveAuthHandler` + `AllowAutoRedirect=false`). `IDriveClient` = the subset extraction/uploads use (fakes in tests).
  `DriveFormat`: `Bytes`, `StorageSummary`, `StorageFraction`, `StorageAlmostFull` (≥ 0.9), `DriveDate`, `Clock`, `MimeFor`.
- (drive) `TransferService`: `Jobs`, `HasPending`, `Upload(account, parentId, path|paths)`, `Extract(account, zipId, zipName,
  zipSize, parentId, after, wifiOnly)` (one active job per ZIP), `CheckExtract(...) → ExtractCheck(Free, Resuming, Size, TooBig)`,
  `Retry(id)`, `Dismiss(id)`, `Cancel(id)`, `LatestForZip(zipId)`, `Resume()`; events `JobChanged(TransferJob)` (background
  thread), `JobFinished`, `JobRemoved(id)`. Persisted in `%LOCALAPPDATA%\Veltoret\transfers.json`; interrupted jobs restart
  at the next start (extraction skips files already in Drive). Max 2 uploads + 2 extractions at once. Jobs wait
  (state Waiting) while offline, and "Only on Wi-Fi" extractions while the network is metered.
- (drive) Deviations: an upload to a full Drive (`storageQuotaExceeded`) fails at once like extraction (Android retries
  uploads 3×). Uploads also wait for a connection (Android has no constraint). On This PC, delete goes to the Recycle Bin
  (as LocalFileSource does), so the Files dialog reads `"{label}" moves to the Recycle Bin on this PC. You can restore it
  from there.` (title "Delete?"). Device-side strings use "This PC" / "Files on this PC" / "Show This PC". After an
  extraction the library rescan is `Scans.RunNow()` (fire-and-forget); Files renames/moves/deletes use
  `Scans.RequestAutomatic()` and "Use as … library" uses `Scans.RunNow({folderId})`.
- (drive) Files Back: `FilesPage` registers class handlers for `Window` PreviewKeyDown/PreviewMouseDown (they run before
  the shell's instance Preview handlers). While the Files page is shown, Esc / Alt+Left / Backspace / mouse Back first
  clear the selection, close search, then go up a folder; only at the root does the shell's Back run. Ctrl+F on the
  Files page opens the Files search (Drive / this folder) instead of the library Search. `FilesPage.HandleBack()` is public.

- (network/Cast) `AppServices.Cast : CastController` (Veltoret.Core.Cast) and `AppServices.TvLinks : TvLinkStore`
  (`AppPaths.Secrets\tv_link.json`, DPAPI entropy "veltoret-link"; the spec's `%LOCALAPPDATA%\Veltoret\tv_link.json` moved
  next to smb_servers.json). `CastController`: `State : CastState`, `event StateChanged` (any thread),
  `Devices` (Veltoret TVs first, then Chromecasts) + `event DevicesChanged`, `StartDiscovery()/StopDiscovery()`
  (ref-counted), `Connect(CastDevice)`, `Load(CastMedia, startMs)`, `Play/Pause/TogglePlay/SeekTo/SeekBy`,
  `SelectSubtitle(id?)`, `SwitchAudio(mkvTrack)`, `SetVolume(0..1)/SetMuted`, `SelectLinkAudio/SelectLinkSubtitle`,
  `PlayNext()`, `Task<long> Disconnect()` (returns the TV position), `SaveProgress()`, `Shutdown()`,
  `event ReceiverUnreachable` (firewall hint), `TvLink : TvLinkClient`, `Media : CastMediaFactory` (builds CastMedia for a
  library file / Files item: TMDB title + artwork, sidecar SRT/ASS/VTT → WebVTT, MKV audio tracks + languages from the
  EBML header, DTS/TrueHD warning, next episode).
- (network/Cast) Player hand-off is done by `Veltoret.App.Network.CastPlayerBridge` (started in StartCast): it puts a
  `CastButton(onImage: true)` into every `PlayerWindow.CastButtonHost` (class Loaded handler), and on connect (or when a
  video opens in the player while connected) calls `PauseForCast()` and loads the player's video at `PositionSeconds`
  (uses `CurrentFile`, `FileId`, `Account`, `VideoTitle`, `VideoSubtitle`); on disconnect it calls
  `ResumeAfterCast(tvPositionMs)` (or plays the episode the TV moved on to via `AppServices.Playback.PlayFile`). The
  player needs no cast code. **Optional (player):** implement `Veltoret.App.Network.ICastMediaSource`
  (`Task<CastMedia?> BuildCastMedia()`) on `PlayerWindow` or its DataContext to hand over its real state (selected MKV
  audio track number, loaded external subtitles converted with `CastSubtitles.ToVtt(lines, offsetUs)` incl. sync,
  audio/subtitle languages for Play on TV). Without it the bridge uses the library: preferred audio language, sidecar
  subtitles (preferred subtitle language, no sync offset), and the player's audio choice isn't followed.
- (network/Cast) UI: `CastButton` (also parameterless for Home's reflection), `CastPanel.Open(owner)` (modeless picker /
  pairing / remote), `CastRemote`, `CastAudioDialog.Ask(...)`, `PlayOnTvSection` (+ `PlayOnTvPairDialog.Run(owner)`),
  `CastFirewall` (on `ReceiverUnreachable`, once per run: offers an inbound "Veltoret (casting)" rule, program = this exe,
  profile=private, via elevated `netsh` only after "Allow"). "Send to TV" core is ready for the SMB UI:
  `Veltoret.Core.Pairing.SendToTv.Find(window)` / `Send(tv, code, PhoneSubmission)` / `Username(domain, user)` (no UI yet).
- (network/Cast) Deviations: Chromecast discovery/session are hand-rolled (Makaretu mDNS, SslStream, hand-encoded
  protobuf); progress is polled with media GET_STATUS every 1 s. Receiver-unreachable = no request reached CastServer
  20 s after LOAD (or LOAD failed before any request). Labels say "this PC" instead of "this phone".
- (network/Cast, for ui) `ButtonAssist.Icon` on `Button.Icon` / `Button.Ghost` styles doesn't render (seen with
  `UiKit.IconButton("Play", …)` too); the cast UI works around it with an `Icon` as the button Content.

### UI module additions
- `Navigator` (additive): `Push(Route)` (always pushes, used for Search so Back works), `SelectTab(Route)` (rail: clears to Home then pushes), `CurrentTopLevel`, `LastNavigationWasBack`, `IsRegistered(Type)`.
- `FixMatchRoute(FileIds, Kind = null, Query = null)`: no file ids → the "Needs a match" list; `Kind` is "MOVIE"/"EPISODE".
- `Veltoret.App.Controls`: `UiKit` (code helpers: Text, Icon, Button, IconButton, Pill, Panel, ClickPanel, MenuItem, ShowMenu, OpenUrl),
  `Icon` (24×24 geometry element; resources `Icon.*` in Controls.xaml; `Icon.Get(name)`), `ButtonAssist` (attached Icon, IconSize,
  IsLoading, Placeholder), `Spinner`, `Motion` (PressScale, Entrance/Play), `SmoothScroll`, `AspectBox`, `VirtualGrid` (+ `IFullSpan`,
  `GridHeader`, `UiCell`), `HorizontalRow`, `SectionHeader`, `ScreenHeader`, `EmptyState`, `LoadingBox`, `Wordmark`, `TmdbAttribution`
  (logo + exact notice; `TmdbAttribution.Logo(height)`), `LivePage` (re-queries on Db.Changed / connectivity), `PosterItem`/`PlayItem`,
  `Formats` (US runtime/remaining/episode code/air label/reminder label/size), card templates `Template.PosterCard` / `Template.WideCard`
  (Controls/Cards.xaml, merged in App.xaml), `FolderPickerDialog.PickLibraryFolder(owner, account)` → (Id, Name, LibraryType) and
  `AskLibraryType`. `DialogWindow.Show` returns the clicked `DialogButton` (null = dismissed); `DialogButton.OnClick` may return false to keep it open.
- Extra styles: `Button.Ghost`, `Button.Danger`, `Button.TextMuted`, `Button.IconOnImage`, `Button.IconFlat`, `Button.Plain`, `Button.Row`,
  `ListBox.Plain`, `MenuItem.Caption`, `Panel`, `Divider.Vertical`, `Pill`/`Pill.Solid`/`Pill.Accent`, `Text.Muted`, `Text.OneLine`; implicit
  ScrollBar/ScrollViewer/TextBox/PasswordBox/ComboBox/CheckBox/ProgressBar/Slider/MenuItem/ContextMenu/ToolTip styles.
- Tokens.xaml fix: `Font.Serif` now points at `#Fraunces 9pt` (the bundled variable font's WPF family name; `#Fraunces` didn't resolve, so titles fell
  back to sans). WPF only renders the variable font's default instance (Black); bundle a static Fraunces 72pt Soft SemiBold to match Android exactly.
- Windows wording: device copies read "On this PC" (Computer icon); onboarding says "folders on this PC"; "Tap" → "Click".

### Player module additions
- (player) `Veltoret.App.Player.PlayerArgs(FileId, Account, Title, FromStart)`; `PlaybackLauncher.Open(PlayerArgs)` (static, any
  thread) reuses `PlayerWindow.Current` (`Open(args)` saves the current video's progress first, then loads in the same
  window; `BringToFront()`), else opens a new `PlayerWindow`. Nothing playable → `Toast.Show("This video isn't available right now")`.
- (player) Cast hooks on `PlayerWindow`: `Current`, `PositionSeconds`, `PauseForCast()` (saves progress, pauses, stops saving
  until `ResumeAfterCast(positionMs)` which seeks and stays paused), `CastButtonHost` (public ContentControl in the top bar),
  plus `CurrentFile`, `FileId`, `Account`, `VideoTitle`, `VideoSubtitle`, `event VideoChanged` (UI thread, each new video)
  and `internal Task SaveProgress()`. `ICastMediaSource` is **not** implemented (the bridge's library fallback applies).
- (player) `PlayerPrefs` (App) derives from `Veltoret.Core.Player.PlayerPrefsStore` (Core, tested): JSON object at
  `AppPaths.PlayerPrefs` with Android's keys/values (`video:{fileId}` = the 8 U+001F-joined TrackMemory fields, `audio:{showId}`,
  `sub:{showId}` / `"off"`, `resize`). `PlayerPrefs.Shared` is the app instance. External sources: `"drive:{id}"` (a file from
  the video's folder on any source), `"file:{path}"` (This PC, "Choose a file…"), `"side:{id}"` (sidecar).
- (player) Core helpers in `Veltoret.Core.Player`: `MediaFormats` (LanguageName/NormalizeLanguage — languages are compared and
  stored as ISO 639-1 where one exists, "eng"→"en"; CleanLabel; TrackTitles; FourCC→codec names; Channels; Resolution;
  Bitrate; FrameRate (Java %.3g); SampleRate), `SubtitleEngine` (encoding normalisation, SRT/VTT/ASS/TTML cue parser,
  `ActiveAt`, `ReadLimited`, `ToUtf8WithBom`, user-facing `SubtitleException`), `Sidecars.Match`, `EpisodeNav`
  (Next/Previous/EpisodeList), `PlayerFormat`, `PlayerMath` (seek, resume, prompt windows, speed steps, crop geometry).
- (player) Deviations / Windows choices: subtitles use spec option B (UTF-8 copy in `%TEMP%\Veltoret\subtitles` +
  `AddSlave`, sync via `SetSpuDelay`); size/background come from settings when the player window opens (LibVLC instance
  options), so a settings change applies to the next player window; the subtitle margin isn't raised while the controls show
  and the mini player doesn't enlarge subtitles (libVLC 3 can't change these on a running video). Forced subtitles when
  "Off": a track whose title contains "Forced" in the audio language (libVLC 3 has no forced flag). Double-click middle third =
  full screen, single click = toggle controls (after a 260 ms double-click wait); double-click left/right thirds and ←/→/J/L
  seek with the "{n} seconds" ripple (1.2 s accumulation; held arrows accelerate ×3/×6). Keys: Space/K/Enter play-pause,
  ↑/↓/wheel volume ±5 (0–200 %), M mute, N/P next/previous, F/F11 full screen, Esc panel → mini → full screen → close,
  [ ] speed, S/C/V cycle subtitles, A cycle audio, G/H sync ∓0.1 s, Z aspect, I info, Home start over, Tab skip intro,
  Ctrl+L lock (only Ctrl+L works while locked), Ctrl+wheel zoom (crop-based), drag to pan when zoomed, hold left button 2×.
  Media keys work while the player has focus; SystemMediaTransportControls are not wired. Minimising keeps playing (progress
  is saved). The "Rotate" chip is replaced by "Full screen". Decoder names aren't exposed by libVLC: info shows
  "Hardware (D3D11VA/DXVA2)" or "Software", HDR shows "SDR" unless Dolby Vision. No touch swipe gestures (mouse/keyboard only).
