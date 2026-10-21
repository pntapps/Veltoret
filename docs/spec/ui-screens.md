# Veltoret UI screens: porting spec (phone/tablet → Windows WPF)

Source: Android app `com.pntapps.veltoret` (Kotlin/Compose), commit e64fe84. Paths below are relative to
`app/src/main/java/com/pntapps/veltoret/`. Out of scope here: TV UI, player, Files, Settings (except where
screens link to them).

**Desktop reference layout = Android `WidthClass.Expanded`** (window width ≥ 840 dp): nav rail on the left,
40 px gutter, side-by-side featured hero, two-column episodes and versions, 6-column collection grid.
Recommended mapping: **1 dp = 1 WPF DIU, 1 sp = 1 DIU** (WPF DIUs are already DPI-independent).
If the Windows window gets narrower than 840, you can either keep Expanded (simplest) or implement
the Medium/Compact buckets as listed for each screen.

Width classes (`ui/util/AppViewModel.kt`):

| Class | Width | Gutter |
|---|---|---|
| Compact | < 600 | 20 |
| Medium | 600–839 | 28 |
| Expanded | ≥ 840 | 40 |

`gutter()` is the horizontal page margin used everywhere (section headers, rows' content padding, grids).

---

## 1. Design system

### 1.1 Colors (`ui/theme/Color.kt`, object `VColors`). Dark only. **No gradients anywhere** (only TMDB's own logo has one).

| Token | Hex (ARGB) | Use |
|---|---|---|
| Background | `#FF0B0B0D` | page background |
| BackgroundOled | `#FF000000` | background when the "OLED black" setting is on (replaces Background and `surface`) |
| Surface | `#FF15151A` | nav rail, bottom bar, panels, chips (unselected), empty-state disc |
| SurfaceHigh | `#FF1E1E25` | image placeholder, secondary button, icon-button disc, dropdown menus, dialogs |
| SurfaceHighest | `#FF26262F` | secondaryContainer / surfaceBright |
| Outline | `#FF2C2C35` | 1 px hairlines on cards/panels/posters, progress track, dividers |
| OutlineStrong | `#FF3B3B46` | secondary button border, pill border, inactive pager dot |
| Text | `#FFF3EFE6` | primary text (warm off-white). Default content color |
| TextMuted | `#FF9C9AA3` | secondary text, inactive nav |
| TextFaint | `#FF6B6973` | tertiary text, disabled, attributions |
| Amber | `#FFE8A33D` | accent: primary button, selected nav, ratings star, links, progress fill |
| AmberSoft | `#FFF3C77F` | text on AmberDim, offline label |
| AmberDim | `#FF3A2B14` | selected nav pill / chip background, accent pill bg |
| OnAmber | `#FF1B1206` | text/icons on Amber |
| Danger | `#FFFF6B5E` | errors |
| Success | `#FF6FCF97` | "Key verified" |
| ImageDim | `#99000000` (60% black) | flat dim over imagery (play disc on cards, progress track over posters, icon buttons on images) |
| BackdropDim | `#B8000000` | TV only |
| PlayerChrome | `#8C000000` | player only |

Extra literal colors: solid Pill background `#D90B0B0D` (85% Background). Onboarding illustrations use
their own palette (see §9.7).

Material color-scheme mapping (Theme.kt), useful for default WPF control styles: primary=Amber,
onPrimary=OnAmber, primaryContainer=AmberDim, onPrimaryContainer=AmberSoft, secondary=TextMuted,
background/surface=Background (or OLED), onSurface=Text, surfaceVariant=SurfaceHigh,
onSurfaceVariant=TextMuted, surfaceContainer(Low)=Surface, surfaceContainerHigh=SurfaceHigh,
surfaceContainerHighest=SurfaceHighest, outline=OutlineStrong, outlineVariant=Outline, error=Danger,
scrim=ImageDim.

### 1.2 Typography (`ui/theme/Type.kt`)

Fonts: **Fraunces** (variable serif; axes `wght`=style weight, `opsz`=72, `SOFT`=50) for display/headline;
**Inter** (variable) for everything else. Both are bundled as `res/font/fraunces.ttf`, `res/font/inter.ttf`
(variable fonts). In WPF, bundle static instances (Fraunces 72pt Soft SemiBold 600 is the main one; Inter
400/500/600/700) because WPF can't set variable axes. Letter spacing is in **em** (multiply by font size;
WPF `Typography`/`CharacterSpacing` uses 1/1000 em → em × 1000).

| Style | Family | Size | Weight | Line height | Letter spacing (em) | CharacterSpacing |
|---|---|---|---|---|---|---|
| displayLarge | Fraunces | 48 | 600 | 54 | −0.02 | −20 |
| displayMedium | Fraunces | 38 | 600 | 44 | −0.02 | −20 |
| displaySmall | Fraunces | 30 | 600 | 36 | −0.015 | −15 |
| headlineLarge | Fraunces | 28 | 600 | 34 | −0.01 | −10 |
| headlineMedium | Fraunces | 24 | 600 | 30 | −0.01 | −10 |
| headlineSmall | Fraunces | 20 | 600 | 26 | −0.01 | −10 |
| titleLarge | Inter | 19 | 600 | 26 | 0 | 0 |
| titleMedium | Inter | 16 | 600 | 22 | 0 | 0 |
| titleSmall | Inter | 14 | 600 | 20 | 0 | 0 |
| bodyLarge | Inter | 16 | 400 | 24 | 0 | 0 |
| bodyMedium | Inter | 14 | 400 | 21 | 0 | 0 |
| bodySmall | Inter | 12 | 400 | 17 | 0 | 0 |
| labelLarge | Inter | 14 | 600 | 20 | 0.01 | 10 |
| labelMedium | Inter | 12 | 600 | 16 | 0.02 | 20 |
| labelSmall | Inter | 11 | 600 | 14 | 0.06 | 60 |

Where each is used (most common): screen titles = headlineLarge; section headers = headlineSmall;
featured/detail titles = displaySmall; card title = titleSmall; card subtitle = bodySmall/TextMuted;
buttons and chips = labelLarge; nav labels, pills, eyebrows ("FILM"/"SERIES") = labelSmall.
Special: image fallback text and tagline use **titleMedium size with the serif family** (tagline also italic).

### 1.3 Shapes / corner radii

| Name | Radius | Used by |
|---|---|---|
| Material extraSmall | 6 | Pill (badge) |
| small | 10 | SelectChip, ScanChip, CopyField |
| medium | 14 | CardShape (wide cards, panels, episode rows, file rows), nav rail items |
| large | 20 | Featured hero image |
| extraLarge | 28 | Onboarding poster wall |
| PosterShape | 12 | poster cards, detail poster |
| Button (VButton) | 12 | all text buttons; VTextField also 12 |
| Detail backdrop frame (Expanded) | 24 | detail header backdrop |
| Bottom-bar icon pill | 12 | (phone only) |
| Pager dot | 2 | featured pager indicator |
| SectionHeader action hit area | 8 | "See all" |
| StatTile / ErrorCard | 16 | onboarding |
| Circles | — | icon buttons, empty-state disc, cast photos, watched badge, play discs |

All bordered elements use a **1 px** border (`Outline` unless noted). Exception: Expanded detail poster has a
2 px border in the page background color.

### 1.4 Spacing constants

- Gutter 20/28/40 (see table above). Rows: section spacing `top = 28` above each row, `12` between header
  and row, `16` between cards in a row.
- Home list bottom padding 32; detail pages 40.
- Library grid gaps (Expanded/Medium): horizontal 20, vertical 28 (Compact 14/20).
- Search grid gaps: 14 h / 20 v. Fix-match/unmatched grids: 10/10.

### 1.5 Image sizes and aspect ratios (TMDB, `data/tmdb/TmdbApi.kt` `TmdbImages`)

Base URL `https://image.tmdb.org/t/p/` + size + path. Defaults: poster `w342`, backdrop `w1280`, still
`w300`, profile `w185`.

| Where | Kind | Size | Aspect |
|---|---|---|---|
| Poster cards (Home rows, grids, search, collection parts, related) | poster | w342 | 2:3 |
| Featured hero | backdrop | w1280 | 16:9 |
| Continue Watching / Next Up wide cards | episode still `w780`, else show/movie backdrop `w780` | w780 | 16:9 |
| Detail header backdrop | backdrop | w1280 | Expanded 16:9 framed; Medium 2.4:1; Compact 16:9 |
| Detail header poster | poster | w500 | 2:3 |
| Collection page header | collection backdrop w1280 / poster w500 (fallback: the earliest owned movie's) | | |
| Episode rows (show page) | still | w300 | 16:9 |
| Cast | profile | w185 | circle 76 |
| Fix match candidates | poster | w185 | 2:3, 64 wide |

`VImage` = flat `SurfaceHigh` placeholder that "breathes" (alpha 0.55↔1.0, 900 ms, FastOutSlowIn, reverse,
infinite) while loading; Crop scaling; if `url == null` and a fallback text is given, it shows that text
centered in serif titleMedium, TextMuted, max 4 lines, 12 padding. Fallbacks: posters → title; cast →
initials (first letter of first two words); episode still → `E{n}`; fix-match → first letter of title.

### 1.6 Motion (`ui/components/Motion.kt`, AppShell)

- **Press scale** (`pressScale`): while pressed scale to **0.96** (cards) / **0.97** (VButton); spring
  dampingRatio 0.6, stiffness MediumLow (≈ 400). WPF: ScaleTransform animated ~150–200 ms with a slight
  overshoot (BackEase amplitude ~0.3) or an EasingFunction approximating a spring.
- **Entrance** (`Modifier.entrance(index, baseDelayMs=0, stepMs=70)`): starts alpha 0 and translateY +18;
  after `index × 70 ms` delay, alpha → 1 over 420 ms FastOutSlowIn (cubic-bezier 0.4,0,0.2,1) and translateY
  → 0 with spring (damping 0.8, stiffness Low ≈ 200, ~500 ms). **Plays once** per element (stored state);
  must not replay when scrolled back into view. Used on: Home hero (0), Continue Watching row (1),
  detail Expanded backdrop (1) and poster (2), onboarding elements (indices given in §9).
- **Placeholder pulse**: see VImage.
- **Navigation transitions**: push = new page slides in from +1/6 width + fade in (320 ms), old fades out
  (180 ms). Pop = previous fades in (260 ms), current slides out to +1/6 width and fades (260 ms).
- **Featured pager**: auto-advance every **8 s** after the page settles (only when > 1 item), animated scroll;
  wraps to page 0.
- Offline strip (phone only): expand/fade. Rail offline label: fade.

### 1.7 Shared components (`ui/components/Components.kt`)

**PosterCard(title, subtitle, imageUrl, onClick, onLongClick?, progress?, watched, badge?)**
- Column with pressScale. Image box: full width, 2:3, PosterShape (12), 1 px Outline border, ripple click.
- `badge` → Pill (solid) top-start, 8 padding. Text is uppercased.
- `watched` → 22×22 Amber circle top-end, 8 padding, Check icon 15 px OnAmber, tooltip "Watched".
- `progress > 0` → VProgress at bottom, 8 padding, track `ImageDim`.
- 8 gap, title titleSmall 1 line ellipsis; subtitle (if not null) bodySmall TextMuted 1 line.

**WideCard(title, subtitle, imageUrl, onClick, progress?, caption?)** (Continue Watching, Next Up)
- 16:9, CardShape (14), 1 px Outline border. Bottom-start 10 padding: 34 px ImageDim circle with PlayArrow
  20 px Text color. `caption` → solid Pill top-end 8 padding.
- If progress != null: 8 gap then VProgress (3 px, track Outline) **below** the image. Then 8 gap, title
  titleSmall, subtitle bodySmall TextMuted, each 1 line.

**Pill(text, solid=false, accent=false)**: text uppercased, labelSmall; corner 6; padding 7 h × 3 v; border
1 px. accent: bg AmberDim, text AmberSoft, border Amber @ 50% alpha. solid: bg `#D90B0B0D`, text Text, border
OutlineStrong. plain: transparent, Text, OutlineStrong.

**RatingText(rating)**: hidden when ≤ 0. Star icon 15 px Amber, 3 gap, `"%.1f"` (US locale) labelLarge Text.

**VButton(text, icon?, style, enabled, loading)**: min height 48, corner 12, padding 20 h × 12 v, centered.
Primary: bg/border Amber, fg OnAmber. Secondary: bg SurfaceHigh, border OutlineStrong, fg Text. Ghost:
transparent, border Outline, fg Text. Disabled: bg SurfaceHigh, border Outline, fg TextFaint. Loading:
18 px spinner (stroke 2) + 10 gap replaces icon, and click disabled. Icon 20 px + 8 gap. Label labelLarge,
single line. pressScale 0.97.

**VIconButton(icon, desc, size=42, onImage=false, tint=Text)**: circle; bg SurfaceHigh with 1 px Outline,
or ImageDim with no border when `onImage`. Icon = 50% of size.

**SelectChip(label, selected, icon?)**: height 36, corner 10, padding 14 h. Selected: bg AmberDim, border
Amber @ 60%, label AmberSoft. Unselected: bg Surface, border Outline, label Text. Optional icon 16 px
(AmberSoft / TextMuted) + 6 gap. Label labelLarge.

**SectionHeader(title, actionLabel?, onAction?)**: row with gutter padding; title headlineSmall (fills);
action = labelLarge Amber text, 8×6 padding, corner-8 hit area.

**ScreenHeader(title, subtitle?, onBack?, actions)**: row padding start = 12 if back else gutter, end 12,
top 12, bottom 8 (plus status bar on Android: ignore on Windows). Back = VIconButton ArrowBack "Back" + 12
gap. Title headlineLarge 1 line ellipsis; subtitle bodySmall TextMuted 1 line. Actions on the right with
8 spacing.

**EmptyState(icon, title, message, actionLabel?, onAction?)**: centered column, padding 32. 72 px circle
(Surface, 1 px Outline) with icon 32 px Amber; 20 gap; title headlineSmall centered; 8 gap; message
bodyMedium TextMuted centered; if action: 24 gap + Primary VButton.

**LoadingBox**: fill, centered 32 px Amber spinner, stroke 2.5.

**MetaLine(parts)**: drops null/blank, joins with `"  ·  "` (two spaces each side), bodyMedium TextMuted,
max 2 lines.

**VProgress(progress, height=3, track=Outline)**: full width, rounded (radius = height), fill Amber,
clamped 0..1.

**VTextField**: outlined text field, corner 12, container Surface, border Outline (focused Amber), label
TextMuted (focused Amber), cursor Amber, placeholder TextFaint, leading icon TextMuted.

**Panel**: full width, CardShape, bg Surface, 1 px Outline, padding 16 (default).

**Wordmark(large=false)**: "Veltoret" in headlineMedium (large: displayMedium), SemiBold, followed by an
Amber dot: 6 px (large 9 px), start padding 3, top padding 8 (large 14) — the dot sits near the baseline,
like a period.

**TmdbAttribution**: TMDB logo (aspect 273.42:35.52, height 12), 8 gap, notice text bodySmall TextFaint:
`This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.`

Dropdown menus: Material DropdownMenu, container SurfaceHigh; selected item text Amber.
Toasts → use a small transient WPF toast/snackbar.

---

## 2. App shell and navigation (`ui/AppShell.kt`, `ui/navigation/Navigation.kt`)

### 2.1 Top-level destinations (order matters)

| Route | Label | Icon (Material Rounded) |
|---|---|---|
| HomeRoute | Home | Home |
| MoviesRoute | Movies | Movie |
| ShowsRoute | TV Shows | LiveTv |
| FilesRoute | Files | Folder |
| SettingsRoute | Settings | Settings |

Other routes: SearchRoute, UnmatchedRoute, ArchivesRoute, MovieRoute(id), ShowRoute(id),
CollectionRoute(id), FixMatchRoute(fileIds: List<string>, kind: "MOVIE"|"EPISODE", query: string).

### 2.2 Navigator semantics (single back stack, "exit through Home")

- `navigate(route)`: push, unless the top is already equal to `route`.
- `selectTab(route)`: no-op if top == route; else clear stack, push Home, then push route if ≠ Home.
- `back()`: pop if stack size > 1.
- `currentTopLevel`: last top-level route in the stack, else Home (drives rail selection, so detail pages
  keep their tab highlighted).
- Windows: map Back to Esc / Alt+Left / mouse XButton1.

### 2.3 Nav rail (Medium + Expanded; desktop reference)

- Column, width **92**, bg Surface, padding vertical 20, horizontally centered; then a **1 px Outline
  vertical divider** on its right.
- Logo: "V" in displaySmall + Amber dot 6×6 (radius 3), top padding 22, start padding 1 (dot beside the V,
  at its baseline). Then 28 gap.
- Each destination: outer padding vertical 6, clickable area corner 14 with inner padding 6/6. Icon pill:
  corner 14, padding 18 h × 8 v, bg AmberDim if selected else Surface; icon 24 (default) Amber if selected
  else TextMuted. 4 gap, label labelSmall (Amber / TextMuted).
- Spacer pushes to bottom: when offline, CloudOff icon 20 AmberSoft + 4 gap + "Offline" labelSmall
  AmberSoft (fade in/out).
- Content area fills the rest.

Phone-only (Compact): bottom bar (Surface, 1 px top Outline, height 68, icon pill corner 12 padding 16×4,
icon 22) and an offline strip above it: AmberDim bg, padding 16×7, CloudOff 16 AmberSoft + 8 gap +
`Offline · showing videos on this device` labelMedium AmberSoft.

### 2.4 Offline concept

`online` = internet reachable. Offline, the library repository shows only titles with a **device copy**
(Windows equivalent: local files) and `availableEpisodes` becomes device episode count; Drive-only episodes
are dropped from Continue Watching. `canPlayNow(account, online) = online || isLocal(account)`.
On Windows, "device" = local disk folders.

---

## 3. Home (`ui/home/HomeScreen.kt`, `HomeViewModel.kt`)

### 3.1 Layout (vertical scroll list, bottom padding 32)

1. **Header row**: padding start=gutter, end 12, top 12, bottom 12. `Wordmark` (fills), then if scanning
   a **ScanChip** + 8 gap, then Cast button (skip on Windows or replace) + 8 gap, then VIconButton Search
   ("Search") → SearchRoute.
   - ScanChip: corner 10, bg Surface, 1 px Outline, padding 10×6; 12 px Amber spinner (stroke 1.5), 8 gap,
     text labelMedium TextMuted: `Matching` if scan phase starts with "Matching", else `Syncing {filesFound}`.
2. **Status block** (exactly one, first match wins):
   - loading → LoadingBox height 400.
   - no library folders → EmptyState(CreateNewFolder, `Choose your library folders`,
     `Pick the Google Drive or device folders that hold your movies and TV shows.`, action `Open Settings`
     → selectTab(Settings)).
   - library empty (no movies and no shows) AND scan running → EmptyState(VideoLibrary,
     `Building your library`, `Found {filesFound} videos so far. Posters will appear here as titles are matched.`).
   - empty AND offline → EmptyState(CloudOff, `Nothing on this device`,
     `Your library is on Google Drive. Connect to the internet to watch it, or add a folder from this device in Settings.`).
   - empty → EmptyState(VideoLibrary, `Nothing here yet`, message = scan error if any, else
     `No videos were found in your library folders. Add files to Drive and scan again.`, action `Scan now`
     → user-initiated scan with notification).
3. **Featured pager** (if any featured; entrance index 0) — see 3.3.
4. **Unmatched panel** (if unmatchedCount > 0 AND online): Panel, padding gutter h × 12 v, clickable →
   UnmatchedRoute. Row: ErrorOutline icon Amber, 12 gap, column: `{n} file needs a match` / `{n} files need a match`
   (titleSmall) and `Tap to identify them on TMDB` (bodySmall TextMuted). (Windows: "Click to…" is fine.)
5. **Archives panel** (if archiveCount > 0): Panel, padding gutter × 6, → ArchivesRoute. FolderZip icon
   Amber; `{n} ZIP archive in your library` / `{n} ZIP archives in your library`;
   `Tap to unpack them so they can play`.
6. Rows, each only if non-empty, in this order:
   | Row title | Kind | Action |
   |---|---|---|
   | Continue Watching | wide (entrance 1) | click plays the file |
   | Next Up | wide | plays |
   | Watchlist | poster | opens title |
   | Coming Up | poster | opens show |
   | Recently Added Movies | poster | header action `See all` → selectTab(Movies) |
   | Recently Updated Shows | poster | `See all` → selectTab(TV Shows) |
   | Highly Rated | poster | |
   | Collections | poster | opens CollectionRoute |
   | {genre} × up to 5 | poster | |

Row layout: column with top padding 28; SectionHeader; 12 gap; horizontal list, content padding gutter,
item spacing 16. Card widths: **poster 164** (Medium 150, Compact 124); **wide 360** (Medium 320, Compact
260). On Windows add horizontal scroll by mouse wheel/shift-wheel and optional left/right arrow buttons.

Poster click route: collection → CollectionRoute(id); isShow → ShowRoute(id); else MovieRoute(id).

### 3.2 Item shapes

`PosterItem { id, isShow, title, subtitle, posterUrl, progress?, watched, badge?, collection }`
- moviePoster: subtitle = `"{year} · {runtime}"` (nulls dropped, joined `" · "`), poster w342, progress =
  state.progress if state exists, not watched, positionMs > 0; watched = state.watched.
- showPoster: subtitle `"{availableEpisodes} episode"` / `"… episodes"`; no progress/watched.

`PlayItem { fileId, title, subtitle, imageUrl, progress?, caption?, movieId?, showId? }`

Runtime format: `"2h 46m"`, `"48m"`, `"2h"`; null when ≤ 0. Remaining: `"{m}m left"` or
`"{h}h {m}m left"` (minimum 1 minute). Episode code: `"S{s} · E{e}"`; season 0 → `"Special {e}"`; empty
when null.

### 3.3 HomeViewModel row logic (exact)

Inputs: movies (MovieRow: movie + addedAt = MIN(file.addedAt) + maxHeight + fileCount + deviceFiles),
shows (ShowRow: show + addedAt = **MAX**(file.addedAt) + availableEpisodes = distinct (season,episode)
count), all watch states, episode files (offline: local only), all TMDB episodes, watchlist (ordered
addedAt DESC), unmatched count, archive count, library folders, scan state. Watch-state keys:
`movie:{id}`, `ep:{showId}:{season}:{episode}`.

**Featured (hero), max 6**
1. Merge movies (addedAt, movie) and shows (addedAt, show); sort by addedAt DESC.
2. Keep shows with a backdrop; keep movies with a backdrop **and not watched**.
3. Build FeaturedItem: title, backdrop w1280, meta list, overview, rating.
   - Movie meta: `[year, certification, first genre, runtime]`.
   - Show meta: `[year, certification, first genre, "{n} season"/"{n} seasons"]`.
   (first genre = `genres.split(',').first()` — genres stored as comma-separated string.)
4. Keep those with rating ≥ **5.5**; if that leaves none, use all.
5. Take first 6.

**Continue Watching, max 20**
- States where `!watched && positionMs > 30_000 && lastFileId != null`, sorted by lastWatchedAt DESC.
- Movie state → if movie in library: PlayItem(fileId=lastFileId, title, subtitle=remaining(pos,dur),
  image=backdrop w780, progress, caption=null).
- Episode state → **dropped if no episode file exists** for that (show, season, episode) in the (possibly
  offline-filtered) episode files; else PlayItem(title = show name, subtitle = `"S1 · E2  ·  {episode name}"`
  (join `"  ·  "`, name optional), image = episode still w780 else show backdrop w780, progress,
  **caption = remaining time** (pill top-right)).
- Take 20.

**Next Up, max 20**
- Group episode files by showId; skip shows already present in Continue Watching.
- Skip shows with **no watched episode** state.
- Target = `PlayTargets.nextEpisode(files, showStates)` (below); skip if null or show missing.
- PlayItem(fileId = target file, title = show name, subtitle as above, image still w780 else backdrop,
  progress null, **caption `"Next"`**).
- Sort by the show's latest `lastWatchedAt` DESC; take 20.

`PlayTargets.nextEpisode(files, states)`:
- playable = files with season & episode, sorted by (season, with 0 last), then episode; distinct by
  (season, episode).
- lastWatched = watched state with season, max lastWatchedAt. inProgress = unwatched, positionMs > 30 000,
  max lastWatchedAt.
- If inProgress exists and is newer than lastWatched → that episode (resuming=true) if its file exists.
- Else if lastWatched exists → first playable after it (season 0: only later specials; otherwise later
  season ≠ 0, or same season with higher episode) that isn't watched → resuming=false; none → null.
- Else (nothing watched) → first non-special episode (or first) with fresh=true.

**Watchlist** (no limit; watchlist order = most recently added first)
- Movie entries: in library and not watched → moviePoster. Show entries: in library → showPoster.

**Coming Up** (no limit)
- followed = Watchlist show ids ∪ every showId that has any watch state.
- Shows that are followed and whose `nextEpisodeAirDate` is today or later; sort by that date ASC.
- showPoster with subtitle = `"S{s} · E{e}"` (null if empty) and **badge = airLabel(date)**:
  `Today`, `Tomorrow`, weekday name (`Friday`) if < 7 days, else `"EEE, MMM d"` (`Fri, Oct 23`), US locale.

**Recently Added Movies**: movies by addedAt DESC, take 20, moviePoster.
**Recently Updated Shows**: shows by addedAt (= newest episode file) DESC, take 20, showPoster.

**Highly Rated**: movies + shows with rating ≥ **7.0**, sorted by rating DESC, take 20. **Shown only if at
least 4 items**, otherwise empty.

**Collections** (no limit): movies with collectionId; group; keep groups with ≥ **2** movies. Item: id =
collectionId, title = collectionName (fallback the movie title), subtitle `"{n} movies"`, poster = the
movie with the max releaseDate (string compare) in the group, collection=true. Sort by the group's max
addedAt DESC.

**Genre rows**: for every movie and show, each non-blank genre → (rating, poster). Group by genre; keep
genres with ≥ **4** items; sort genres by item count DESC; take **5**; inside each, sort by rating DESC,
take 20. Row title = genre name. Movies and shows mixed.

`isEmpty` = recentMovies empty AND recentShows empty. `hasFolders` = any library folder configured.

**Featured pager UI (Expanded)**
- Horizontal pager, content padding gutter on both sides, page spacing = gutter (neighbors hidden).
- Expanded page: Row, vertically centered: image (weight 1.2) | 36 gap | info (weight 1, title max 3 lines).
  Compact/Medium: image full width, 16 gap, info below (title max 2 lines).
- Image: 16:9, corner 20, 1 px Outline, click → details; fallback text = title.
- Info: eyebrow `FILM` or `SERIES` (labelSmall Amber); 6 gap; title displaySmall; 8 gap; row: RatingText
  (+12 gap if rating > 0) + MetaLine(meta); if overview: 10 gap + overview bodyMedium TextMuted max 3 lines;
  16 gap; buttons row spacing 10: Primary `Play` (PlayArrow) and Secondary `Details` (Info icon).
  Play resolves the target (movie: best file; show: next episode, or episode 1 again when all watched) and
  starts playback.
- Indicator (if > 1 item): row padding top 16, start gutter, spacing 6; each bar height 3, corner 2, width
  22 (current, Amber) / 8 (others, OutlineStrong). Column bottom padding 8.
- Auto-advance every 8 s.

---

## 4. Movies / TV Shows library grids (`ui/library/LibraryScreens.kt`)

Same screen for both; title `Movies` (icon Movie) or `TV Shows` (icon LiveTv).

### 4.1 Layout

- ScreenHeader(title, subtitle) with actions: VIconButton Search → SearchRoute; VIconButton Sort ("Sort",
  icon Sort) opening a dropdown.
- Subtitle: hidden while loading; with a source filter active: `"{shown} of {total} titles · {source label}"`;
  else `"{total} title"` / `"{total} titles"`.
- Sort dropdown items (selected = Amber): `Recently added`, `Title`, `Release year`, `Rating`. If source
  list non-empty: divider (Outline, 4 v padding), caption `SOURCE` (labelSmall TextMuted, padding start
  12/top 6/bottom 2), then `All sources` + each source label.
- Body:
  - loading → LoadingBox.
  - total == 0 AND offline → EmptyState(CloudOff, `No movies on this device` / `No tv shows on this device`,
    `Your movies are on Google Drive. Connect to the internet to watch them, or add a folder from this device in Settings.`)
    — note: built with `title.lowercase()`, so the show variant literally reads "tv shows".
  - total == 0 AND unmatched == 0 → EmptyState(icon, `No movies yet` / `No tv shows yet`,
    `Add a movies folder in Settings, or wait for the library scan to finish.` (resp. "a tv shows folder")).
  - else adaptive grid: min cell **156** (Medium 140, Compact 108), content padding gutter left/right and
    32 bottom, gaps 20 h / 28 v.
- First grid row (full span): horizontal chip strip, spacing 8, bottom padding 4:
  1. if unmatched > 0 and online: chip `"{n} unmatched"` (ErrorOutline icon, never selected) → UnmatchedRoute.
  2. Filter chips: `All`, `Unwatched`, `In progress`, `Watched`, `4K`.
  3. If genres exist: chip labelled with selected genre or `Genre` (Tune icon, selected when a genre is set)
     opening dropdown: `All genres`, then genres ordered by how many titles have them (DESC).
- If filtered list empty: full-span text `Nothing matches these filters.` TextMuted, 40 v padding.
- Items: PosterCard (title, subtitle, poster, progress, watched). Click → detail.

### 4.2 Data logic

Movies entry: status = Watched if state.watched; InProgress if state exists with positionMs > 30 000;
else Unwatched. Subtitle `"{year} · {runtime}"`. progress only when InProgress. uhd = maxHeight ≥ 1600.
sources = distinct accounts holding a file of the movie.

Shows entry: watched set = distinct (season, episode) of watched episode states. Unwatched if none;
Watched if count ≥ availableEpisodes; else InProgress. Subtitle: InProgress → `"{w} of {n} watched"`; else
`"{n} episode(s)"`. progress = w/n when InProgress. uhd = any episode file height ≥ 1600. sources =
accounts of any episode file.

Filters: source (title has a copy in it) AND genre AND (All | 4K → uhd | status == filter).
Sorts: Recent → added DESC; Title → `title.removePrefix("The ").lowercase()` ASC; Year → year DESC
(missing = 0); Rating → rating DESC.
Sources list: only when online; accounts that actually hold something; ordered device first, Google
accounts, then SMB servers; labels = device display name / SMB display name / email; **hidden if ≤ 1
source**. A selected source that disappears falls back to all.
Unmatched count per screen: unmatched files of kind MOVIE (Movies) or EPISODE (Shows).
Total = all entries (pre-filter). Filter state is per screen, in memory.

---

## 5. Search (`ui/search/SearchScreen.kt`)

- ScreenHeader `Search` with Back.
- Text field: full width, padding gutter, **max width 720**, label `Titles, actors, directors, collections`,
  leading Search icon, autofocus on open (unless opened by voice). Trailing: if text not empty → Close
  icon "Clear" (clears); else if voice available → Mic icon Amber "Search by voice" (voice prompt
  `Say a title, actor or director`). Windows: voice optional/skip.
- If query not blank and no results: EmptyState(SearchOff, `No results`, `Nothing in your library matches "{query}".`).
- Adaptive grid min cell **150** (Compact 108), padding gutter × 20 v, gaps 14 h / 20 v:
  full-span header `Movies` (headlineSmall) + PosterCards; then `TV Shows` + PosterCards.
  PosterCard subtitle = `"{year} · {reason}"` (either part optional; null if both missing). No progress/watched.
- Logic: query debounced **200 ms**, trimmed; blank → nothing. Local DB search (SQL `LIKE %q%`,
  case-insensitive ASCII):
  - Movies: match title or originalTitle (reason null), else director (reason `Directed by {director}`),
    else collectionName (reason = collection name), else a cast credit name (reason = that person's name,
    first by billing order). Order: title matches first, then year DESC. Limit 60.
  - Shows: name (reason null), creator (`Created by {creator}`), cast name. Same ordering, limit 60.
  - Hits are kept only if the title is in the current (online/offline-filtered) library.

---

## 6. Movie detail (`ui/details/MovieDetailScreen.kt`, `DetailCommon.kt`, `DetailActions.kt`)

### 6.1 Header (`DetailHeader`) — Expanded (desktop)

Row, padding start 40, end 40, top 16, bottom 12:
- Left column (weight 1, end padding 40): VIconButton Back (42) → back; 24 gap; **info** content.
- Right box (weight 1.1, padding top 58, bottom 48): backdrop w1280, full width 16:9, corner **24**, 1 px
  Outline (entrance 1). Poster w500 overlaid bottom-start: start padding 20, offset y **+48** (hangs below
  the backdrop), width **124**, 2:3, PosterShape, **2 px border in page background color** (entrance 2).

Medium: backdrop 2.4:1 full width with Back on image (onImage) at 12 padding; then row padding 28: poster
180 wide (1 px Outline) | 28 gap | info. Compact: backdrop 16:9, Back on image, info padding 20.
**No text is ever placed on artwork** (no scrim needed).

### 6.2 Info content (movie)

1. Title displaySmall; tagline (if any): 6 gap + serif titleMedium italic TextMuted.
2. 12 gap; row: RatingText + 12 gap (if rating > 0) + MetaLine `[year, certification, runtime]`.
3. TagRow (if any): 12 gap then wrap panel spacing 6/6: quality pills (accent) first — from the best file's
   `qualityTags(name, height)`, max 4 — then genre pills (plain).
4. 20 gap. If resumable (state exists, not watched, positionMs > 30 000): VProgress (bottom padding 6),
   remaining text bodySmall TextMuted, 12 gap.
5. **DetailActionRow** (see 6.4). Play label: `Resume` (resumable) / `Watch again` (watched; icon Replay,
   plays from start) / `Play` (icon PlayArrow). Enabled when there's a best file and it can play now.
   `labelledTrailer = false` for movies (icon-only trailer at every width). Menu items:
   - `Mark unwatched` (RemoveDone) if watched, else `Mark watched` (Check)
   - `Remind me…` (NotificationsActive) → ReminderDialog
   - `Fix match` (Edit) → FixMatchRoute(all file ids, "MOVIE", movie title)
6. ReminderList (§6.6).
7. Overview: 20 gap, bodyLarge, Text @ 88% alpha (hidden if blank).
8. CreditLine `Director`, `Collection` (clickable → CollectionRoute; rendered Amber with `"  ›"` suffix),
   `Released` (date `"MMM d, yyyy"`, e.g. `Oct 23, 2015`). CreditLine: 10 gap; label labelLarge TextMuted
   fixed width 96; value bodyMedium. Hidden if blank.

Best file = first of the movie's files ordered: device copy first, then height DESC, then size DESC.

### 6.3 Sections below header

- **Cast** (if any; max 30 credits by order): top padding 32, SectionHeader `Cast`, 14 gap, horizontal row
  padding gutter, spacing 16. Item width 84 centered: 76 px circle photo (1 px Outline, fallback initials),
  8 gap, name labelMedium max 2 lines centered, character bodySmall TextMuted 1 line.
- **Versions / File** (if any files): top 32, header `Versions` if > 1 file else `File`, 12 gap; grid of
  FileRows, **2 per row on Expanded** (1 otherwise), spacing 10, padding gutter.
  FileRow = Panel padding 14, alpha 0.45 + disabled if it can't play now. Row: PlayArrow Amber, 12 gap,
  column: file name titleSmall 1 line; 4 gap; row of up to 3 accent quality pills (6 end padding) + text
  `"{size} · {duration}"` bodySmall TextMuted (size: `"%.1f GB"` for ≥ GB, else `"%.0f MB"`, etc.);
  4 gap; source line icon 13 px + 4 gap + text:
  - device → PhoneAndroid icon, `On this device` (AmberSoft)
  - SMB not playable → `Network server · needs Wi-Fi`; SMB → `Network server · {root name}`
  - Drive not playable → `Google Drive · needs internet`; Drive → the account email
  (CloudQueue icon, TextFaint). Click plays that exact file.
- **More like this** (if any): PosterRow `More like this` (poster width 164 Expanded), top padding +4.
  Data: TMDB recommendation ids stored per title; keep those in the library, in TMDB order, excluding self,
  distinct, **max 20**; same type only. Movie items include progress/watched.
- Attribution: `Metadata and artwork from TMDB` bodySmall TextFaint, padding start gutter, top 32.

On open (online): ensure recommendations are fetched; fetch trailer YouTube key (in-memory cache). If the
movie disappears (re-matched), go back automatically.

### 6.4 DetailActionRow overflow rules (exact)

Always **one line**: `[Play] [Trailer?] [Watchlist?] [⋮]`, spacing **GAP = 10**, icon buttons **ICON = 48**.
- buttonWidth(label) = measured labelLarge text width + **BUTTON_CHROME = 20×2 + 20 + 8 + 2 = 70**.
- playWidth = buttonWidth(playLabel); labelled = buttonWidth("Trailer").
- `fits(widths) = playWidth + ICON(⋮) + Σ(w + GAP) + GAP ≤ availableWidth`.
- Trailer mode (only if a trailer key exists and online):
  - `Labelled` if labelledTrailer && fits([ICON, labelled]) (watchlist icon + labelled trailer);
  - else `Icon` if fits([ICON, ICON]);
  - else `Menu`.
- Watchlist in row: if trailer mode is Menu or None → fits([ICON]); otherwise true.
- Play button: Primary VButton; on wide screens it hugs its label (weight with fill=false), on phones it
  takes spare width.
- Trailer Labelled = Ghost VButton `Trailer` (SmartDisplay icon); Icon = 48 VIconButton "Watch trailer".
  Opens `https://www.youtube.com/watch?v={key}` (Windows: default browser). Error toast if none:
  `Install YouTube to watch trailers`.
- Watchlist button: 48 VIconButton, Bookmark (filled, tint Amber) when saved / BookmarkBorder (Text);
  tooltip `Remove from Watchlist` / `Watch later`; toast `Removed from your Watchlist` /
  `Added to your Watchlist`.
- ⋮ (MoreVert, "More") menu order: `Watch trailer` (if Menu mode), then `Remove from Watchlist` /
  `Watch later` (if not in row; same toast), then the page's menu items.

### 6.5 Watchlist & reminders (`TitlePlans.kt`)

`saved` = title in watchlist; toggle adds/removes. Reminders: list for (type, id).

### 6.6 ReminderList & ReminderDialog

ReminderList: top 14, spacing 6; each: NotificationsActive 18 Amber, 8 gap, text bodyMedium
`"[S1 · E2  ·  ]Reminder {label}"` where label = `"Today at 9:00 PM"` / `"Tomorrow at …"` /
`"Fri, Oct 23 at 9:00 PM"`; then 32 px close button (Close 16 TextMuted, "Cancel reminder").

ReminderDialog (bg SurfaceHigh), title `Remind me`, then the item label (bodyMedium TextMuted), 12 gap,
choice rows (icon 20 Amber, 14 gap, bodyLarge; padding 8×12, corner 14):
- extra choices still in the future (episode: `When it airs ({airLabel}, 8 PM)` at air date 20:00)
- `Tonight, 8 PM` (only if now < 19:30), `Tomorrow, 8 PM`, `Saturday, 8 PM` (next Saturday, omitted when it
  equals tomorrow)
- `Pick a date and time…` (EditCalendar) → date picker (today or later; buttons `Next` Amber / `Cancel`)
  → time picker (initial 20:00, 12 h; title = formatted date; `Set reminder` Amber, enabled only if in the
  future; `Back`). Dismiss button `Cancel`.
On pick: toast `Reminder set for {label}` (or `Reminder set for {label}. Allow notifications so it can appear.`
when notifications are blocked).

---

## 7. Show detail (`ui/details/ShowDetailScreen.kt`)

### 7.1 Header info

- Title + tagline; RatingText + MetaLine `[year, certification, network, "{n} season(s)"]`.
- TagRow: quality = `Returning` pill (accent) if status == "Returning Series"; then genres.
- 20 gap; if target is resuming with a state: VProgress (bottom 12).
- Play label: no target → `All caught up` (disabled); resuming → `Resume S1 · E3`; else `Play S1 · E3`.
  Icon PlayArrow. `labelledTrailer = wide` (true on Medium/Expanded).
  Target = PlayTargets.nextEpisode over files that can play now.
- Menu: `Remind me…`, `Mark season watched` (DoneAll), `Mark season unwatched` (RemoveDone), `Fix match`
  (Edit → FixMatchRoute(all file ids, "EPISODE", show name)). Season actions apply to episodes **with files**
  in the currently selected season.
- ReminderList; Overview; if next episode is upcoming: CreditLine `Next episode` =
  `"S3 · E2  ·  “{name}”  ·  {airLabel}"` (curly quotes); CreditLine `Created by`, `First aired`.

### 7.2 Seasons chips

Horizontal strip, padding gutter, spacing 8, **top padding 40 on Expanded** (8 otherwise), bottom 16.
Season list = seasons that have at least one file; TMDB-only episodes are shown only for seasons that have
files. Order: 1..n, Specials (0) last. Label `Season {n}` / `Specials`; append `"  ✓"` when all available
episodes of the season are watched. Selected season default = the target episode's season, else first.

### 7.3 Episode list

Episodes of the selected season: union of file keys and TMDB episodes (for that season), sorted by number.
**2 per row on Expanded**, row padding horizontal `gutter − 20`.
EpisodeUi: name = TMDB name or `Episode {n}`; still w300; runtime = TMDB runtime or the file's duration;
air date `"MMM d, yyyy"`; file = first file for the key; watched; progress if unwatched and > 30 s;
needsInternet = file exists but can't play now; upcoming = air date ≥ today.

EpisodeRow (available = has file && !needsInternet):
- Row clickable (corner 14), padding 20 h × 10 v; click = play (from start if watched) if available, else
  opens its menu; right-click/long-press = menu.
- Thumbnail width **200** (wide) / 136, 16:9, corner 14, 1 px Outline, alpha 0.45 if unavailable; fallback
  `E{n}`; centered 34 px ImageDim disc + PlayArrow 20 when available; progress bar bottom (6 padding,
  ImageDim track).
- 14 gap; column (dimmed too): `"{n}. {name}"` titleSmall max 2 lines; 3 gap; `"{runtime} · {date}[ · status]"`
  bodySmall TextMuted, where status = `On Google Drive · needs internet` or `Not in library`; overview
  bodySmall TextMuted max 3 lines (wide) / 2.
- Trailing: if available → toggle icon CheckCircle (Amber, "Mark unwatched") / RadioButtonUnchecked
  (TextFaint, "Mark watched"), 24 px, 6 padding, start 8. Else if upcoming → NotificationsActive Amber
  "Remind me" → reminder for this episode.
- Menu: `Remind me…`; if available: `Mark unwatched` / `Mark watched`.
- Reminder label for an episode: `"{show} · S1 · E2"`; offers `When it airs (…, 8 PM)` if upcoming.

Below: Cast row, More like this (shows; subtitle episode count).

---

## 8. Collection page (`ui/details/CollectionScreen.kt`)

- Loading → LoadingBox. If no owned movies → go back.
- DetailHeader(name, backdrop, poster w500); info: title (no tagline), 12 gap, accent Pill badge:
  `"{owned} of {total} in your library"` (total known once TMDB answers) else `"{owned} in your library"`;
  Overview.
- SectionHeader `Movies` (top 28, bottom 12). Grid of PosterCards in rows of **6** (Medium 4, Compact 3),
  padding gutter, bottom 20 per row, spacing 14; empty cells padded.
- Parts: TMDB collection parts sorted by releaseDate ASC (empty dates last), owned ones replaced by library
  data (watched/progress). Not owned: alpha 0.42, not clickable, subtitle `"{year} · Not in your library"`.
  Offline/no TMDB: owned movies only, by releaseDate. Name/backdrop/poster fallback to the earliest owned
  movie.

---

## 9. Fix match flow (`ui/fixmatch/FixMatchScreens.kt`)

### 9.1 Unmatched ("Needs a match") screen

- ScreenHeader `Needs a match`, subtitle `Files we couldn't identify automatically`, Back.
- Loading → LoadingBox. If no unmatched and no ignored → EmptyState(CheckCircle, `All matched`,
  `Every file in your library has been identified.`).
- Adaptive grid min **420**, padding gutter × 20 v, gaps 10.
  - If no unmatched (but some ignored): full-span `Everything else is matched.` bodyMedium TextMuted.
  - Groups: unmatched files grouped by (kind, parsedTitle or file name if blank), sorted by title
    (case-insensitive). Card = Panel, click → FixMatchRoute(group file ids, kind, title). Content: title
    titleMedium 1 line; 2 gap; `"Movie · {n} file(s)"` or `"TV · {n} file(s)"` bodySmall **Amber**; first
    file's `relativePath/name` bodySmall TextMuted 1 line ellipsis; text button `Ignore` (TextMuted) →
    marks all group files IGNORED; chevron KeyboardArrowRight TextMuted.
  - If ignored exist: full-span header (top 18) `Ignored` titleLarge + `Kept out of your library. Restore one to match it again.`
    bodySmall TextMuted; ignored group Panels: title titleSmall TextMuted, first file name bodySmall
    TextFaint, text button `Restore` (Amber) → set PENDING and start a background scan.

### 9.2 Fix match screen

- ScreenHeader `Fix match`, subtitle `"{n} file"` / `"{n} files"`, Back.
- Chips (padding gutter, spacing 8): `Movie`, `TV Show` (selection = kind; switching re-runs the search).
- 12 gap; row (padding gutter, **max width 760**): VTextField label `Title (add a year to narrow)`, Search
  icon, Enter = search; 10 gap; Primary VButton `Search` (loading spinner while searching).
- Text button: `Not a movie or show? Ignore this file` / `… Ignore these files` (TextMuted) → mark IGNORED,
  then go back.
- Error text (Danger, bodySmall, padding 20): exception message or `Search failed` / `Could not apply match`.
- If not searching, no results and no error → EmptyState(Movie, `No results`,
  `Try a shorter title or switch between Movie and TV Show.`).
- Results grid min 420, gaps 10. Candidate Panel (padding 12), click (disabled while applying) → apply.
  Row: poster w185, width 64, 2:3, PosterShape, 1 px Outline (fallback first letter); 14 gap; column: title
  titleMedium max 2 lines; year bodySmall Amber; 4 gap; overview bodySmall TextMuted max 3 lines; a 20 px
  Amber spinner on the right while this candidate is applying.
- Initial query = route query; search runs on open.
- Year split: regex `^(.*?)\s*\(?((?:19|20)\d{2})\)?$` on the trimmed query; if title part non-blank →
  (title, year) else (query, null). TMDB `search/movie?query=&year=&include_adult=false` or
  `search/tv?query=&first_air_date_year=&include_adult=false`; all results of page 1 in TMDB order.
- Apply (movie): ensure movie metadata; set every file kind=MOVIE, movieId, clear show/season/episode,
  matchState=MANUAL. Apply (TV): for each file keep its season/episode, else parse from name/path, else 1/1;
  kind=EPISODE, showId, MANUAL; ensure show metadata for those seasons. Then prune catalog. On success go
  back. MANUAL is never overwritten by rescans; IGNORED survives rescans.

---

## 10. Onboarding (`ui/onboarding/OnboardingScreen.kt`)

Shown until `onboardingComplete`. Steps: **Welcome → Accounts → Folders → Tmdb → Scan**. Back works on
steps 2–4 (not Welcome, not Scan).

Container: fills window, content column centered, **max width 1200 on Expanded** (640 otherwise),
padding 48 h (24) × 12 v. Step transitions: forward = slide in from +1/3 width + fade (420/360 ms), out to
−1/4 + fade (320/220 ms); backward mirrored.

**TopProgress** (all steps except Welcome): optional 38 px Back icon button + 14 gap; 4 bars (weight 1
each, spacing 6, height 4, corner 2, track Outline, fill Amber animated 600 ms; bar i filled when
i < step index); 14 gap; `"{i} of 4"` labelMedium TextMuted. Then 12 gap.

**StepLayout (Expanded)**: Row (vertically centered): illustration box (weight 1, end padding 56, centered,
scaled by `wideScale`, entrance 0) | column (weight 1, max width 520): scrollable content (vertically
centered) + bottom button area. Narrow: illustration on top, 20 gap, content, 16 gap, bottom pinned.

**StepHeader(eyebrow, title, body)**: eyebrow uppercased labelSmall Amber (entrance idx); 8 gap; title
displaySmall (idx+1); 10 gap; body bodyLarge TextMuted (idx+2); 24 gap.

### 10.1 Welcome
- Illustration: PosterWallIllustration (Expanded: full width, 1:1 aspect; narrow: height 300).
- Content: Wordmark large (entrance 1); 10 gap; `Your movies and shows,\nas a private cinema.`
  headlineMedium (2); 24 gap; features (row: 44 px tile corner 12 Surface + Outline, Amber icon; 16 gap;
  title titleMedium; body bodyMedium TextMuted; padding 8 v):
  - AutoAwesome `Organized for you` — `Posters, cast and episode guides added automatically.` (3)
  - PlayCircle `Plays everything` — `MKV, MP4 and more, with any audio track or subtitle.` (4)
  - Devices `Picks up where you left off` — `Continue Watching and Next Up remember your place.` (5)
- Bottom: Primary full-width `Get started` (ArrowForward) (7); `Free and open source · Your files stay in your Drive and on your device`
  bodySmall TextFaint centered, top 12 (8). Debug builds only: link `Explore a demo library (debug build)` /
  `Loading demo library… {p}%` (labelLarge Amber).

### 10.2 Accounts (Step 1)
- Illustration: ConnectIllustration (max width 520).
- Header: `Step 1 · Connect`, `Where are your videos?`,
  `Connect the Google Drive that holds them, use folders on this device (phone storage, SD card or USB), a network server (SMB) at home, or all of them. You can change this any time.`
- Connected accounts list: Panel (bottom 10): avatar 40, 12 gap, displayName titleMedium, subtitle
  bodySmall TextMuted, CheckCircle Amber "Connected".
- Buttons (full width, spacing 10): `Connect Google account` (Primary when no accounts) / `Add another Google account`
  (Secondary) with PersonAdd and loading state; `Use files on this device` (Secondary, PhoneAndroid; only if
  no device account); `Add network server` (Secondary, Dns) → AddServerDialog.
- ErrorCard on connect failure (Danger @ 45% border, corner 16, padding 16; title titleMedium, message
  bodyMedium TextMuted; for setup problems an expandable `Setup details for this build` with package name
  and SHA-1 copy fields — Android-specific; on Windows show OAuth client guidance instead).
- Privacy note (corner 14, Surface, padding 14): Lock 20 AmberSoft + `Private by design. Veltoret talks to Google and your network servers directly from this device and only sees the folders you pick — no servers of ours, no tracking. You can disconnect at any time in Settings.`
- Bottom: `Continue` (enabled when ≥ 1 account).

### 10.3 Folders (Step 2)
- Illustration: FoldersIllustration (wideScale 1.3).
- Header: `Step 2 · Library`, `Choose your folders`,
  `Tell Veltoret where your movies and TV shows live. You can add several folders of each kind.`
- Per account (label = display name for device/SMB, else email; shown only when > 1 account): folder
  Panels (Movie/LiveTv icon Amber, name titleSmall, accent pill `Movies`/`TV Shows`, Close "Remove"), then a
  button: `Add another folder` if it has folders; else device: `Choose a folder on this device` (multi
  account) / `Choose a folder`; SMB multi: `Choose a folder on {name}`; Drive multi: `Choose a Drive folder`;
  else `Choose a folder`. Primary when no folders at all, else Secondary.
  Drive/SMB → folder picker titled `Choose a folder` with actions `Movies` / `TV Shows`. Device → system
  folder picker then a library-type dialog (dismiss `Cancel`).
- Tip Panel: `Works best like this` titleSmall; monospace AmberSoft block:
  ```
  Movies/
    Inception (2010)/Inception.mkv
  TV Shows/
    Breaking Bad/
      Season 1/S01E01.mkv
  ```
  then `Messy names are fine too — anything Veltoret can't recognise can be fixed later in a couple of taps.`
- Bottom: `Continue` (enabled when ≥ 1 folder).

### 10.4 TMDB (Step 3)
- Illustration: MetadataIllustration (max 420, wideScale 1.15).
- With a bundled key (unless "use my own"): header `Step 3 · Artwork`, `Posters & details are ready`,
  `This copy of Veltoret comes with a TMDB key, so posters, cast and episode guides work without any setup.`;
  link (Key icon) `Use my own TMDB key instead`; TmdbAttribution; bottom `Build my library`.
- Own key: header `Step 3 · Artwork`, `Add posters & details`,
  `Veltoret uses The Movie Database (TMDB) for posters, cast and episode guides. A free key takes about a minute.`
  Numbered lines (26 px AmberDim circle, number labelMedium AmberSoft, 12 gap, bodyMedium):
  1 `Create a free account at themoviedb.org`; 2 `Open Settings → API and request a key (choose “Personal”)`;
  3 `Copy the API Key or the Read Access Token and paste it below`. Link `Open TMDB API settings` (OpenInNew)
  → https://www.themoviedb.org/settings/api. Password field `API key or Read Access Token` (Key icon,
  Visibility toggle "Show key"). Status line: Valid → CheckCircle Success `Key verified — you're all set`;
  Invalid → ErrorOutline Danger + message (`TMDB didn't accept this key. Copy it again from your TMDB account.`
  on 401, else error message or `Couldn't reach TMDB. Check your connection.`). TmdbAttribution.
  Bottom: `Verify key` (enabled when non-blank, loading while checking) → after valid, `Build my library`.
  Key starting with `eyJ` = v4 bearer token (Authorization header); otherwise `api_key` query param.
  Validation = GET `configuration`. Editing the key resets status.
- `Build my library` starts the first full scan (app-scoped) + periodic sync, then goes to Scan.

### 10.5 Scan (Step 4)
- Illustration: ScanIllustration(finished) (max 560). No back button.
- finished = scan not running and lastFinishedAt > 0.
- Header: `Step 4 · Library`; title `Your library is ready` / `Building your library`; body:
  `Finished with a problem: {error}` / `Everything is organized. Enjoy the show.` /
  `This only takes a while the first time. You can start browsing whenever you like.`
- Two StatTiles (spacing 12; corner 16, Surface, Outline, padding 16; value headlineMedium, label bodySmall
  TextMuted): `Videos found` = filesFound; `Matched` = `"{matched} / {toMatch}"` or matched. Numbers
  animate (600 ms).
- While running: 18 gap; `Matching titles with TMDB…` (phase starts with "Matching") or `Reading your Drive…`;
  8 gap; VProgress height 4 = matched/toMatch (or 0.05).
- Bottom: `Start watching` (Primary, PlayCircle) when finished, else `Continue in background` (Secondary).
  Either marks onboarding complete.

### 10.6 Illustrations (`Illustrations.kt`, all flat vector drawings, no gradients; re-create in WPF Canvas/XAML)
- Poster art palette (bg / mid / dark / light, style): `#1F3B3A/#2E5552/#142726/Amber s0`,
  `#3A2238/#55304F/#241522/Cream s1`, `#1E2A44/#2C3D61/#131B2C/AmberSoft s2`,
  `#4A2A1C/#6B3D28/#2E1A11/Cream s3`, `#2A2D35/#3B3F4A/#1A1C21/Amber s4`,
  `#33361F/#4A4F2D/#202213/AmberSoft s1`, `#2B1F3D/#3F2E58/#1B1327/Amber s0`,
  `#173238/#214751/#0F2125/Cream s2`, `#402024/#5E2F35/#281416/AmberSoft s4`; Cream = `#F3E6CF`.
  Styles: 0 sun over mountains, 1 big moon + horizon, 2 night skyline, 3 overlapping discs, 4 figure before
  sun; each with two cream "title lines" near the bottom.
- PosterWall: corner 28 Surface frame + Outline; 4 columns of 2:3 tiles (gap 10) drifting vertically in
  alternating directions (26 s loop), 35% Background dim, centered 76 px Amber play disc (PlayArrow 42
  OnAmber) with a pulsing 84 px Amber ring (scale 1→1.7, alpha 0.6→0, 2.2 s).
- Connect: phone (76×132, SurfaceHigh, 2×2 mini posters) ⇄ cloud (circles, Drive-like triangle in
  Amber/AmberSoft/Cream) with a dashed animated line (Amber when active) and travelling dots; center badge
  46 px: Lock (not connected) / Check on Amber (connected) with springy scale. Height 210.
- Folders: two folder drawings (back `#6B4D22`, Amber front with Movie/LiveTv icon) labelled `Movies` and
  `TV Shows`, posters bobbing out (3 s). Height 200.
- Metadata: fanned three posters swaying (2.6 s), rating chip `★ 8.6`, rotating Amber key disc. Height 210.
- Scan: Surface frame corner 24 with 4×2 poster slots revealing one by one (4.8 s cycle) and an Amber 2 px
  scan line sweeping (1.8 s) until finished.

---

## 11. Demo library (debug only, `data/demo/DemoLibrary.kt`)

Account `demo@veltoret.local` ("Demo Library") with folders "Demo Movies" / "Demo TV Shows".
Movies (TMDB id → height): 693134, 157336, 155, 872585, 335984, 438631 (2160); 27205, 603, 680, 496243,
129, 324857 (1080). Shows: 1396 (seasons 1–2), 66732, 100088, 94997, 1399 (season 1); first 8 episodes per
season. Fake file names (`Title.2160p.HDR.HEVC.Atmos.mkv` or `Title.1080p.x264.DTS.mkv`; `S01E01.1080p.mkv`),
addedAt staggered by 1 h (movies) / 2 h (shows). Seeded watch states make Continue Watching (157336, 27205,
1396 S1E4), Next Up (66732, 100088) and a watched movie (155) appear. Useful as Windows dev seed data.

---

## 12. Porting notes / gotchas

- Keep **dialogs outside scrolling containers** (Android bug: a dialog inside a lazy item vanished when
  scrolled away). In WPF use overlay/popup at window level.
- Entrance animation must play once, not on every virtualized re-realization.
- Placeholder pulse/animations should run on the render thread (Storyboard on Opacity), not by re-binding.
- Poster lists use stable keys: posters `"m{id}"`/`"s{id}"`, wide cards by fileId.
- All counts use proper singular/plural as written above.
- Dates: US formats (`MMM d, yyyy`, `EEE, MMM d`, `h:mm a`) regardless of locale.
- "Tap" strings in Home panels can become "Click" on Windows; everything else can be kept verbatim.
- Detail pages auto-close if their title disappears (re-match); Collection closes if no owned movies.
