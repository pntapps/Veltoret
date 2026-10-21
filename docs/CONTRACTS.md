# Cross-module contracts (Mac)

Modules are built in parallel. These names are fixed so modules can call each other before the other side exists.
Implement exactly what your module provides; call only what's listed for the others. If you need something that isn't
here, add it to your own module and append a note under **Additions** at the end (append-only; one bullet, prefixed
with your module name).

## Translation rule from the Windows contracts

Every API below is the Windows API (`../Veltoret-Windows/docs/CONTRACTS.md`) translated mechanically, so you can
code against a module that isn't written yet:

- Names → lowerCamelCase (`ScanAll()` → `scanAll()`, `IsOnline` → `isOnline`, `Db.Changed` → `db.changed`).
- `Task<T> Foo(...)` → `func foo(...) async throws -> T`; `Task` → `async throws`. Pure queries that only touch
  SQLite may be synchronous `throws` (the DAOs are). `CancellationToken` → Swift task cancellation (omit the parameter).
- `event Action<T> X` → `public let x = Event<T>()` (VeltoretKit/Util/Event.swift); handlers run on the firing
  thread, UI hops to `@MainActor` itself.
- `IReadOnlySet<long>?` → `Set<Int64>?`; `IReadOnlyList<T>` → `[T]`; `DateTimeOffset` → `Date`; `Stream` from
  OpenRead → `ByteSource`; `long` ms → `Int64`; TMDB ids → `Int`; folder ids → `Int64`.
- Records → `public struct` (Hashable, Sendable, Codable when persisted). Services → `public final class`
  (`@unchecked Sendable`, internally locked) unless they're UI state (`@MainActor final class … : ObservableObject`).
- Static C# helper classes → `public enum X { public static func … }`.
- C# `AppServices.Foo` → Swift `AppServices.foo` (declared in your target's `extension AppServices`).

## Foundation (lead, exists — VeltoretKit)

`AppServices.db/accountDao/mediaFileDao/catalogDao/plansDao/watchDao/settings/storage/secrets/playback/navigate/toast`,
`AppPaths`, `VeltoretDb` (`query/one/rows/scalar/execute/transaction/upsert/notifyChanged`, `changed: Event<Set<String>>`),
entities in `Data/Entities.swift`, DAOs in `Data/Daos.swift`, `Storage` + `FileSource` + `ByteSource`
(`FileByteSource`, `DataByteSource`) + `StorageItem` + `StorageSpace` + `Accounts` in `Storage/Storage.swift`,
`AppSettings` + `SettingsStore` (`current`, `update { $0.x = … }`, `changed`), `SecretStoring` (Keychain /
`MemorySecretStore`), `Event`/`Subscription`/`SubscriptionBag`, `Log`, `nowMillis()`, `Route`, `PlaybackLauncher`.
Tests call `AppServices.initForTests()` (in-memory DB, temp root, memory secrets).

## Core (VeltoretKit: Library/ Tmdb/ Local/ Net/ Images/)

```swift
extension AppServices {
  static var tmdb: TmdbRepository!; static var scanner: LibraryScanner!; static var library: LibraryRepository!
  static var watch: WatchRepository!; static var resolver: PlaybackResolver!; static var connectivity: Connectivity!
  static var images: ImageCache!; static var scans: ScanScheduler!; static var artwork: ArtworkPrefetch!
  static var localFiles: LocalFileSource!
}
```
- `TmdbRepository`: `searchMovies(_ q: String, year: Int? = nil) async throws -> [TmdbMovieSummary]`, `searchShows(...)
  -> [TmdbTvSummary]`, `findMovie(title:year:exactOnly:)`, `findShow(...)`, `ensureMovie(_ id: Int)`, `ensureShow(_ id: Int,
  seasons: Set<Int>)`, `ensureRecommendations(type: String, id: Int)`, `trailer(type:id:) async throws -> String?`
  (YouTube key), `collection(_ id: Int) async throws -> TmdbCollection`, `validateKey() async throws`
  (throws `TmdbKeyMissingError`), `static pickTrailer`, `static pickBest`, `static yearOf`. `TmdbImages` builds image URLs
  (`poster(path, size)`, `backdrop`, `still`, `profile`, `logo`).
- `LibraryScanner`: `state: ScanState`, `stateChanged: Event<ScanState>`, `scanAll()`, `scan(_ folderIds: Set<Int64>?)`,
  `cancel()`, `isBusy`, `applyManualMatch(fileIds: [String], kind: MediaKind, tmdbId: Int)`, `ignore(_ ids:)`,
  `restore(_ ids:)`, `onFileRenamed(oldId:newId:newName:)`, `onFilesRemoved(_ ids:)`. `ScanState` mirrors Android
  (running, phase, filesFound, toMatch, matched, error, lastFinishedAt, folderIds, foldersTotal, foldersDone,
  doneFolderIds, currentFolderId, currentFolder, currentPath, newFiles, identified, cancelled, folderErrors,
  `covers(_:)`, `waiting(_:)`, `progress`).
- `LibraryRepository` (offline-aware): `movies()`, `shows()`, `episodeFiles()`, `relatedMovies(_:)`, `relatedShows(_:)`,
  `movieSources()`, `showSources()`, `deviceCopy(_ file:)`, `addFolder(account:folderId:name:type:) -> Int64?`,
  `removeFolder(_:)`, `removeAccount(_:)`, plus `movie/movieFiles/show/seasons/episodes/showFiles/credits/unmatched/
  ignored/folderCounts/allEpisodes/archives/forgetArchive/file/episode/subtitlesBeside/search/nextEpisodeFile/
  previousEpisodeFile/accountList/folders/ensureDeviceAccount`. Re-query on `db.changed` / `connectivity.onlineChanged`.
- `WatchRepository`, `WatchKeys`, `PlayTargets`, `RelatedTitles`, `PlaybackResolver` — ports of the Windows classes.
- `Connectivity` (NWPathMonitor + a TMDB/Google reachability check): `isOnline`, `isMetered`, `onlineChanged: Event<Bool>`,
  `start()`, `refresh() async -> Bool`.
- `ImageCache`: `file(for url: String?) async -> URL?` (downloads once, works offline), `prefetch(_ urls:)`,
  `path(for:)`, `isCached(_:)`, `trim()`; 512 MB LRU in `AppPaths.imageCache`, file name = SHA-1 hex of the URL.
- `ScanScheduler`: `start()`, `runNow(_ folderIds: Set<Int64>? = nil) async`, `requestAutomatic()`, `cancel()`, `busy`.
- `LocalFileSource: FileSource` for `"device"` (root id `"device-root"`), `MimeTypes.forName(_:)`.

## Player kit (VeltoretPlayerKit)

`MediaFormats`, `SubtitleEngine` (+ `SubtitleCue`, `SubtitleError`), `HdrProbe`, `PlayerPrefsStore` (`AppPaths.playerPrefs`,
Android's keys), `Sidecars.match`, `EpisodeNav` (`next/previous/episodeList`), `PlayerFormat`, `PlayerMath`, `TrackMemory`.
`MediaStreamServer.shared`: `url(account:fileId:name:mime:) async throws -> URL` (127.0.0.1, random port + token, HTTP
Range over `Storage.openRead`), `stop()`.

## Drive (VeltoretDrive)

```swift
extension AppServices { static var googleAuth: GoogleAuthService!; static var drive: DriveRepository!
                        static var driveFiles: DriveFileSource!; static var transfers: TransferService! }
```
- `GoogleAuthService`: `hasClient`, `client: OAuthClient?` (`maskedId`), `importClientJson(_ url: URL) throws`,
  `removeClient()`, `signIn(loginHint: String? = nil) async throws -> AccountEntity` (throws `ConnectError` with
  title/message/setupProblem), `signOut(_ email:) async`, `accessToken(_ email:) async throws -> String`,
  `needsReconnect(_:)`, `reconnectNeeded: Event<String>`, `changed: Event<Void>`.
- `DriveRepository`, `DriveFormat` (`bytes`, `storageSummary`, `storageFraction`, `storageAlmostFull`, `driveDate`, `clock`,
  `mimeFor`), `DriveFileSource` (root `"root"`, `sharedRoot = "shared"`), `DriveRangeStream: ByteSource`.
- `TransferService`: `jobs`, `hasPending`, `upload(account:parentId:urls:)`, `extract(account:zipId:zipName:zipSize:
  parentId:after:wifiOnly:)`, `checkExtract(...) -> ExtractCheck`, `retry/dismiss/cancel(_ id:)`, `latestForZip(_:)`,
  `resume()`, events `jobChanged: Event<TransferJob>`, `jobFinished`, `jobRemoved: Event<String>`.

## SMB (VeltoretSmb)

```swift
extension AppServices { static var smbServers: SmbServerStore!; static var smbFiles: SmbFileSource!
                        static var smbDiscovery: SmbDiscovery! }
```
`SmbFileSource: FileSource` for `smb://host` accounts (`test(server:password:) async throws`, `disconnect(_:)`,
`disconnectAll()`), `SmbServerStore` (`servers`, `server(_:)`, `save(_:password:)`, `remove(_:)`, `password(_:)`,
`changed: Event<Void>`; passwords in Keychain), `SmbServer`, `SmbPath`, `SmbErrors.describe(_:)`,
`SmbAccounts.addServerAccount/ensureServerAccounts`, `SmbDiscovery` (`start/stop`, `servers`, `changed`).

## Cast (VeltoretCast)

```swift
extension AppServices { static var cast: CastController!; static var tvLinks: TvLinkStore! }
```
`CastController`: `state: CastState`, `stateChanged: Event<CastState>`, `devices: [CastDevice]`, `devicesChanged`,
`startDiscovery()/stopDiscovery()` (ref-counted), `connect(_:)`, `load(_ media: CastMedia, startMs:)`,
`play/pause/togglePlay/seek(to:)/seek(by:)`, `selectSubtitle(_:)`, `switchAudio(_:)`, `setVolume(_:)/setMuted(_:)`,
`selectLinkAudio/selectLinkSubtitle`, `playNext()`, `disconnect() async -> Int64`, `saveProgress()`, `shutdown()`,
`receiverUnreachable: Event<Void>`, `tvLink: TvLinkClient`, `media: CastMediaFactory`. `CastSubtitles.toVtt`,
`CastAudio`, `PairingCrypto`, `SendToTv`.

## Plans (VeltoretPlans)

```swift
extension AppServices { static var plans: PlansRepository!; static var upcoming: UpcomingService! }
```
`PlansRepository`: `isInWatchlist(type:id:)`, `setWatchlist(type:id:on:)`, `watchlist()`, `reminders()`,
`remindersFor(type:id:)`, `addReminder(type:id:season:episode:title:atMs:addToWatchlist:) -> Int64`,
`removeReminder(_:)`, `snooze(...)`, `fire(_:)`, `restore()`, `rescheduleAll()`, settable `notifier: PlanNotifier?`.
`Plans` (static rules), `OpenTarget`, `PlanFormat`, `ReminderScheduler`, `UpcomingService` (`start/onOnline/run`),
`VoiceQuery`. Protocol `PlanNotifier` (post reminder / new-episode notifications) is implemented by FeatureSettings.

## UI (VeltoretUI) — see the module's README section in Additions once published

`Theme` (colors, `Theme.background` follows Pure black, fonts `Theme.serif(size)`/`Theme.sans(size, weight)`, type
scale `.vDisplayLarge` … `.vLabelSmall` view modifiers), `Fonts.register()`, components (buttons: primary / secondary /
text / icon / ghost / danger; chips; toggles; text fields; cards; pills; section headers; empty states; spinner;
`AsyncPoster` / `ArtworkImage` loading through `AppServices.images`), `Toast.show(_:action:)`, `Dialogs` (confirm,
text input, custom sheet), `FolderPicker` (any source through Storage; This Mac uses NSOpenPanel), `Navigator`
(`@MainActor ObservableObject`: `current`, `canGoBack`, `navigate/push/selectTab/goBack`, `register(_ kind:, view:)`),
`PageRegistry` (feature modules register a SwiftUI view builder per `Route` case), `SettingsSections` registry
(other modules register their Settings sections by id), `MainShell` (sidebar rail + page host + toasts) and
`Formats` (US runtime, remaining, episode codes, sizes).

## Feature modules

- **FeatureLibrary** registers pages for home, movies, shows, search, movieDetail, showDetail, collection, fixMatch,
  onboarding.
- **FeaturePlayer** sets `AppServices.playback`; provides `PlayerWindowController` with Cast hooks (`current`,
  `positionSeconds`, `pauseForCast()`, `resumeAfterCast(positionMs:)`, `currentFile`, `fileId`, `account`, `videoTitle`,
  `videoSubtitle`, `videoChanged: Event<Void>`, and a cast-button slot `PlayerHooks.castButton: (() -> AnyView)?`).
- **FeatureFiles** registers files and archives pages; `AccountsSection`, `ConnectGoogle.run(reconnectEmail:)`,
  `ExtractDialog`.
- **FeatureNetwork** provides `AddServerDialog`, `NetworkServersSection`, `CastButton`, `CastPanel`, `PlayOnTvSection`,
  `CastPlayerBridge` (fills `PlayerHooks.castButton`).
- **FeatureSettings** registers the settings page (hosting the other modules' sections via `SettingsSections`),
  `ReminderDialog.show(type:id:season:episode:title:airDate:)`, the notifier (UserNotifications), the menu bar item,
  `VoiceSearch.listen() async -> String?`.

## Additions

