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

- core-scan: `LibraryScanner(accounts: AccountDao, files: MediaFileDao, catalog: CatalogDao, storage: Storage, tmdb: TmdbMatching,
  settings: SettingsStore, connectivity: ScanConnectivity)`; `ArtworkPrefetch(catalog: CatalogDao, prefetch: @escaping ([String]) async -> Void)`
  (wire `prefetch: { await images.prefetch($0) }`), `urls() throws -> [String]`, `run() async throws`;
  `ScanScheduler(scanner:connectivity: ScanConnectivity, settings:prefetch: ArtworkPrefetch?)` + `start()`, `stop()`,
  `runNow(_:) async`, `requestAutomatic()`, `cancel()`, `busy`. Seams in `Library/ScanState.swift`: protocol `TmdbMatching`
  (`TmdbRepository` conforms in `Library/ScanAdapters.swift`, owned by core-scan) and protocol `ScanConnectivity`
  (`isOnline`, `onlineChanged: Event<Bool>`) — core-data: add `extension Connectivity: ScanConnectivity {}` next to Connectivity.
  Scanner methods are `async throws`; `ignore/restore/onFilesRemoved` take `[String]`. FilenameParser API: `parseMovie(_:folders:)`,
  `parseEpisode(_:folders:)`, `movieCandidates/showCandidates(_:folders:)`, `clean(_:isFile:)`, `normalizeForCompare`,
  `qualityTags(_:height:)`, `isVideo(_:mimeType:)`, `isSubtitle`, `isArchive`, `extension`, `baseName`.

- (plans) `AppServices.plans/upcoming/reminderScheduler`. `PlansRepository(_ dao:, now:)`: SQLite-only calls are sync
  `throws` (`isInWatchlist(type:id:)`, `watchlist()`, `setWatchlist(type:id:on:)`, `reminders()`, `remindersFor(type:id:)`,
  `addReminder(type:id:season:episode:title:atMs:addToWatchlist: = true) -> Int64`, `addReminder(...at: Date)`,
  `snooze(type:id:season:episode:title:)` (now + 1 h, no watchlist), `removeReminder(_:)`, `rescheduleAll() -> [ReminderEntity]`);
  `fire(_ id:) async throws -> Bool` (fire-once; keeps the row while `notifier.canPostNow` is false), `restore() async throws`.
  Settable `notifier: PlanNotifier?`, `alarms: ReminderAlarms?`. Re-query on `db.changed` ("watchlist", "reminders").
- (plans) `protocol PlanNotifier: AnyObject { var canPostNow: Bool; func showReminder(_: ReminderEntity) async throws;
  func showNewEpisode(_: ShowEntity) async throws }` — the implementation builds title/body/artwork itself (Windows
  ToastNotifier, spec 5.4) and is set by FeatureSettings with `AppServices.plans.notifier = …` (UpcomingService falls
  back to it). `NoopPlanNotifier` (can't post). `PlanNotificationIds` (`reminderCategory = "reminder"`,
  `newEpisodeCategory = "new-episode"`, `playAction = "play"`, `snoozeAction = "snooze"`, titles "Play" / "Snooze 1 hour").
  `OpenTarget(mediaType:mediaId:season:episode:play:)` with `userInfo` / `init?(userInfo:)` for notification payloads.
  `protocol ReminderAlarms { schedule(_:); cancel(_:) }`.
- (plans) `LocalDate` (C# DateOnly: `year/month/day`, `init(_ date:, calendar:)`, `dayNumber`, `adding(days:)`,
  `description` = "yyyy-MM-dd"). `Plans`: `movie/tv`, `staleAfterMs`, `stillAiring`, `quickTimes(_ now: Date, calendar:)
  -> [QuickTime(label, at: Date)]`, `airLabel(_:today: LocalDate)`, `isUpcoming(_:today:)`, `reminderLabel(_ at: Int64,
  now: Date, timeZone:)`, `due(_:now:) -> DueKind(.schedule/.fireNow/.drop)`, `toMillis(_ date: Date)`,
  `toMillis(_ local: DateComponents, timeZone:)`, `parse(_:) -> LocalDate?`. `PlanFormat.episodeCode/runtime/relative/date`.
- (plans) `ReminderScheduler(fire:now:)` (wall-clock DispatchSourceTimer, ≤ 30 min re-check, `pendingIds`, `dispose()`).
  `UpcomingService(plans:catalog:watch:settings:refreshShow:isOnline:localNow:calendar:)`: `start()`, `onOnline()`,
  `run() async throws`, `notifier`, `static alertKey/prune`, `dispose()`. `VoiceQuery.parse/best` (`Parsed`, `Candidate`).
- (plans) `VeltoretPlansModule.start()` restores reminders at start, on wake (NSWorkspace.didWakeNotification) and on
  clock / time zone changes (`SystemChangeMonitor`; replaceable hook `VeltoretPlansModule.observeSystemChanges`),
  starts UpcomingService once onboarding is complete, and calls `upcoming.onOnline()` on `connectivity.onlineChanged`.
  `VeltoretPlansModule.restoreReminders()` is public. Showing/hiding the window, the menu bar item and notification clicks
  are FeatureSettings/lead work (click "Snooze 1 hour" → `AppServices.plans.snooze(...)`; Play/open → navigate + playback).
- core-data: core API is published and wired (`CoreModule.initialize()/start()/shutdown()`). SQLite-only reads are **sync
  `throws`** (callers may still write `try await`): all `LibraryRepository` methods (`credits(type:id:)`,
  `episode(showId:season:episode:)`, `folderCounts() -> [Int64: Int]`, `search(_:) -> (movies:, shows:)`,
  `addFolder(account:folderId:name:type:) -> Int64?`), `WatchRepository(_ dao:)` (`savePosition(_ file:fallbackFileId:
  positionMs:durationMs:)`, `setMovieWatched(_:watched:)`, `setEpisodeWatched(showId:season:episode:watched:)`,
  `setEpisodesWatched(showId:_:watched:)`, `setFileWatched(_:watched:)`, static `isFinished(positionMs:durationMs:)`),
  `WatchKeys.movie/episode/file/forFile`, `PlaybackResolver` (`movieFile(_:)`, `showTarget(_:)`, `showPlayTarget(_:)`,
  `episodeFile(showId:season:episode:)` → `EpisodeTarget(file,state,resuming,fresh)`), `PlayTargets.nextEpisode(_:_:)`,
  `RelatedTitles.parseIds/inLibrary(_:_:selfId:limit:)`. TMDB: `TmdbClient(session:keyProvider:)`, `TmdbClient.buildUrl/
  makeDecoder()`, errors `TmdbKeyMissingError` and `TmdbError(message,statusCode)`; `TmdbRepository(api:catalog:)` with
  `findMovie(title:year:exactOnly:)`, `ensureShow(_:seasons:)`, `trailer(type:id:)`, `collection(_:)`; models are
  structs with camelCase props (`TmdbMovieDetail.collection`, `TmdbTvDetail.nextEpisode`, `country` for iso_3166_1).
  `TmdbImages.poster/backdrop/still/profile/logo`. `Connectivity(initiallyOnline:)`: `isOnline`, `isMetered`
  (NWPath isExpensive||isConstrained), `onlineChanged`, `start()/stop()`, `refresh() async -> Bool`, `set(_:)`, hooks
  `systemCheck`/`meteredCheck`. `ImageCache(directory:session:maxBytes:)`: `file(for:) async -> URL?`, `prefetch(_:) async`,
  `path(for:) -> URL`, `isCached`, `trim()`. `LocalFileSource.root/folderMime/normalize(_:)`, errors `LocalFileError`
  (`.folderUnavailable`, `.fileUnavailable`, `message`); Files search filters the current folder only (spec, not recursive).
  `MimeTypes.forName`. Tests: `FakeHttp.session { request in (status, Data)? }` (Tests/VeltoretKitTests/TmdbTests.swift)
  fakes URLSession for any test in VeltoretKitTests.
- (smb) `VeltoretSmbModule.initialize()` creates `AppServices.smbServers = SmbServerStore(url: SmbServerStore.defaultURL
  /* AppPaths.stores/smb_servers.json */, secrets: AppServices.secrets)`, `smbFiles = SmbFileSource(servers:)` (registered
  with `storage`) and `smbDiscovery`, and back-fills `smb://host` account rows; `shutdown()` stops discovery and
  disconnects. `SmbServer(host:port:username:domain:name:)` (`account`, `guest`, `displayName`). `SmbServerStore`:
  `servers`, `server(_ account:)`, `save(_:password:)` (non-throwing, Keychain key `"smb-" + account`; guests keep no item),
  `remove(_:)` (also deletes the Keychain item), `password(_:) -> String?` ("" guest; nil = sign in again), `changed:
  Event<Void>`. `SmbFileSource`: `servers`, `test(server:password:) async throws -> [String]` (share names,
  `@discardableResult`), `disconnect(_ account:)`, `disconnectAll()`, `static folderMime`; every failure is thrown as
  `SmbError` (`message` is the user sentence, `underlying` the cause). `openRead` returns `SmbReadStream: ByteSource`
  (1 MiB chunks, 2 read-ahead, 6 cached, retries once on a dropped connection; `read` fills `count` unless EOF).
  `SmbPath(host:share:segments:)`: `id`, `sharePath` (\\), `filePath` (/ for AMSMB2), `name`, `parent`, `child(_:)`,
  `account`, `unc`, `static scheme/isSmb/accountOf/fromUserInput`, `static parse(_:) throws`.
  `SmbErrors.describe(_:)` + constants `wrongLogin/accountDisabled/couldntReach/unknownHost/connectionLost/fallback/noGuests`
  (the guest rewrite in "Add server" step 9 is the UI's job). Errors: `SmbError`, `SmbStatusError(SmbStatus, op)`,
  `SmbTransportError`, `SmbSocketError`. `SmbMime.forName(_:)`. `SmbAccounts.addServerAccount(_ dao:, _ server:) throws`,
  `ensureServerAccounts(_ dao:, _ store:) throws`. `NetBios.nodeStatusQuery/parseNodeStatus`.
  `SmbDiscovery`: `start()` (fresh scan; also "Scan again"), `stop()`, `servers: [FoundServer]` (merged by address, sorted
  routers → named → address), `isScanning`, `changed: Event<Void>` (any thread; also fires when a scan ends),
  `discover() -> AsyncStream<FoundServer>` (raw), `nameOf(_ address:) async -> String?`, `static merge/subnetHosts/toInt/
  fromInt`. `FoundServer(address:name:isRouter:)` with `label` ("Your router" / "File server") and `subtitle`
  ("<ip> · router"). **Lead:** discovery browses Bonjour `_smb._tcp` → Info.plist `NSBonjourServices = ["_smb._tcp"]`
  and an `NSLocalNetworkUsageDescription` (the subnet sweep on TCP 445 and NetBIOS UDP 137 also need local-network access).
  Deviations: AMSMB2 doesn't report HIDDEN/SYSTEM attributes, so listings hide dot-files, `$RECYCLE.BIN`,
  `System Volume Information`, `desktop.ini`, `Thumbs.db`; one AMSMB2 connection per share (not per host); share
  listing uses a throwaway connection to IPC$; NetBIOS names are asked per hit by unicast (as Windows/Android), no broadcast.
- (playerkit) **VeltoretPlayerKit API** (Windows names, lowerCamelCase; positional args as in C#):
  `MediaFormats.normalizeLanguage/languageName/cleanLabel/trackTitles(_ tracks: [(language:, label:)], fallback:, language:)/
  fourCC(UInt32)/audioCodec/videoCodec/subtitleFormat/channels/resolution(_:_:)/bitrate(Int64)/frameRate(Double)/sampleRate(Int)`
  (languages via Foundation `Locale`, ISO 639-1 where one exists). `SubtitleEngine`: `maxBytes`, `tooLarge`, `unsupported`,
  `Kind`, `formatOf(_:)`, `readLimited(_ source: ByteSource) async throws -> Data`, `readLimited(account:id:)`,
  `normalizeText/decodeText/toUtf8WithBom(_ Data)`, `guessLegacyEncoding(_:) -> String.Encoding`,
  `windowsCodePage(_ Int) -> String.Encoding` (CFStringEncoding), `parse(_ bytes: Data, fileName:) throws -> [SubtitleCue]`,
  `activeAt(_ cues:, _ positionMs:, _ offsetMs:)`; `SubtitleCue(startMs:endMs:text:)`; errors are `SubtitleError` (`message`
  = the user sentence, also `localizedDescription`). `HdrFormat` (`.unknown/.sdr/.hdr10/.hlg/.dolbyVision`), `HdrProbe.detect(_
  source: ByteSource, fileName:) async -> HdrFormat` (doesn't close it), `detect(account:fileId:fileName:) async`,
  `fromFileName`, `fromContainer(_:) async throws`, `label`, `isHdr`. `TrackMemory` (struct, `with { $0.x = … }` for C#'s
  `with`, `encode()`, `static decode(_:)`, `subOff/subEmbedded/subExternal`). `PlayerPrefsStore(url:)` (open class) with
  `trackMemory(_:)`, `updateTrackMemory(_:_ change: (TrackMemory) -> TrackMemory)`, `audioLanguage(_:)`,
  `setAudioLanguage(_:_:)`, `subtitleLanguage(_:)`, `setSubtitleLanguage(_:_:)`, `resizeMode`; `PlayerPrefsStore.shared`
  (at `AppPaths.playerPrefs`) = `AppServices.playerPrefs` (set in `VeltoretPlayerKitModule.initialize()`).
  `Sidecars.match(_ videoName:, _ files: [T], name: (T) -> String) -> [SidecarMatch<T>]` (`file/name/language`),
  `Sidecars.isSubtitle(_:)`. `EpisodeNav.next(_ file:, _ showFiles:, online:)`, `previous(…)`, `episodeList(_:)`.
  `PlayerFormat.clock/bytes/runtime/episodeCode(_:_:)/speedOption/speedChip/trim/syncLabel/loadingHint(_:_:)/volume/
  swipeSeek(_:_:)/zoom/time(Date)/endsAt(Date) ("Ends at 10:42 PM")/sleepDetail(_ endsAt: Date?, _ endOfVideo:)`.
  `PlayerMath.seekBy/swipeSeek/swipeVolume/skipForward/resumeAt/skipIntroVisible/upNextVisible/speeds/stepSpeed/
  accumulateSeek/cropGeometry(_:_:_:_:fill:_:_:_:)` plus Mac additions from the Windows window: `endsAt(now:durationMs:
  positionMs:speed:) -> Date?`, `clampZoom(_:)` (1–5×, < 1.05 snaps to 1), `wheelZoom(_:notches:)` (×1.1 per notch),
  `pan(_:delta:size:zoom:)` (drag-to-pan, −1..1).
- (playerkit) **MediaStreamServer**: `MediaStreamServer.shared` (also `AppServices.mediaStream`):
  `url(account:fileId:name:mime: String? = nil) async throws -> URL` → `http://127.0.0.1:<port>/<token>/<entry>/<name>`
  (same URL for the same file until `stop()`; mime defaults from the extension, `static mimeFor(_:)`), `stop()` (closes every
  connection and its ByteSource; next `url` restarts on a new port/token), `currentPort`, `streamFailed:
  Event<StreamFailure>` (`account`, `fileId`, `error` — the source's own error, e.g. Drive 403/404 or `SmbError`, for the
  player's error text) and `lastError(account:fileId:) -> Error?`. Serves GET/HEAD, `Range` (single range: `a-b`, `a-`,
  `-n`; 206 + Content-Range; 416 when past the end), keep-alive, any number of connections (one ByteSource per connection,
  reused while it asks for the same file, closed when the connection ends; idle connections close after 120 s), 1 MiB reads
  with the next chunk read while the current one is sent (no further buffering = backpressure). Open failure → 502 and the
  connection closes. Unknown length (`length == -1`) → 200 without ranges. `VeltoretPlayerKitModule.shutdown()` stops it.
- (playerkit) Deviations: `Sidecars` carries its own copy of FilenameParser's `baseName`/subtitle extensions (no dependency
  on core's parser). Legacy subtitle encodings undefined bytes become U+FFFD; Windows-1250…1258 + 874 are available through
  `windowsCodePage`, while the guess (as Windows/Android) only picks 1252/1251/1256.
- cast: **Bonjour service types browsed** (add to Info.plist `NSBonjourServices`, plus `NSLocalNetworkUsageDescription`):
  `_googlecast._tcp` (Chromecasts), `_veltoret-play._tcp` (Veltoret TVs, "Play on TV"), `_veltoret._tcp` (TVs showing
  "Use your phone", Send to TV). The Mac also *listens* (CastServer, random TCP port on the LAN address) while casting.
- cast: API as published (Swift names): `CastController` — `state`, `stateChanged: Event<CastState>`, `devices`,
  `devicesChanged: Event<Void>`, `receiverUnreachable: Event<Void>`, `startDiscovery()/stopDiscovery()`,
  `connect(_ device: CastDevice) async throws` (throws `LinkError(code: "unpaired")` for an unpaired Veltoret TV; other
  failures land in `state.error`), `load(_ media: CastMedia, startMs: Int64) async`, `play()/pause()/togglePlay()`,
  `seek(to: Int64)/seek(by: Int64)`, `selectSubtitle(_ id: String?)`, `switchAudio(_ track: Int64) async`,
  `setVolume(_ level: Double)/setMuted(_:)`, `selectLinkAudio(_:)/selectLinkSubtitle(_:)`, `playNext() async`,
  `disconnect() async -> Int64`, `saveProgress(ended:)`, `refreshPairing()`, `shutdown()`, `tvLink: TvLinkClient`,
  `media: CastMediaFactory` (`forFile(_:) async`, `forItem(account:fileId:name:) async`, `describe(_:)`,
  `nextEpisode(_:)`, `subtitles(account:parentId:videoName:offsetUs:) async`), `server: CastServer`.
  `TvLinkClient`: `find(window:) -> AsyncStream<LinkTv>`, `hello(host:port:)`, `startPairing(_:)`, `pair(_:code:)`,
  `forget(_:)`, `play/command/status`; errors are `LinkError` (`message`, `code`). `TvLinkStore`: `peers`, `secret(_:)`,
  `save(_:secret:)`, `remove(_:)`, `deviceId`, `changed`. `SendToTv.find(window:) -> AsyncStream<FoundTv>`,
  `SendToTv.send(_:code:submission:) async -> SetupReply`, `SendToTv.username(domain:user:)`.
  `CastSubtitles.toVtt(_ lines: [CastSubtitles.Line], offsetUs:)`, `CastSubtitles.parse(_:fileName:)`, `LanguageNames`.
- cast: progress goes through the `CastProgressStore` protocol (default `WatchProgressStore`, which calls
  `AppServices.watch.savePosition` / `get(WatchKeys.forFile)`), so tests can swap it.
- ui: **VeltoretUI is published** — full guide in `Sources/VeltoretUI/README.md`. Summary: `VeltoretUIModule.initialize()`
  (@MainActor: fonts, theme, sets `AppServices.toast`/`navigate`) and `start()` (binds `ShellStatus` to connectivity/scanner).
  Theme: `Theme.*` colors/`Radius`/`gutter`, `Theme.serif(size)`, `Theme.sans(size, weight)`, `Fonts.register()/nsSerif/nsSans`,
  `ThemeState.shared` (live "Pure black"), `.vPageBackground()`, type modifiers `.vDisplayLarge()`…`.vLabelSmall()`/`.vText(_:color:)`,
  `.vHairline`, `.vPanel`, `.vCard`, `.vEntrance`. Components: `VButton`/`VButtonStyle`(`.vPrimary` …), `VIconButton`, `VPlainButtonStyle`,
  `VRowButtonStyle`, `VClickPanel`, `VChip`, `VToggle`, `.vSwitch`/`.vCheckbox` toggle styles, `VTextField`, `VSecureField`, `VProgressBar`,
  `VSpinner`, `VLoadingBox`, `VPill` (+`.quality`), `VRating`, `VMetaLine`, `VSectionHeader`, `VScreenHeader`, `VEmptyState`, `VScanChip`,
  `VDivider`, `Wordmark`, `RailLogo`, `AppLogo`, `TmdbAttribution` (+`.notice`), `TmdbLogo`, `ArtworkImage`/`AsyncPoster`/`ArtworkLoader`
  (through `AppServices.images`), `PosterItem`/`PosterCard`, `PlayItem`/`WideCard`, `WatchedCheck`, `HorizontalRow`, `VAdaptiveGrid`,
  `VPosterGrid`, `Formats`, `openInBrowser`. Dialogs: `Dialogs.confirm/textInput/choose/alert/present/show`, `VDialog`, `VDialogMessage`,
  `DialogController`, `DialogHost(View)`; `Toast.show(_:actionTitle:action:)`, `ToastCenter`, `ToastHostView`. `FolderPicker.pick(account:)`,
  `.pickLibraryFolder(account:)`, `.askLibraryType(folderName:)`, `.pickLocal()`, `.browse(account:title:choices:)`. Navigation:
  `RouteKind` + `Route.kind`, `PageRegistry.register(_ kind:, _ builder: (Route) -> AnyView?)` (or `view:` typed), `Navigator.shared`
  (`current`, `backStack`, `canGoBack`, `navigate/push/selectTab/goBack/reset(to:)`, `currentTopLevel`, `lastNavigationWasBack`,
  `navigated`), `SettingsSections.register(id:title:order:icon:content:)` / `.shared.sections`. Shell: `MainShell()` (configures its
  window; `MainShell.configure(_:)`), `ShellCommands.goBack/selectTab/openSearch/showMainWindow/handlesShortcuts`, `RailTab.all`,
  `ShellStatus.shared` (`isOffline`, `scanText`, `scanProgress`, `banner`, `railAccessory` slots).
  **Lead:** please add `.copy("Resources/Images")` to VeltoretUI's resources (the logo, `Resources/Images/logo.png`, used by `AppLogo`)
  and `exclude: ["README.md"]` to silence the unhandled-file warnings.
- (drive) API as published (`Sources/VeltoretDrive`): `GoogleAuthService(http: HttpTransport, secrets: SecretStoring, accounts:
  AccountDao?)` — `hasClient`, `client: OAuthClient?` (`maskedId`), `importClientJson(_ url:) throws` (throws `ClientFileError`
  with a user message = C# FormatException), `setClient(_:) throws`, `removeClient()`, `signIn(loginHint:) async throws ->
  AccountEntity` (every failure is a `ConnectError` with `title/message/setupProblem`; cancel the Swift task to cancel →
  "Sign-in cancelled"), `signOut(_:) async`, `accessToken(_:) async throws` (`AuthRequiredError` after `invalid_grant`,
  `GoogleSetupError` for `invalid_client`), `invalidate(_:)`, `needsReconnect(_:)`, `remember(_:token:expiresInSeconds:)`,
  `static secretNameFor(_:)`, `openBrowser` (NSWorkspace), events `reconnectNeeded: Event<String>`, `changed: Event<Void>`.
  Keychain keys `google-client` and `google-<sha256(lowercased email)>`. `LoopbackReceiver` is a BSD socket on 127.0.0.1.
- (drive) HTTP seam: `HttpTransport` (`send(URLRequest) -> HttpResponse`, `open(URLRequest) -> HttpStreamResponse`),
  `URLSessionTransport` (no redirects; streamed bodies with back-pressure), `DriveAuthTransport(tokens:inner:)` (bearer +
  one retry on 401; the account travels in an internal `X-Veltoret-Account` header that is stripped before sending),
  `TokenProvider`. Network/Drive failures are `DriveIOError(message)` (C# IOException); full Drive = `DriveStorageFullError`.
- (drive) `DriveRepository(http:)`: `listChildren(_:folderId:orderBy:)`, `listSharedWithMe`, `search(_:text:)`, `get`, `rename`,
  `move`, `trash`, `deletePermanently`, `createFolder`, `about`, `freeBytes`, `space`, `download(_:id:_ block:)`,
  `openRange(_:id:from:) -> HttpStreamResponse?`, `openRead(_:id:) -> ByteSource` (a `DriveRangeStream`), `upload(...)`
  (input is a `ByteStream`: `FileByteStream`, `DataByteStream`), `static mediaUrl/spaceFrom/escape`. `DriveClient` = the subset
  uploads/extraction use. `DriveFile.toItem()`. `DriveFormat` also has `baseName`/`fileExtension`.
- (drive) `TransferService(drive:jobsURL:)`: `upload(account:parentId:urls:)` / `upload(account:parentId:url:)`, `extract(account:
  zipId:zipName:zipSize:parentId:after: ZipAfterExtract (.keep/.trash/.delete), wifiOnly:)`, `checkExtract(...) async ->
  ExtractCheck` (`free/resuming/size/tooBig`), `retry/dismiss/cancel`, `latestForZip`, `resume()`, `jobs`, `hasPending`; events
  `jobChanged`, `jobFinished`, `jobRemoved` fire on background threads. `TransferJob` fields as on Windows. Wired to
  `connectivity.isOnline/isMetered`, `scans.runNow()` after an extraction, `library.forgetArchive` after trash/delete.
- (drive) Deviation: ZIP extraction no longer streams the archive forward-only (Windows: SharpCompress ZipReader). It reads the
  central directory by HTTP range (`ZipArchive.entries`, ZIP64 aware) and inflates each entry's range with the Compression
  framework (raw DEFLATE; store too), checking CRC-32. Files already in Drive with the same size are skipped without being
  downloaded. Encrypted entries / other methods fail with the Windows messages; a damaged ZIP fails with
  "The ZIP looks damaged or incomplete (…)". Upload failure for a missing file: "The file is no longer on this Mac".
- (library-browse) Shared helpers in `Sources/FeatureLibrary/Common/` (internal to FeatureLibrary, public where useful):
  `LiveQuery<Value>` (@MainActor ObservableObject = Windows LivePage: `init(tables:route:watchOnline:watchScan:load:)` with
  an `@Sendable async throws` load run off the main thread, re-run throttled 250 ms on `db.changed` / `onlineChanged`,
  only while `route` is the current page; `value`, `scan`, `error`, `start()`, `invalidate()`, `refresh()`, `onScan`).
  `CardActions` (Windows CardActions + Mac menus: `play(PosterItem|PlayItem)` (PlayItem casts via
  `LibraryHooks.castIfConnected`), `playMovie/playShow/playEpisode` (toast when `AppServices.playback` is nil),
  `open`, `openDetails`, `fixMatch(PosterItem)`, `toggleWatchlist(type:id:)` (toasts "Added to / Removed from your
  Watchlist"), `setMovieWatched`). `WatchlistMarks.shared` (watchlist key set kept live). View modifier
  `.posterContextMenu(item)`; `LibraryPosterCard(item)` / `LibraryWideCard(item)` (cards with menus). `PosterItems.movie/
  show/statesByKey`, `LibraryWidth(width)` (compact <600 / medium <840 / expanded; `posterWidth`, `wideWidth`, `gutter`),
  `FlowLayout` (wrapping chips), `PopupMenu.show([.item(title, selected:, action:), .separator, .caption("SOURCE")])`.
- (network-ui) **FeatureNetwork API** (all `@MainActor`): `FeatureNetworkModule.initialize()` registers Settings sections
  `"network"` "Network servers" (300, `NetworkServersSection()`) and `"play-on-tv"` "Play on TV" (500, `PlayOnTvSection()`);
  `start()` binds `CastStateModel.shared`, `CastPlayerBridge.start()` and `CastFirewall.watch()`; `shutdown()` closes the cast panel.
  `AddServerDialog.show(editing: SmbServer? = nil) async -> String?` (server account once saved, also if the folder step is
  closed with Esc; `AddServerModel` is the ported view model: `attempt(address:guest:username:password:name:)`, `scan()`).
  `NetworkServersSection` + `static confirmAndRemove(_ account:) async -> Bool` / `static removeServer(_ account:) throws`
  (library rows + account, connection, password) — **settings-ui:** don't render a generic panel for `smb://` accounts.
  `CastButton(onImage: Bool = false, size: 42)`, `CastPanel.open()/close()/isOpen` (modeless floating NSPanel: picker → pairing
  → remote), `CastRemote()`, `CastAudioDialog.ask(deviceName:options:current:) async -> Int64?`, `PlayOnTvSection`,
  `PlayOnTvPairDialog.run() async`, `CastGlyph(connected:)` (Material cast Shape), `CastStateModel.shared` (`state`, `devices`),
  `CastFirewall.watch()/openSettings()`, `CastLauncher.castIfConnected(_ file:) async -> Bool` (saved position via
  `PlayerMath.resumeAt`). **Player hand-off without a FeaturePlayer dependency — lead wires in the app target:**
  `PlayerHooks.castButton = { CastPlayerBridge.makeCastButton() }`; `CastPlayerBridge.attach(pause: { PlayerWindowController
  .current?.pauseForCast() }, resume: { PlayerWindowController.current?.resumeAfterCast(positionMs: $0) }, currentVideo: {
  PlayerWindowController.current.map { CastPlayerVideo(fileId:account:file:title:subtitle:positionMs:) } }, describe: nil)`
  (`describe` = optional player-built `CastMedia`, Windows ICastMediaSource); `currentVideo` must return nil when no player is
  open. Also `LibraryHooks.addNetworkServer = { await AddServerDialog.show() }`, `LibraryHooks.castButton = { AnyView(CastButton()) }`,
  `LibraryHooks.castIfConnected = { await CastLauncher.castIfConnected($0) }`. `CastPlayerBridge.castCurrentPlayer(ask:)`,
  `castFile(_:startMs:)` are public. Deviations: the firewall hint can't add a rule (no netsh): when `socketfilterfw
  --getglobalstate` says the firewall is off it shows a network toast, else a dialog "Let the TV reach this Mac?" with
  "Open Firewall settings" (x-apple.systempreferences Network-Settings ?Firewall, falling back to the security pane), once per
  run. Discovery in Add server uses the shared `AppServices.smbDiscovery` (start on open, stop on close). Icons are SF Symbols
  except the cast glyph. The bridge tracks the cast-from player by file id (no window identity).
- (settings-ui) **FeatureSettings API** (all `@MainActor` unless noted). `FeatureSettingsModule.initialize()` (registers the
  `.settings` page and sections `library` 100 "Library", `playback` 400, `subtitles` 410, `notifications` 600 "Reminders &
  alerts", `appearance` 700, `app` 800, `tmdb` 850, `about` 900; installs `MacNotifier` as the UNUserNotificationCenter
  delegate + categories and sets `AppServices.plans.notifier` / `upcoming.notifier` — call it before the app finishes
  launching), `start()` (menu bar item, `LoginItem.sync()`, permission check), `shutdown()`. `SettingsPage` hosts every
  `SettingsSections` entry in order (group title = the section's title, uppercased amber — sections shouldn't draw their own);
  ≥ 840 pt: two columns, FeatureSettings' own ids except `library` on the right, everything else (library, Google accounts,
  network, Play on TV…) on the left. Reusable rows: `SettingsGroupTitle`, `SettingsPanel`, `SettingsDivider`, `SettingRow`,
  `SwitchRow`, `ChoiceRow`, `SettingsNote`; `ScanText` (title/step/counts/idle/folder/menuLine).
  `ReminderDialog.show(type:id:season:episode:title:airDate:) async -> Bool` (@discardableResult). `RemindersDialog.show()`.
  `VoiceSearch.listen() async -> String?`, `VoiceSearch.isAvailable` (hide the mic when false). `OpenRequests.open(_ OpenTarget)`
  (shows the window, navigates, plays when `play`; one consumer, in order) and replaceable `OpenRequests.showMainWindow`.
  `MacNotifier.shared` (not main-actor: `PlanNotifier`, `isSupported` = running from a .app bundle, `status`,
  `statusChanged`, `refreshStatus()`, `requestAuthorization() async -> Bool`). `MenuBarController.shared` (`start/stop`,
  follows `showMenuBarItem` live; hooks `MenuBarController.nowPlaying` — **player:** set it to `{ (title, isPlaying, toggle) }`
  or nil when idle — and `MenuBarController.openMainWindow`). `LoginItem` (`isEnabled`, `needsApproval`, `set(_:) -> Bool`,
  `sync()`, `launchedAtLogin` — **lead:** read it at launch to stay in the menu bar without showing the window).
  Notification ids: reminders `r<id>` (category `reminder`, or `reminder-snooze` when nothing is playable), new episodes
  `e<tmdbId>` (`new-episode`); userInfo = `OpenTarget.userInfo` + `title`, `playSeason/playEpisode`, `snoozeSeason/snoozeEpisode`.
  Deviations: the idle scan text says "Details are under Library." (no Sources group); "Scan library now" asks for notification
  permission only while macOS hasn't asked; one attachment per notification (picture, else poster; no square crop); window
  closing / `runInBackground` / Dock behaviour stays with the lead (AppDelegate).
- (library-detail) `DetailPages.register()` (in `Sources/FeatureLibrary/Details/DetailCommon.swift`) registers `.movieDetail`,
  `.showDetail`, `.fixMatch` (ids → Fix match; none → "Needs a match" with Ignored section) and `.onboarding`. Uses
  `LibraryHooks.reminderDialog` / `connectGoogle` / `addNetworkServer` / `castIfConnected` (nil → item hidden / plays locally),
  reuses Common's `PopupMenu`, `PosterItems`, `FlowLayout`, `LibraryPosterCard`. Space / Return on a detail page = Play (local
  NSEvent monitor, skipped while a dialog or text field has focus). Onboarding "Build my library" calls `scans.start()` +
  `scans.runNow()`; finishing sets `onboardingComplete` and `Navigator.shared.reset(to: .home)`.
- (files-ui) **FeatureFiles API**: `FeatureFilesModule.initialize()` (@MainActor) registers `.files(account:folderId:)`
  (FilesPage) and `.archives` (ArchivesPage) with `PageRegistry`, and the Settings section `id "google-accounts"`,
  title "Google accounts", order 200 (`AccountsSection()`). `start()/shutdown()` are no-ops. Public:
  `AccountsSection(showAccounts: Bool = true)` (View: Google accounts with photo/name/email, "Reconnect" when
  `googleAuth.needsReconnect`, "Remove", "Add Google account", the "Google sign-in" panel: import/change the Desktop
  client JSON via NSOpenPanel, masked id, setup-guide link); `AccountsSection.confirmAndRemove(_ a: AccountEntity) async
  -> Bool` (per-source dialog + `library.removeAccount` + `googleAuth.signOut` for Google — **use this to remove a Google
  account anywhere**; SMB callers must still forget the server themselves) and `AccountsSection.removeDialog(_:) async ->
  Bool` (dialog only). `ConnectGoogle.run(reconnectEmail: String? = nil) async -> AccountEntity?` (@MainActor; imports a
  client first when none, "Continue in your browser…" dialog with Cancel → cancels the sign-in task, toast "Connected
  {email}", ConnectError → dialog with title/message, setup problems add client details + guide link),
  `ConnectGoogle.importClient(firstTime:) async -> Bool`, `ConnectGoogle.openGuide()`, `ConnectGoogle.setupUrl`
  (`…/Veltoret-Mac/blob/main/docs/SETUP.md#google-drive` — **lead: docs/SETUP.md doesn't exist yet**).
  `ExtractDialog.show(account:zipId:zipName:size:parentId:) async -> Bool` (@MainActor; starts `transfers.extract`).
- (files-ui) Files Back: the shell has no page hook, so FeatureFiles installs its own `NSEvent` local monitor (AppKit
  calls the newest local monitor first, i.e. before `MainShell`'s). While a Files page is current and no dialog is open,
  Esc / ⌘[ / mouse back / two-finger swipe right clear the selection → close search → go up a folder, and only at the
  top is the event passed on to the shell. ⌘F opens the Files search (Drive / this folder); ⌘A, ⌘⌫ (trash/delete),
  ⌥⌘⌫ (Drive delete permanently), Return (rename one), ⌘↓/⌘O (open), ⌘↑ (up), ⇧⌘N (new folder), Space (Quick Look,
  This Mac). **Not intercepted:** the title-strip back chevron and a *clicked* Go → Back menu item (they call
  `ShellCommands.goBack()` directly). Suggested additive UI change: `ShellCommands.backInterceptor: (@MainActor () -> Bool)?`
  consulted first by `goBack()`; FeatureFiles would then set it and drop its Esc/⌘[ handling.
- (files-ui) Deviations: single click opens/plays (as Windows); ⌘-click / ⇧-click / ⌘A select; right-click on a
  multi-selection acts on the selection. One-column list with sortable Name / Date Modified / Size headers (click again
  to reverse) instead of the 360-pt adaptive grid; the Sort menu is kept. Name sort is Finder-style
  (`localizedStandardCompare`). Drag and drop from Finder: Drive uploads the files (folders skipped), This Mac offers to
  add a dropped folder to the library ("What's in …?"), SMB refuses. Transfer cards show Retry / Cancel / Dismiss on hover
  (and in a context menu). This Mac extras: Quick Look, Show in Finder. Errors from ConnectGoogle show as dialogs (Windows:
  toasts), user cancel as a toast.
- (player) **FeaturePlayer API** (`Sources/FeaturePlayer`). `FeaturePlayerModule.initialize()` sets `AppServices.playback =
  VeltoretPlaybackLauncher()` (and clears stale subtitle temp copies); `shutdown()` (main thread) saves progress synchronously and
  closes the player. `VeltoretPlaybackLauncher: PlaybackLauncher` — `playMovie/playShow/playEpisode` via `AppServices.resolver`
  (device copies first; offline only local), `playFile`, `playItem(account:fileId:name:)`; nothing playable → toast "This video isn't
  available right now". Static `open(_ args: PlayerArgs)` (any thread) and `openLocalFile(_ url: URL)` (Finder "Open With" / Dock drop
  — **lead:** call it from `AppDelegate.openFiles`). `PlayerArgs(fileId:account:title:fromStart:)`.
  `@MainActor PlayerWindowController` (NSWindowController): `static current`, `static open(_:)` (reuses the open window: saves the
  current video's progress, loads in place, `bringToFront()`), Cast hooks `positionSeconds`, `pauseForCast()` (saves, pauses, stops
  saving until `resumeAfterCast(positionMs:)`, which seeks and stays paused), `currentFile`, `fileId`, `account`, `videoTitle`,
  `videoSubtitle`, `videoChanged: Event<Void>` (main actor, each new video), `isPlaying`, `saveProgress()`, plus `close()`,
  `toggleFullscreen()`, `enterMini()/exitMini()/toggleMini()`, `isFullscreen`, `isMini`. `@MainActor PlayerHooks.castButton:
  (() -> AnyView)?` (top-bar slot) and `PlayerHooks.windowOpened: ((PlayerWindowController) -> Void)?` (called once per new window).
  `@MainActor PlayerCommands` (all no-ops without a player): `togglePlayPause/play/pause/skipForward/skipBackward/startOver/skipIntro/
  nextEpisode/previousEpisode/volumeUp/volumeDown/toggleMute/speedUp/speedDown/normalSpeed/cycleAudio/cycleSubtitles/subtitlesOff/
  subtitleEarlier/subtitleLater/cycleAspect/toggleFullScreen/toggleMiniPlayer/toggleLock/showVideoInfo/showAudio/showSubtitles/
  showEpisodes/showSleepTimer/closePlayer/bringPlayerToFront`, state `isPlayerOpen/isPlayerKey/isPlaying/hasNextEpisode/
  hasPreviousEpisode/isLocked/isMiniPlayer/isMuted`, and `makeMenu() -> NSMenu` (a validated "Playback" menu; only ⌘ shortcuts —
  ⌘←/⌘→ skip, ⇧⌘←/⇧⌘→ episodes, ⌘↑/⌘↓ volume, ⌥⌘M mini player, ⌘L lock, ⌥⌘I video info — enabled while the player window is
  key). **Lead:** in `AppWiring.extendMenu(main)` add an item titled "Playback" with `submenu = PlayerCommands.makeMenu()`.
- (player) Mac player notes / deviations: one dark `NSWindow` (hidden title bar, traffic lights fade with the chrome; frame autosaved as
  "VeltoretPlayer") hosting `VLCVideoView` (`VLCMediaPlayer(options:)`, its own libVLC instance with the Windows subtitle options) under
  an `NSHostingView` SwiftUI chrome; keys are taken in `NSWindow.sendEvent` before SwiftUI (Space/K/Return, ←/→/J/L with ripple and
  held-key acceleration, ↑/↓ volume 0–200 %, M, N/P, F, Esc panel → mini → full screen → close, [ ], S/C/V, A, G/H, Z, I, Home,
  Tab skip intro, ⌘L lock — the only key while locked); mouse: click toggles controls (260 ms double-click wait), double-click thirds
  seek/full screen, hold 2×, drag pans when zoomed, scroll volume, ⌘-scroll and trackpad pinch zoom (crop-based, 1–5×). Full screen is
  native (`toggleFullScreen`). The mini player is the **same window** made floating (`.floating`, all Spaces, aspect-locked, 400 pt
  wide bottom-right; drag moves it, double-click expands) rather than a separate NSPanel (moving the VLC view between windows isn't
  safe). Drive/SMB play through `MediaStreamServer` (`:network-caching=3000`, `:http-reconnect`); local by path (`:file-caching=1000`).
  Hardware decoding = VideoToolbox (`:avcodec-hw=any`); software = `:no-videotoolbox :avcodec-hw=none`; automatic fallback once on a
  decoder error. HDR: macOS manages EDR itself, so there's no display switch; the top-bar chip only shows the detected format
  (`HdrProbe`; header probe for local files, file name otherwise). VLCKit 3.7.3 reports buffering continuously while playing and the
  natural end of a file as **Paused** (not Ended): loading = a buffering event while the clock hasn't moved for 0.6 s; an unexpected pause
  within 3 s of the end is treated as the end. A remote stream that stops early with a `MediaStreamServer.lastError` shows the error card.
  Now Playing/media keys via MPNowPlayingInfoCenter + MPRemoteCommandCenter (poster artwork through `AppServices.images`); display sleep
  blocked with an IOPMAssertion while playing. Subtitle copies live in `AppPaths.temp/subtitles` (deleted on close and at launch).
