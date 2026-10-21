# VeltoretUI — how feature modules use it

`import VeltoretUI` gives you the design system, navigation, the shell, dialogs and toasts. Everything is SwiftUI
(macOS 14), dark only. **No gradients** (only `TmdbLogo`). Flat surfaces, 1 pt hairlines, amber accent.

## Wiring (app target)

```swift
VeltoretUIModule.initialize()   // after the foundation + Core, before feature modules: fonts, theme, AppServices.toast/navigate
// feature modules' initialize() register pages / settings sections here
window.contentView = NSHostingView(rootView: MainShell())   // configures the window itself (hidden title bar, dark)
VeltoretUIModule.start()        // after CoreModule.start(): binds the rail's Offline label + scan indicator
```
Menus call `ShellCommands.goBack()`, `.selectTab(0…5)`, `.openSearch()`, `.showMainWindow()`. The shell already
handles ⌘[, ⌘1–⌘6, ⌘F, Esc (dialog dismiss / Back outside text fields), mouse back button and two-finger swipe back
(set `ShellCommands.handlesShortcuts = false` to leave keys to the menus).

## Pages and navigation

```swift
PageRegistry.register(.home) { _ in HomePage() }
PageRegistry.register(.movieDetail) { route in
    guard case .movieDetail(let id) = route else { return nil }   // builder: (Route) -> AnyView?
    return AnyView(MovieDetailPage(movieId: id))
}
Navigator.shared.navigate(.movieDetail(movieId: 603))   // or AppServices.navigate(...) from non-UI code
Navigator.shared.push(.search(query: "dune"))           // push even top-level routes (keeps Back)
Navigator.shared.goBack()
```
Pages stay mounted while in the back stack (their `@State` and scroll position survive Back). Page roots should use
`.vPageBackground()` (follows "Pure black" live) and fill the space they get; the shell gives the page the area
right of the rail, below the title-bar strip (use `.ignoresSafeArea(edges: .top)` for full-bleed backdrops).
`Navigator` also exposes `current`, `backStack`, `canGoBack`, `currentTopLevel`, `lastNavigationWasBack`,
`reset(to:)`, `navigated: Event<Route>`.

Settings sections from other modules:
```swift
SettingsSections.register(id: "network", title: "Network servers", order: 300, icon: "network") { NetworkServersSection() }
// The Settings page: @ObservedObject var reg = SettingsSections.shared; ForEach(reg.sections) { $0.content() }
```

## Theme

- Colors: `Theme.background` (current; live via `.vPageBackground()` / `ThemeState.shared`), `surface`, `surfaceHigh`,
  `surfaceHighest`, `outline`, `outlineStrong`, `text`, `textMuted`, `textFaint`, `amber`, `amberSoft`, `amberDim`,
  `onAmber`, `danger`, `success`, `imageDim`, `backdropDim`, `playerChrome`, `pillSolid`, `hover`, `pressed`.
- `Theme.Radius.{pill 6, chip 10, button 12, poster 12, card 14, dialog 20, hero 20, detailBackdrop 24}`,
  `Theme.gutter` (40), `sectionSpacing` (28), `rowSpacing` (16), `railWidth` (92).
- Fonts: `Theme.serif(size)` (Fraunces SemiBold, opsz 72, Soft 50), `Theme.sans(size, .semibold)` (Inter);
  AppKit: `Fonts.nsSerif/nsSans`.
- Type scale: `Text("…").vHeadlineLarge()` … `.vLabelSmall()`, or `.vText(.titleSmall, color: Theme.textMuted)`;
  `.vMuted()` (bodySmall muted), `.vOneLine()` (card titles). Every modifier takes an optional color.
- `.vHairline(radius)`, `.vPanel()` (full-width card, padding 16), `.vCard()` (content-sized), `Color(hex: 0xAARRGGBB)`.
- Motion: built into buttons/cards; `.vEntrance(index, key: "home.hero")` plays the one-time rise-in.

## Components

| Need | Use |
|---|---|
| Buttons | `VButton("Play", icon: "play.fill", kind: .primary/.secondary/.ghost/.danger/.text/.textMuted/.textDanger, loading:, compact:, fullWidth:) { }`, or `Button(…).buttonStyle(.vPrimary / .vSecondary / .vGhost / .vDanger / .vText / .vTextMuted)` |
| Round icon button | `VIconButton("magnifyingglass", help: "Search", size: 42, kind: .standard/.onImage/.flat, tint:) { }` |
| Clickable card / row | `.buttonStyle(VPlainButtonStyle(pressScale: 0.96))`, `.buttonStyle(VRowButtonStyle(selected:))`, `VClickPanel { }` |
| Chips / toggles | `VChip("Action", icon:, selected:) { }`, `VToggle("Pure black", subtitle:, isOn:)`, `Toggle(...).toggleStyle(.vSwitch / .vCheckbox)` |
| Text input | `VTextField("Search", text: $q, icon: "magnifyingglass", onSubmit:) { trailing }`, `VSecureField("Password", text: $pw)` |
| Progress | `VProgressBar(0.4, height: 3, track: Theme.imageDim)`, `VSpinner(size:, lineWidth:, color:)`, `VLoadingBox(height:)` |
| Pills | `VPill("New", style: .plain/.solid/.accent)`, `VPill.quality("4K")` |
| Text bits | `VRating(7.8)`, `VMetaLine("2021", "2h 35m", "PG-13")`, `VSectionHeader("Movies", actionTitle: "See all") { }`, `VScreenHeader("Movies", subtitle:, showsBack: true) { actions }` |
| States | `VEmptyState(icon: "film", title:, message:, actionTitle:, action:)`, `VScanChip("Syncing 120")` |
| Brand | `Wordmark(large:)`, `RailLogo()`, `AppLogo(size:)`, `TmdbAttribution()`, `TmdbLogo(height:)`, `TmdbAttribution.notice` |
| Images | `ArtworkImage(url:, fallbackText:, cornerRadius:, outlined:, maxPixel:)` (loads via `AppServices.images`, breathing placeholder), `AsyncPoster(url:, title:)`; `ArtworkLoader.load(url, maxPixel:) -> NSImage?` |
| Cards | `PosterCard(PosterItem(...), onTap:)` (default: opens `item.route`), `WideCard(PlayItem(...), onDetails:) { play }`, `WatchedCheck()` |
| Shelves / grids | `HorizontalRow(items, itemWidth: 160, arrowCenter: 120) { PosterCard($0) }`, `VAdaptiveGrid(items, minItemWidth: 150) { cell }`, `VPosterGrid(posterItems)` (inside a `ScrollView`) |
| Formatting | `Formats.runtime(136)` "2h 16m", `runtimeMs`, `remaining(positionMs:durationMs:)`, `episodeCode(1, 2)` "S1 · E2", `episodeCodeCompact` "S01E02", `airLabel`, `reminderLabel`, `longDate`, `size(bytes)`, `rating`, `join`/`joinTight`, `seasons`/`episodes`/`plural`, `clock(ms:)` |
| Misc | `VDivider(vertical:)`, `openInBrowser(url)` |

## Dialogs and toasts

```swift
if await Dialogs.confirm(title: "Remove folder?", message: "…", confirm: "Remove", danger: true) { … }
let name = await Dialogs.textInput(title: "Rename", placeholder: "Name", initial: old, confirm: "Rename")
let kind = await Dialogs.choose(title: "…", message: "…", options: [("Movies", 1), ("TV Shows", 2)])
await Dialogs.alert(title: "Couldn't connect", message: error)
let result: MyResult? = await Dialogs.present { ctl in MyDialog(controller: ctl) }   // custom; wrap in VDialog(title:) { } actions: { }
let handle = Dialogs.show { VDialog(title: "Extracting…") { VLoadingBox(height: 80) } }; handle.close()
Toast.show("Removed from your Watchlist", actionTitle: "Undo") { … }   // any thread; AppServices.toast(...) too
```
Dialogs appear over the main window when it is active, else in a floating panel over the active window (player).
Esc dismisses (`present` returns nil). Windows other than the shell can add `ToastHostView()` / `DialogHostView()`.

## Folder picker

```swift
if let f = await FolderPicker.pick(account: Accounts.device) { f.id; f.name }          // NSOpenPanel on This Mac
if let f = await FolderPicker.pickLibraryFolder(account: email) { f.id; f.name; f.type } // + "What's in …?" step
let t = await FolderPicker.askLibraryType(folderName: "Films")
```
Drive / SMB are browsed through `AppServices.storage` (an SMB server's share list can't be chosen).

## Shell status

`ShellStatus.shared`: `isOffline`, `scanText`, `scanProgress` (bound by `VeltoretUIModule.start()`), plus slots
`banner: AnyView?` (above the page) and `railAccessory: AnyView?` (bottom of the rail).
