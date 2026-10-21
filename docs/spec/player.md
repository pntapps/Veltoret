# Player: porting spec (Android → Windows)

Source of truth: Veltoret Android `app/src/main/java/com/pntapps/veltoret/player/` (`PlayerActivity`, `PlayerScreen`,
`PlayerViewModel`, `PlayerPrefs`, `PlayerLoading`, `MediaFormats`, `SubtitleEngine`, `DriveMedia`, `SmbDataSource`,
`BufferedDataSource`, `LinkDataSource`), plus `ui/util/Format.kt`, `data/library/WatchRepository.kt`,
`data/library/LibraryRepository.kt` (next/previous episode), `data/settings/SettingsRepository.kt` (defaults).

Target: C# .NET 10, WPF, LibVLCSharp. Strings in quotes are the exact UI text; keep them (US English only).
`×` is U+00D7, `−` is U+2212 (minus sign, not hyphen), `…` is U+2026, `·` is U+00B7. Keep these characters.

Labels used below:
- **[Android-only]**: no Windows equivalent; drop or replace as described.
- **[Proposed]**: not in the Android app; a suggested desktop mapping.

---

## 1. Opening a video

### 1.1 Arguments
`PlayerArgs(fileId, accountEmail?, title?, fromStart: bool, link?)`. `link` is the "Play on TV" handoff (out of scope for
Windows; ignore). Opening a new video while one is open (next/previous/episode list/new request) first calls
`SaveProgress()` for the current one, cancels any in-flight load, then loads the new one in the **same** player window.

### 1.2 Load sequence (`PlayerViewModel.load`)
1. Look up the library file by id. **Offline**: if the file is on Drive (or another remote source) and a device copy of the
   same movie/episode exists (`LibraryRepository.deviceCopy`: same `movieId`, or same `showId+season+episode` with
   `accountEmail == "device"`, best `height` first), play the device copy instead.
2. `fileId` = entity id (or requested id), `email` = entity account ?? hint. Load per-video track memory (§8).
3. If no account: show error **"This file isn't linked to a Google account"** and stop.
4. Title / subtitle shown in the top bar:
   - Default title: `titleHint ?? file name ?? "Video"`, subtitle null.
   - Movie (`movieId` set): title = movie title; subtitle = `[year, runtime]` joined with `" · "`, e.g. `"2019 · 2h 46m"`
     (runtime via `Format.runtime`: `"2h 46m"`, `"48m"`, `"2h"`; omitted if null/≤0).
   - Episode (`showId` set): title = show name; subtitle = `[episodeCode, episodeName]` joined with `"  ·  "` (two spaces
     each side), e.g. `"S1 · E2  ·  Pilot"`. `Format.episodeCode`: season 0 → `"Special {e}"`, else `"S{s} · E{e}"`,
     empty when unknown (empty part dropped).
5. Compute `next` / `previous` episode (§6.1) and `nextLabel` = `[episodeCode, episodeName]` joined `"  ·  "`.
6. Resume position (§4.1).
7. `loadingFrom` (for the loading hint, §11): stream from phone → `"your phone"`; device file → null; SMB →
   share root name (e.g. `"MyNAS"`); otherwise `"Google Drive"`.
8. Apply language preferences (§8.3), set media at `resumeAt`, prepare, **auto-play** (unless casting).
9. Load sidecar subtitle files (§9.2).

State reset per video: error, finished, external subtitle list, selected external, subtitle offset (restored from
memory), auto-play-cancelled, intro-skipped, dropped-frame counter, software-fallback-tried flag.

### 1.3 Media URIs / data sources
| Source | Android | Windows (LibVLC) |
|---|---|---|
| Device file | SAF `content://` URI | Plain file path → `new Media(libVLC, path, FromType.FromPath)` |
| SMB share | id `smb://host/share/path`, read by `SmbDataSource` (smbj) at the requested offset | Prefer the UNC path `\\host\share\path` (Windows SMB client, credentials via the OS) or a custom `MediaInput` over your SMB library. libVLC's own `smb://` module also works but handles credentials poorly. |
| Google Drive | `veltoret-drive://media/<id>?account=<email>` rewritten on **every open** to `https://www.googleapis.com/drive/v3/files/<id>?alt=media&supportsAllDrives=true` with header `Authorization: Bearer <fresh token>` | libVLC can't add arbitrary headers. Use a custom `MediaInput` (LibVLCSharp `StreamMediaInput` or subclass `MediaInput`) backed by `HttpClient` + `Range` requests, getting a fresh token for each (re)open so seeks keep working after the token expires; **or** a loopback HTTP proxy (`http://127.0.0.1:<port>/<token>/<id>`) that adds the header. |

- `BufferedDataSource` (256 KB read-ahead for tiny reads) exists only because Android FUSE system calls are slow
  **[Android-only]**. A custom `MediaInput` should still read in large chunks (≥256 KB) to avoid one HTTP/SMB round-trip
  per small read.
- `VeltoretMatroskaExtractor` (late Info/Tracks after the first Cluster, SeekHead past EOF) **[Android-only]**: libVLC's
  MKV demuxer handles these files; test with an MKV whose Tracks are at the end and an incomplete download.
- FFmpeg audio extension + MediaCodec selection **[Android-only]**: libVLC decodes DTS/TrueHD/AC3/E-AC3/FLAC/ALAC/HEVC
  10-bit etc. natively.
- Buffering on Android: min 30 s, max 90 s, 1.5 s to start, 3 s after rebuffer; network loads retried 8 times. On
  libVLC use `:network-caching=` (e.g. 3000 ms for Drive/SMB) and `:file-caching=` (e.g. 1000 ms), and retry on read
  failure in the `MediaInput`.
- Media metadata (title/subtitle) is also published to the system media session (Android `MediaSession`). Windows:
  publish via `SystemMediaTransportControls` so hardware media keys and the Windows media overlay work **[Proposed]**.
- Keep the display awake while the player is open (`FLAG_KEEP_SCREEN_ON`). Windows: `SetThreadExecutionState(ES_CONTINUOUS
  | ES_DISPLAY_REQUIRED)` while playing, cleared on pause/close.
- "Audio becoming noisy" (pause when headphones unplug) **[Android-only]**; optional on Windows.

---

## 2. Screen layout and controls

Black background, video full window. Controls overlay = full-window scrim `PlayerChrome` (`#8C000000`), fade in 180 ms /
out 220 ms. Accent `Amber #E8A33D`, on-accent `#1B1206`, text `#F3EFE6`, muted `#9C9AA3`, faint `#6B6973`,
surface `#15151A`, surface-high `#1E1E25`, surface-highest `#26262F`, outline `#2C2C35`, outline-strong `#3B3B46`,
amber-dim `#3A2B14`, amber-soft `#F3C77F`, danger `#FF6B5E`. No gradients.
"Narrow" = window width < 600 dp (use DIPs on Windows).

### 2.1 Top bar (left → right)
| Control | Tooltip / label | Shown | Action |
|---|---|---|---|
| ← | "Back" | always | Close player |
| Title + subtitle | — | always (subtitle if not blank) | Single line each, ellipsis |
| Cast | — | always | Chromecast **[Android-only]**; omit |
| Episodes icon | "Episodes" | episode only | Opens Episodes panel (§6.3) |
| PiP icon | "Picture in picture" | not narrow | Enter mini player (§13) |
| Lock-open icon | "Lock controls" | always | Lock (§2.6); controls stay visible |
| ⋮ | "More" | always | Opens More panel (§2.5) |

Round "chrome" buttons: 44 dp, white 10% fill, icon 52% of size.

### 2.2 Centre transport (left → right)
| Control | Label | Notes |
|---|---|---|
| Previous episode | "Previous episode" | Only if `previous != null`; else an empty spacer of the same size **if** next exists (keeps play centred). 44 dp narrow / 50 dp. |
| Back N s | "Back {seekSeconds}s" | `SeekBy(−seekSeconds·1000)`. 50 / 58 dp. |
| Play/Pause | "Pause" / "Play" | Amber circle 68 / 78 dp. See §3.1. |
| Forward N s | "Forward {seekSeconds}s" | `SeekBy(+seekSeconds·1000)`. |
| Next episode | "Next episode" | Only if `next != null`; else spacer if previous exists. |

Spacing 18 dp narrow / 32 dp wide.

### 2.3 Bottom: timeline (§3.4) then a tool row
Left part scrolls horizontally if crowded; "Next episode" is pinned far right.
| Chip | Label | Action |
|---|---|---|
| Audio | "Audio" | Audio panel (§7.2) |
| Subtitles | "Subtitles" | Subtitles panel (§9.1) |
| Speed | `"Speed"` at 1×, else e.g. `"1.5×"` / `"2×"` | Speed panel (§3.5) |
| Aspect | `"Fit"` / `"Fill"` / `"Stretch"`, or `"Zoom"` when zoom > 1 | Cycle Fit → Fill → Stretch → Fit; persist (§3.6); reset zoom and pan to 1× / 0 |
| Rotate | "Rotate" | **[Android-only]** omit (or replace with Fullscreen toggle **[Proposed]**) |
| Skip | `"+{skipSeconds}s"` (default `"+85s"`) | Episodes only. Same as Skip intro (§5.2), at any position |
| Next episode (accent, pinned right) | "Next episode" | Only if next exists → play next |

Chips: 40 dp high, radius 12, 18 dp icon, white 10% fill, accent = amber fill with on-amber text.

### 2.4 Visibility rules
- Click/tap on the video toggles controls (Android: single tap). Every interaction bumps an "interaction" counter that
  restarts the hide timer.
- **Auto-hide after 4 000 ms** when controls are visible **and** the video is playing **and** no panel is open **and** not
  scrubbing.
- Windows **[Proposed]**: mouse movement over the window shows controls (and the cursor); hide the cursor with the
  controls while playing.

### 2.5 More panel ("More")
Panels are bottom sheets on Android; on Windows use a right-side flyout or bottom popup. Rows (icon, label, detail):
- "Sleep timer" — detail = sleep label (§5.3) → opens Sleep panel.
- "Video info & decoder" — detail `"Software decoding"` or `"Hardware decoding"` → opens Video info (§10).
- "Picture in picture" → closes panel, enters mini player.
- "Rotate screen" **[Android-only]**, omit.

Closing any panel (click outside / Esc) clears the subtitle error text and counts as an interaction.

### 2.6 Lock
- "Lock controls" sets `locked = true` and keeps controls visible. While locked the main controls are hidden; only an
  **"Unlock"** button (lock icon, left-centre, 32 dp from left edge) appears, toggled by clicking the video, and it uses
  the same auto-hide rule.
- While locked: double-tap seek, centre double-tap, hold-for-2×, swipes and pinch are all disabled; Back does **not** exit
  (Back still closes an open panel); Skip intro and Up next prompts are hidden.
- On Windows, while locked, ignore keyboard shortcuts except the one that unlocks **[Proposed]** (Android had no lock
  interaction with the hardware keyboard: keys still worked).

### 2.7 Back
Back (Android back; Windows Esc **[Proposed]**): if a panel is open → close it; else if not locked → close player.
When `finished` becomes true (end with nothing to auto-play) the player closes itself.

---

## 3. Playback controls

### 3.1 Play/pause rule (important)
- The button reflects **`playWhenReady`** ("will play when it can"), **not** `isPlaying`. `isPlaying` is false while
  loading, which showed ▶ on a video that was about to start.
  - libVLC mapping: keep your own `bool playWhenReady` that you set on Play()/Pause(); don't derive it from
    `MediaPlayer.IsPlaying` or the `Buffering` state.
- Icon: ended → Replay (↻); `playWhenReady` → Pause; else Play. Accessible name `"Pause"` if playWhenReady else `"Play"`.
- **While buffering** the button shows a spinner instead of the icon (accessible name `"Loading, tap to pause"` if
  playWhenReady else `"Loading"`). Clicking still works: it pauses (the video won't start when ready).
- Click: if state is Ended → seek to 0 first; then `if (playWhenReady) Pause() else Play()`.
- When controls are hidden (or locked) and loading, a standalone amber spinner (52 dp, stroke 3) shows at centre.
- Note: keyboard Space/K, the centre double-tap and PiP play/pause use `isPlaying` instead. On Windows use the
  playWhenReady rule everywhere for consistency **[Proposed]**.

### 3.2 Seek primitives
- `SeekBy(deltaMs)`: `target = max(0, pos + delta)`; if duration > 0, `target = min(target, duration − 500)`.
- `SkipForward(seconds)` (Skip intro): `target = pos + seconds·1000`; if duration > 0, `min(target, duration − 1000)`.
- `seekSeconds` setting: default **10** (Settings). Used by the centre buttons and double-tap. Keyboard and PiP seek are
  a fixed **10 000 ms** on Android regardless of the setting.

### 3.3 Double-tap seek, accumulation → mouse/keyboard
Android: double-tap in left third → back, right third → forward, middle third → toggle play/pause (by `isPlaying`).
- Each double-tap seeks **one** `seekSeconds` step immediately (`SeekBy(±step·1000)`).
- Feedback "ripple": a half-pill on that side (30% width, 80% height, white 10%) with ⏪/⏩ and text
  **"{total} seconds"**. `total` accumulates: if the previous feedback was the same direction and less than **1 200 ms**
  ago, `total = previous.total + step`, else `total = step`. Ripple disappears **900 ms** after the last tap.
- Windows mapping **[Proposed]**:
  - Double-click left third / right third of the video = same as Android (with accumulation).
  - Double-click middle third = toggle fullscreen (desktop convention) — or keep Android's play/pause; pick one and be
    consistent. Single click in the middle = toggle controls (Android) or play/pause (desktop convention).
  - ← / → (and J / L) = seek with the same ripple + accumulation (same 1 200 ms window).

### 3.4 Timeline
- Above the bar, right-aligned: **"Ends at {time}"** (only when duration > 0), muted label. See §5.1.
- Row: current time (monospace) | seek bar | remaining time as **"−{clock}"** or **"--:--"** when duration unknown.
  The left time shows the scrub position while scrubbing.
- `Format.clock(ms)`: `h:mm:ss` if ≥ 1 h else `m:ss` (e.g. `"4:05"`, `"1:02:09"`), negative clamps to 0.
- Seek bar: 36 dp touch height; track 4 dp (6 dp while dragging), radius 3; background white 18%, buffered white 32%,
  played amber; amber thumb 16 dp (22 dp while dragging).
- Click → seek to that fraction immediately. Drag → live preview (scrub fraction) and seek **on release** (also on cancel).
  While scrubbing the controls never auto-hide.
- Clock refresh every **100 ms** (position, duration, buffered). libVLC: `MediaPlayer.Time`, `Length`; buffered isn't
  exposed for all inputs — use the `Buffering` event percentage or omit the buffered layer.

### 3.5 Speed
- Panel title **"Playback speed"**, note **"Tip: press and hold the video for 2× speed."**
- Options: `0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3`; label `"Normal"` for 1, else `"{trim}×"` where trim prints an
  integer without decimals (`"2×"`, `"0.25×"`, `"1.5×"`). Check mark on current. Selecting closes the panel.
- libVLC: `MediaPlayer.SetRate(float)`. Speed is not persisted between videos on Android (it carries only across a
  software-decoding rebuild).

### 3.6 Hold for 2×
- Long-press (only when **playing** and not locked) → speed 2×; a pill at top-centre **"2× speed"** (⏩) with fade+scale.
- On release: restore the speed captured at press-down; if that was 2×, restore **1×**.
- Windows **[Proposed]**: hold left mouse button on the video ≥ ~450 ms; release restores. Optionally hold a key
  (e.g. hold `L`/`→` > 500 ms) — not in Android.

### 3.7 Aspect: Fit / Fill / Stretch, zoom, pan
- Fit = letterbox (`ContentScale.Fit`); Fill = crop to fill (`Crop`); Stretch = distort to fill (`FillBounds`).
  libVLC: Fit → `AspectRatio = null; Scale = 0`; Fill → set `CropGeometry` to the window's aspect (e.g. `"16:9"` computed
  as `"{w}:{h}"`); Stretch → `AspectRatio = "{windowW}:{windowH}"`. Recompute Fill/Stretch on window resize.
- Persisted globally as `resize` = `"Fit" | "Fill" | "Stretch"` (default Fit).
- Pinch zoom (two fingers): scale clamped **1×–5×**, pan clamped to `±(zoom−1)·size/2` per axis. HUD **"Zoom {z:F1}×"**
  (e.g. `"Zoom 1.5×"`). On gesture end, if zoom < 1.05 → snap to 1× and pan 0. Changing the aspect mode resets zoom.
  Windows **[Proposed]**: Ctrl+mouse wheel = zoom (around cursor), drag with zoom > 1 = pan, touch pinch via WPF
  manipulation events. Implement as a `ScaleTransform`/`TranslateTransform` on the video host (or libVLC `Scale` +
  crop; a WPF transform is simpler but needs the VideoView in a WPF-composited surface; with the airspace-based
  `VideoView`, use libVLC `CropGeometry` to emulate zoom).

### 3.8 Swipe gestures (touch)
Windows: implemented for touchscreens (`PlayerWindow.Touch.cs`): tap, double-tap seek (further taps on that side keep
adding), middle double-tap = full screen, hold = 2×, horizontal swipe seek, right-half volume swipe, pinch zoom 1×–5× with
two-finger pan, mini player drag. Brightness is dropped.

One finger, decided after touch-slop: horizontal → seek scrub; vertical on left half → brightness; vertical on right
half → volume. Touches starting within 28 dp of the left/right edge or 56 dp of top/bottom are ignored (system gestures).
- **Seek scrub**: full width = **180 000 ms**; target clamped 0..duration; HUD `"{+|−}{clock(|delta|)}  ·  {clock(target)}"`
  (two spaces around the dot), ⏩/⏪ icon; seek on release. Windows: optional for touchscreens; mouse users have the bar.
- **Brightness [Android-only]**: drop (no reliable per-window brightness on Windows).
- **Volume (with boost)**: value 0–2 where 0–1 = system volume and 1–2 = loudness boost (up to +10 dB). Drag of 70% of
  the height = full range. HUD **"Volume {n}%"**, plus **" · Boost"** when > 100%. Windows: map to libVLC
  `MediaPlayer.Volume` **0–200** (libVLC amplifies above 100), not the system volume. Mouse wheel / ↑ ↓ = ±5 **[Proposed]**,
  same HUD text. Boost isn't persisted.
- HUD pill: top-centre 48 dp from top, chrome background, amber icon, auto-hides **1 000 ms** after the last update.

---

## 4. Resume and progress

### 4.1 Resume position
- `fromStart = true` → 0.
- Else look up the watch state by key (§4.3): resume at `positionMs` if **not watched** and `positionMs > 10 000`; else 0.
- From the in-player Episodes list: `fromStart = item.watched` (a watched episode starts over; an unwatched one resumes).
- Next / Previous: `fromStart = false` (resume if partially watched).

### 4.2 Resume prompt
- If resumed (> 0): bottom-left card **"Resumed at {clock}"** + chip **"Start over"** (↻). 24 dp from left; 132 dp from
  bottom when controls are visible, else 28 dp. Fades in/out.
- Auto-dismiss after **7 000 ms**. "Start over" → seek 0 and dismiss.
- Hidden on casting (n/a).

### 4.3 Saving progress
`SaveProgress()` is called:
- every **10 000 ms** while playing,
- whenever playback stops being "playing" (pause, buffering stall, end),
- when another video is opened in the player,
- when the window is hidden/stopped (Android `onStop`) and when the player closes.

It skips if duration is unknown (falls back to the file's stored `durationMs`; skip if none). Writes asynchronously
(fire-and-forget on an app-wide scope so closing the window doesn't cancel it).

On **end of stream**: save `position = duration` (→ marks watched).

`WatchRepository.savePosition(file, fileId, positionMs, durationMs)`:
- Key: movie → `"movie:{movieId}"`; episode → `"ep:{showId}:{season}:{episode}"`; else `"file:{fileId}"`.
- **Watched rule**: `finished = position ≥ duration × 0.92 || duration − position < 120 000`.
- Stored `positionMs = finished ? 0 : position`; `watched = finished || (previouslyWatched && position < 60 000)`
  (re-watching a watched title keeps the tick during the first minute); `lastWatchedAt = now`; `lastFileId`; ids.
- Multi-episode file (`episodeEnd` set, e.g. S01E01E02): when finished, also mark episodes `episode+1..episodeEnd` watched.

---

## 5. Clocks, timers, intro

### 5.1 "Ends at"
`endsAt = now + (duration − shownPosition) / speed`, formatted as the OS short time (Android `DateFormat.SHORT`;
Windows `DateTime.ToString("t", CurrentCulture)`). Uses the scrub position while scrubbing; recomputed every refresh.

### 5.2 Skip intro
- Prompt chip **"Skip intro"** (accent, ⏩), bottom-right, 28 dp margin. Shown only when: episode **and** not yet skipped
  for this video **and** controls hidden **and** not locked **and** `5 000 ≤ position ≤ 180 000` ms.
- Action: `SkipForward(skipSeconds)` (relative to the current position; setting default **85**), then mark
  `introSkipped = true` (prompt never returns for this video). The `"+85s"` tool chip does the same thing.
- No chapter/intro detection; it's a fixed jump.

### 5.3 Sleep timer
Panel **"Sleep timer"**: `"Off"` (checked when none), `"15 minutes"`, `"30 minutes"`, `"45 minutes"`, `"60 minutes"`,
`"90 minutes"`, `"End of this video"` (checked when active). Selecting closes the panel. Setting any option cancels the
previous timer.
- Minutes: after N minutes → pause; clear timer; notice HUD **"Sleep timer: paused"** (ℹ icon).
- End of this video: at end of stream → clear timer, notice **"Sleep timer: stopped"**, **no auto-play**, the player stays
  open on the last frame (doesn't close). The Up-next card is hidden while this mode is active.
- More-panel detail label: none → `"Off"`; end-of-video → `"At the end of this video"`; countdown →
  `"Stops at {short time}"`.
- The timer is per player session (not persisted); it survives next/previous episode changes within the window.

---

## 6. Episodes

### 6.1 Next / previous file
- Next: files of the same show with season > 0, (offline: device files only), whose `(season, episode)` is after
  `(season, episodeEnd ?? episode)` of the current file; order by season, episode, then same-account-first. Take first.
- Previous: `(season, episode)` of current is after `(s, episodeEnd ?? e)` of the candidate; order season desc, episode
  desc, same-account-first. Specials (season 0) are excluded from both.

### 6.2 Up next / auto-play next
- Card bottom-right (300 dp wide; 132 dp from bottom with controls visible, else 24 dp) shown when: next exists **and**
  duration > 0 **and** `1 ≤ remaining ≤ 30 000` ms **and** not cancelled **and** not locked **and** sleep mode ≠
  end-of-video.
- Content: **"UP NEXT"** (amber small caps), then `nextLabel` (2 lines max), then buttons:
  - auto-play on (setting `autoPlayNext`, default **true**): **"Play in {remaining/1000}s"** (accent, integer seconds,
    counts down with the clock) and **"Cancel"** (⏸). Cancel → `autoPlayCancelled = true` (card hides; video ends
    normally and closes).
  - auto-play off: **"Play now"** only.
- Auto-play triggers at **end of stream** (not when the countdown text hits 0): if next exists && autoPlayNext &&
  !cancelled → open next (resume rules apply); else set `finished` → the player closes.
- Previous / Next transport buttons, the pinned "Next episode" chip, and N / P keys open them immediately.

### 6.3 In-player episode list
Panel **"Episodes"** (spinner while loading). Built from the show's library files with season & episode set,
**distinct by (season, episode)** (first file wins), sorted by season (season 0 / specials **last**), then episode.
Each row:
- Thumbnail 120 dp wide, 16:9, radius 10: TMDB still (`TmdbImages.still(stillPath)`), fallback text `"E{episode}"`.
- Line 1: episode code (`"S1 · E3"` / `"Special 2"`), amber for the current one, else muted.
- Line 2: TMDB episode name, or **"Episode {n}"** when blank (2 lines max).
- Current: amber-dim background, extra line **"Now playing"** (amber-soft), not clickable.
- Watched: amber check-circle icon (accessible name "Watched").
- List initially scrolled to the current episode. Click → play it (`fromStart = watched`), close panel.

---

## 7. Track naming and the audio panel

### 7.1 Naming rules (copy exactly)
`languageName(code)`:
```
if code is null/blank or "und" → null
name = Locale.forLanguageTag(code).getDisplayLanguage(Locale.US)
return (name non-blank && name != code) ? name : code.ToUpperInvariant()
```
C#: try `CultureInfo.GetCultureInfo(code).EnglishName` neutral language part (use the neutral culture's `EnglishName`,
e.g. `"English"`, not `"English (United States)"`). libVLC often reports ISO 639-2 codes (`"eng"`, `"hin"`, `"fre"`/`"fra"`,
`"ger"`/`"deu"`): map 3-letter codes via `CultureInfo.GetCultures(CultureTypes.NeutralCultures)` matching
`ThreeLetterISOLanguageName` (plus a small table for bibliographic codes fre/ger/chi/cze/dut/gre/per/rum/slo/alb/arm/baq/
bur/geo/ice/mac/mao/may/tib/wel). Unknown → uppercase code. Normalize codes the same way before comparing/persisting
languages (§8), so `"eng"` and `"en"` match.

`cleanLabel(label)` — hide release-site names, keep real labels:
```
junkLabel = Regex("""(?i:www\.|https?://|@)|\b[A-Za-z0-9-]{3,}\.[a-z]{2,10}\b""")
cleanLabel(label) = label?.trim() takeIf (not empty && !junkLabel.containsMatchIn(it))
```
.NET: `new Regex(@"(?i:www\.|https?://|@)|\b[A-Za-z0-9-]{3,}\.[a-z]{2,10}\b")` (case-sensitive except the inline group:
the `.tld` part must be **lowercase**). Expected: `"ReleaseSite.at"` → hidden; `"www.x.com"` → hidden; `"SDH"`,
`"Dub.Intl"`, `"DTS-HD.MA"`, `"H.264"` → kept. Port the `MediaFormatsDeviceTest` cases as unit tests.

`trackTitles(formats, fallback, language)` (`fallback` = `"Track"` for audio, `"Subtitle"` for subtitles):
```
base[i] = language(f.language) ?? cleanLabel(f.label) ?? "{fallback} {i+1}"
for names occurring more than once: append " {n}" with n = 1,2,… in list order ("Hindi 1", "Hindi 2")
unique names unchanged
```
Track lists are ordered by type, in container order (the index among tracks of that type is the "ordinal").
libVLC: `MediaPlayer.AudioTrackDescription` / `SpuDescription` give only id+name (and include a "Disable" entry, id −1:
skip it). For language/codec/channels use `Media.Tracks` (`MediaTrack.Language`, `Description`, `Codec`/FourCC,
`Data.Audio.Channels`, `Rate`) matched by track id.

Codec names (`MediaFormats.audioCodec`): AAC→"AAC", AC3→"Dolby Digital", E-AC3→"Dolby Digital+", E-AC3 JOC→
"Dolby Digital+ Atmos", AC-4→"Dolby AC-4", TrueHD→"Dolby TrueHD", DTS→"DTS", DTS-HD→"DTS-HD", DTS Express→"DTS Express",
DTS:X→"DTS:X", Opus→"Opus", FLAC→"FLAC", Vorbis→"Vorbis", MPEG audio→"MP3", ALAC→"ALAC", raw PCM→"PCM", other → MIME
subtype uppercased (Windows: FourCC string uppercased). Map libVLC FourCCs: `mp4a`→AAC, `a52 `→AC3, `eac3`→E-AC3,
`dts `→DTS (check profile for DTS-HD if available), `mlp `/`trhd`→TrueHD, `opus`, `flac`, `vorb`, `mpga`/`mp3 `→MP3,
`alac`, `araw`/`s16l` etc.→PCM.
Video (`videoCodec`): H.264→"H.264", H.265→"HEVC", Dolby Vision→"Dolby Vision", VP8, VP9, AV1, MPEG-4 Part 2→
"MPEG-4 Part 2", MPEG-2→"MPEG-2", VC-1→"VC-1", H.263→"H.263", else uppercased. FourCCs: `h264`, `hevc`, `VP80`, `VP90`,
`av01`, `mp4v`, `mp2v`, `WVC1`, `h263`.
Channels (`channels`): 0/unknown → null; 1 "Mono"; 2 "Stereo"; 6 "5.1"; 8 "7.1"; else `"{n} ch"`.
Subtitle format (`subtitleFormat`): SSA/ASS→"ASS", SubRip→"SRT", WebVTT→"WebVTT", TTML→"TTML", PGS→"PGS",
VobSub→"VobSub", DVB→"DVB", tx3g→"Timed text", else none. FourCCs: `ssa `, `subt`, `wvtt`, `ttml`, `pgss`/`pgs `, `spu `,
`dvbs`, `tx3g`.

### 7.2 Audio panel ("Audio")
- `"No audio tracks"` note when empty.
- Row title = `trackTitles(...)[n]`. Detail joined `" · "`: `cleanLabel(label)` if it differs from the language name;
  codec; channels; `"not supported on this device"` if unsupported (row disabled). Check mark on the selected track.
- Select → apply, remember (§8.2), close panel.

---

## 8. Track memory and language preferences (`PlayerPrefs`)

Storage: Android SharedPreferences file `player`. Windows: a small JSON/settings store with the same keys and meaning.

### 8.1 Keys
| Key | Value |
|---|---|
| `video:{fileId}` | Per-video memory: 8 fields joined with U+001F: `audioIndex`, `audioLanguage`, `subtitleMode`, `subtitleIndex`, `subtitleLanguage`, `externalSource`, `externalName` (U+001F replaced by space), `subtitleOffsetMs`. Empty field = null; offset default 0. (On Windows a JSON object is fine; keep the field set.) |
| `audio:{showId}` | Per-show audio language code. Set only when the language is non-null/non-blank and the video is an episode. |
| `sub:{showId}` | Per-show subtitle language code, or `"off"`. `null` written as `"off"`. |
| `resize` | `"Fit"` / `"Fill"` / `"Stretch"` |

`subtitleMode`: `"off"`, `"embedded"`, `"external"`, or null (never chosen). `externalSource`: `"drive:{fileId}"`,
`"device:{uri}"` (Windows: `"file:{path}"` **[Proposed]**), or `"side:{fileId}"` (sidecar). `audioIndex`/`subtitleIndex` =
ordinal among tracks of that type. Language codes: `"und"` is stored as null.

### 8.2 When memory is written
- Select audio track → `audio:{showId} = language` (if known); memory `audioIndex = ordinal, audioLanguage = language`.
- Select embedded subtitle → `sub:{showId} = language` only if language known; memory `mode=embedded, subtitleIndex,
  subtitleLanguage, externalSource=null, externalName=null`.
- Subtitles Off → `sub:{showId} = "off"`; memory `mode=off`, external cleared.
- Select external subtitle (user action) → `sub:{showId} = language` if the file has one; memory `mode=external,
  externalSource=id, externalName=label, subtitleIndex=null`. Automatic selections (sidecar by language, restoring)
  don't write memory.
- Sync offset change → memory `subtitleOffsetMs`.

### 8.3 Applying at open (order matters)
1. **Initial preferences** before tracks are known (`applyLanguagePreferences`):
   - audio language = `memory.audioLanguage ?? audio:{showId} ?? settings.preferredAudioLanguage` (default `"en"`).
   - subtitle language:
     - memory mode off or external → `"off"` (external is re-attached later);
     - memory mode embedded → `memory.subtitleLanguage ?? "off"`;
     - no memory → `sub:{showId} ?? (settings.preferredSubtitleLanguage, "" → "off")` (default `""` = off).
   - Clear manual overrides, enable text, set preferred audio language and preferred text language (null if off).
   - **"Off" means off**: when off, ignore the file's DEFAULT flag but still show **forced** subtitles.
   - If the chosen subtitle language isn't "off" and there was no per-video memory, remember it as
     `autoSubtitlePending` (§9.2).
2. **Exact restore** once tracks are first known (once per video): audio = track at `audioIndex` among audio tracks if
   its language still equals `audioLanguage` (or language null), else the first audio track with `audioLanguage`.
   Subtitles: off → disable text; embedded → same ordinal/language matching; external → re-read the source and select it
   (label `externalName ?? "Subtitles"`).

libVLC mapping: libVLC has `:audio-language=` / `:sub-language=` media options (comma lists, ISO codes), but the reliable
way is: on `MediaPlayer.ESAdded`/first `Playing`/`Vout` event, pick the tracks yourself with `SetAudioTrack(id)` /
`SetSpu(id)`. Forced subtitles: libVLC 3 doesn't expose the forced flag in `MediaTrack`; when "off", call `SetSpu(-1)`
unless a track whose description/label contains "Forced" (or libVLC 4 `TrackSelected`/forced metadata) is present for
the audio language — document the gap if not achievable. Also libVLC auto-selects a default subtitle track; override it
with `SetSpu(-1)` when the decision is "off".

---

## 9. Subtitles

### 9.1 Subtitles panel ("Subtitles")
Rows in order:
1. **"Off"** — checked when no external is selected and no embedded text track is selected.
2. Embedded tracks: title `trackTitles(...,"Subtitle",...)[n]`; detail joined `" · "`: cleanLabel(label) if ≠ language
   name; `"Forced"` if forced flag; format (§7.1); **"In video"**. Disabled if unsupported. Checked when selected and no
   external selected.
3. External (sidecar/added) files: title = label; detail = `[languageName(language) if ≠ label, "File"]` joined `" · "`.
   Selecting an external does **not** close the panel (so sync can be adjusted); Off/embedded selections close it.
4. **Sync control** (only when an external file is selected) — see §9.4.
5. Spinner while loading a file; error text (danger colour) if any.
6. Actions: **"From the video's folder"** (folder icon) and **"Choose a file…"** (Android: phone icon).

"From the video's folder" → panel **"Subtitles in this folder"**: lists files in the video's parent folder (Drive, device
or SMB) whose extension is a subtitle extension (§9.3); row = name + size (`Format.bytes`). Empty: **"No .srt, .vtt or
.ass files next to this video. Put one next to the video, or use “Choose a file…”."** (curly quotes). Selecting loads,
selects and remembers it; closes on success, shows the error otherwise. Parent folder: the file's stored `parentId`; for
SMB the parent of the path; for Drive fall back to the file's first parent from the API; device files without parentId →
empty list.

"Choose a file…" → system file picker (Android MIME list: srt, vtt, ssa, ttml, text/plain, octet-stream, any). Windows:
`OpenFileDialog` filter `Subtitles|*.srt;*.vtt;*.ass;*.ssa;*.ttml;*.dfxp|All files|*.*`. Default name if unknown
`"subtitle.srt"`. Closes the panel on success.

Errors (exact):
- `"No subtitles found in {name}"` (parsed but zero cues)
- `"Couldn't read {name}"` (exception without message)
- `"That file is too large to be a subtitle"` (> 8 MiB = 8 × 1024 × 1024 bytes)
- `"This subtitle format isn't supported"`
- `"Couldn't open the file"`
- otherwise the exception message.

### 9.2 Sidecar files (automatic)
After the video starts loading:
```
base   = baseName(video.name).ToLower()         // baseName = name without the last ".ext" (whole name if no dot)
for sub in subtitle files in the same folder (library DB index) where sub.name.ToLower().StartsWith(base):
    tail = baseName(sub.name).Substring(base.Length).Trim('.', ' ', '_', '-')
    lang = tail.SubstringBefore('.').ToLower(), only if length is 2..3 and all letters, else null
    parse; add as external id "side:{sub.fileId}", label = languageName(lang) ?? sub.name, language = lang
```
Examples: `Movie.mkv` + `Movie.en.srt` → "English" (en); `Movie.srt` → label "Movie.srt", no language;
`Movie.forced.en.srt` → tail "forced.en" → "forced" → no language, label = file name. Files that fail to parse are
skipped silently. Sidecars are **not** selected automatically, except: if `autoSubtitlePending` (wanted language) is set
and **no embedded text track is selected** once tracks are known, select the first external with that language (without
writing memory). If an embedded track was selected, clear the pending language.
Windows: also scan the folder on disk directly for device files (same matching). Do not hand sidecars to libVLC's own
auto-detection (`--sub-autodetect-file`) in addition, or tracks will appear twice: disable it (`--no-sub-autodetect-file`).

### 9.3 Parsing and encoding (`SubtitleEngine`)
- Format by extension (lowercase): `srt` → SubRip; `vtt` → WebVTT; `ass`, `ssa` → SSA/ASS; `ttml`, `dfxp` → TTML;
  anything else → SubRip. Subtitle extensions for listing: `srt, vtt, ass, ssa, ttml, dfxp`.
- Size limit 8 MiB (checked while reading and before parsing).
- Text normalisation (copy exactly):
  1. Starts with UTF-8 BOM `EF BB BF` → keep bytes.
  2. Starts with UTF-16 BOM `FF FE` or `FE FF` → keep bytes.
  3. Decodes as strict UTF-8 (throw on invalid) → keep.
  4. Else guess a legacy code page and transcode to UTF-8 (invalid bytes replaced):
     ```
     asciiLetters = count of bytes in 0x41..0x5A or 0x61..0x7A
     high        = count of bytes >= 0x80
     cyrillic    = high bytes in {E0, E5, E8, ED, EE, F0, F1, F2}
     arabic      = high bytes in {C7, C8, CA, D1, E1, E3, E4, E6}
     nonLatin    = high > 0 && high / (high + asciiLetters) > 0.3
     !nonLatin          → windows-1252
     arabic > cyrillic  → windows-1256
     else               → windows-1251
     (fallback ISO-8859-1 if unavailable)
     ```
  .NET: register `CodePagesEncodingProvider.Instance` (System.Text.Encoding.CodePages) for 1251/1252/1256; strict UTF-8 =
  `new UTF8Encoding(false, throwOnInvalidBytes: true)`.
- Cues: drop cues with unknown start; sort by start; end = start + duration, or the next cue's start if open-ended,
  or start + 5 s for the last; drop empty cues.
- Active cues at time `t = position − offset`: binary-search the first cue starting after `t`, walk back up to 64 cues and
  include every cue with `t < end` (overlaps shown together, earlier first).

Windows implementation choice:
- **Option A (closest to Android)**: own parser + overlay `TextBlock` for external files (styling §9.5); libVLC renders
  embedded tracks. Needs your own SRT/VTT/ASS/TTML parsing (ASS styling would be lost).
- **Option B (recommended)**: normalise the bytes to UTF-8 (above), write to a temp file with the original extension, add
  via `MediaPlayer.AddSlave(MediaSlaveType.Subtitle, fileUri, select: true)`, and use `MediaPlayer.SetSpuDelay(µs)` for
  sync. libVLC renders ASS with libass (an improvement Android lists as "planned"). Keep the "external" bookkeeping
  (ids, labels, memory) in the app, and still parse once to detect "No subtitles found in {name}".

### 9.4 Sync offset
- Shown only while an external subtitle is selected (Android). Header **"Sync"** + value (amber):
  `0` → **"In sync"**; `> 0` → **"{s:0.0} s later"**; `< 0` → **"{s:0.0} s earlier"** (one decimal, invariant culture,
  absolute value).
- Buttons: **"−1 s"** (−1000), **"−0.1 s"** (−100), **"Reset"** (0), **"+0.1 s"** (+100), **"+1 s"** (+1000).
- Help: **"Use + if subtitles appear before the speech, − if they're late."**
- Positive offset = subtitles shown **later** (`t = position − offset`). libVLC: `SetSpuDelay(offsetMs * 1000)` (positive
  delays subtitles — same sign).
- Persisted per video (`subtitleOffsetMs`) and restored on open.
- Keyboard **[Proposed]**: `G` / `H` = −0.1 s / +0.1 s (VLC convention) with a HUD showing the sync label.

### 9.5 Rendering style
- White text, black outline edge, no window colour; background box `#B3000000` only when the setting
  `subtitleBackground` is on (default off).
- Size = default × `subtitleScale` (setting, default 1.0) × 1.4 in the mini player.
- Bottom padding raised to **20%** of the height while controls are visible (so subtitles sit above the timeline),
  default otherwise (~8%).
- Embedded ASS styles applied. libVLC: `--freetype-outline-thickness`, `--freetype-rel-fontsize`, `--sub-margin`
  (raise/lower while controls show — changes may need a restart of the vout; Option A overlays avoid that).

---

## 10. Video info panel ("Video info")
Group headers uppercase amber: **"FILE"**, **"VIDEO"**, **"AUDIO"**. Rows with a null/blank value are hidden. Key column
120 dp.
- FILE: "Name" = file name; "Size" = `Format.bytes` (e.g. `"1.4 GB"`, `"700 MB"`; ≤ 0 → `"—"`; 1024-based, one decimal
  from GB up, none below); "Container" = extension uppercased.
- VIDEO: "Codec"; "Resolution" = `"{w}×{h} · {label}"` with label: h ≥ 2000 or w ≥ 3800 → "4K"; h ≥ 1400 → "1440p";
  h ≥ 1000 or w ≥ 1900 → "1080p"; h ≥ 700 → "720p"; else "SD"; "Frame rate" = `"%.3g fps"` (e.g. `"23.976 fps"` → `"24.0 fps"`
  per `%.3g`; port with 3 significant digits); "HDR" = "Dolby Vision" / "HDR10" (PQ / ST2084) / "HLG" / default **"SDR"**;
  "Bitrate" = ≥ 1 000 000 → `"%.1f Mbps"`, else `"{bps/1000} kbps"`; "Decoder" = `"{kind} · {decoder name}"`;
  "Dropped frames" = count.
- AUDIO: "Codec"; "Channels"; "Sample rate" = `"{rate/1000.0} kHz"` (e.g. `"48.0 kHz"`); "Language" = language name;
  "Decoder".
- Decoder kind (Android names): contains "ffmpeg" → "Software · FFmpeg"; `c2.goldfish.` → "Emulator"; `c2.android.` /
  `OMX.google.` → "Software · Android"; else "Hardware". Windows: report "Hardware (D3D11VA/DXVA2)" vs "Software" from the
  `--avcodec-hw` setting; libVLC doesn't expose decoder names. Dropped frames: `Media.Statistics.LostPictures`;
  bitrate: `Media.Statistics.InputBitrate` or track bitrate; HDR from `VideoTrack` transfer if available (libVLC 4) else
  omit.
- Toggle row: **"Software video decoding"** / **"Uses Android's built-in software decoders. Try it if the picture is
  green, frozen or glitchy. Uses more battery; 4K may stutter."** with a switch. Windows text **[Proposed]**:
  "Turns off hardware acceleration. Try it if the picture is green, frozen or glitchy. Uses more power; 4K may stutter."

### 10.1 Software decoding switch and automatic fallback
- Toggling rebuilds the player keeping position, play/pause, track selection and speed; clears the error; reloads the media.
  Windows: recreate the `Media` with `:avcodec-hw=none` (software) or `:avcodec-hw=any` (default), seek to the saved time.
- **Automatic fallback**: on a decoder error (init/query/decoding failed, format exceeds capabilities, unsupported), if
  not already software and not tried for this video → switch to software once, resume playing, HUD notice
  **"Switched to software decoding"**. Otherwise show the error card.

---

## 11. Loading hints (`PlayerLoading`)
Loading = buffering state and no error. Stages, restarted each time loading starts, only while `playWhenReady`:
stage 0 at start; stage 1 after **5 000 ms**; stage 2 after **15 000 ms**. Text (pill under the spinner, 150 dp below
centre, surface-high 85%):
- stage ≥ 2 and source known → **"Slow connection, still loading…"**
- stage ≥ 2, device file → **"Still loading…"**
- stage 1, source known → **"Loading from {from}…"** (`"Google Drive"`, the SMB share name, `"your phone"`)
- stage 1, device file → **"Loading…"**
libVLC: treat `Buffering` events with percentage < 100 (and Opening) as loading; `Playing`/`Paused` with buffer 100 ends it.

---

## 12. Errors

Error card (centre, max 440 dp, surface-high, outline, radius 20): title **"Playback stopped"**, message, buttons
**"Close"** (←, closes player), **"Try software"** (only if not already software; switches decoding), **"Retry"**
(accent ▶). Retry: clear error; if no media loaded → reopen the file; else re-prepare and play.

Messages, first match wins (`describe`):
1. Auth required anywhere in the cause chain → **"Your Google account needs to be reconnected in Settings."**
2. SMB exception → its message, or **"Couldn't read this file from the server."**
3. SMB source and offline → **"You're offline. This video is on a network server, so this device needs to be on the same network."**
4. SMB source and an IO error → **"Couldn't read this video from the network server. Check that it's on and that you're on the same Wi-Fi."**
5. Not a device file and offline → **"You're offline. This video is on Google Drive, so it needs an internet connection. Videos on this device still play."**
6. Device file and file-not-found / no-permission / unspecified IO → **"This file isn't available on this device. If it's on an SD card or USB drive, make sure it's connected."** (Windows **[Proposed]**: "…If it's on a USB drive or another disk, make sure it's connected.")
7. HTTP 403 → **"Google Drive refused the stream (403). The file may have hit its daily download limit — try again later."**
8. HTTP 404 → **"This file is no longer in Google Drive."**
9. Network connection failed / timeout → **"Network problem. Check your connection and retry."**
10. Unsupported container → **"This file's container format isn't supported (for example WMV/ASF or RealMedia)."** (libVLC
    plays WMV/RM; keep only as a generic demux failure message.)
11. Decoder errors (after the software fallback):
    - no format → **"This device can't decode this file's format."**
    - HEVC Main10 (`hvc1.2`/`hev1.2`) → **"This video is 10-bit HEVC (H.265 Main 10), and this device has no decoder for it. An 8-bit H.264 or HEVC version of the file will play."**
    - Dolby Vision → **"This video is Dolby Vision, which this device can't decode."**
    - other video → **"This device can't decode {codec} video at {w}×{h}."** (` at …` omitted if width unknown)
    - audio → **"This device can't decode the {codec} audio track. Try another audio track."**
12. Otherwise the error code name humanised (e.g. `"Io bad http status"`). Windows **[Proposed]**: libVLC's
    `EncounteredError` carries no reason; read the last libVLC log line at error level and fall back to
    "Couldn't play this video." Your `MediaInput` should surface HTTP status / auth / SMB failures itself so rules 1–9 work.

Other one-off HUD notices: "Switched to software decoding", "Sleep timer: paused", "Sleep timer: stopped".

---

## 13. Keyboard, mouse, and Android-only features

### 13.1 Android hardware-keyboard shortcuts (port as-is)
| Key | Action |
|---|---|
| Space, K | Toggle play/pause (Android uses `isPlaying`; use the playWhenReady rule on Windows) |
| J, ← | Seek −10 s (`SeekBy(−10000)`) |
| L, → | Seek +10 s |
| M | Mute toggle (player volume 0 ↔ 1; Windows: `MediaPlayer.Mute`) |
| N | Next episode (if any) |
| P | Previous episode (if any) |

### 13.2 D-pad behaviours from the TV player worth mapping **[Proposed for Windows]**
- Enter/OK = toggle play (pausing also shows controls). Media Play/Pause/Play/Pause keys likewise; Media Pause shows controls.
- ← / → **accelerate when held**: step = seekStep × 1 (repeat ≤ 6), × 3 (repeat 7–20), × 6 (repeat > 20), using the
  key's auto-repeat count. Seek hint accumulates while the same direction is pressed within **1 500 ms**:
  `"+{n}s"` / `"−{n}s"` plus `"{clock(pos)} / {clock(dur)}"` and a thin timeline at the bottom; hint disappears after
  1 400 ms.
- Timeline focused: ← / → add to a **pending** jump (shown as target time in amber and `"+m:ss"`), applied **650 ms** after
  the last press or immediately on Enter. Hint: **"← → to scrub · OK to jump"**.
- ↑ / ↓ show the controls (Windows: ↑/↓ = volume ±5 instead, and any mouse move shows controls).
- Media Next = next episode; Media Previous = previous episode, or seek to 0 if none.
- Back/Esc: close panel → hide controls → exit (TV order). On desktop, Esc in fullscreen should leave fullscreen first.
- Controls auto-hide after 5 s on TV (phone: 4 s).
- TV "Start over" button appears when resumed or position > 60 s; TV resume text **"Resumed at {clock} · press ↓ for Start over"**.
- TV picture size labels: **"Picture size · Fit (whole picture)"**, **"Fill screen (zoom)"**, **"Stretch"**.

### 13.3 Suggested complete Windows map **[Proposed]**
Space/K play-pause · ←/J, →/L seek (hold to accelerate) · ↑/↓ or wheel volume ±5 (0–200%, HUD) · M mute · N/P next/prev ·
F, F11 or double-click centre: fullscreen · Esc: close panel / exit fullscreen / close player · `[` `]` speed down/up
through the speed list · `S` Skip intro (episodes) · `A` / `C` cycle audio / subtitle tracks (`V` also cycles subtitles in
VLC) · `G`/`H` subtitle sync ∓0.1 s · `Z` cycle Fit/Fill/Stretch · Ctrl+wheel zoom · `I` video info · Ctrl+L lock ·
`Home` start over · media keys via SMTC.

### 13.4 Android-only, and replacements
| Android feature | Windows |
|---|---|
| Picture-in-picture (aspect clamped 1:2.39–2.39:1, actions: "Back 10 seconds", "Pause"/"Play", "Forward 10 seconds"; auto-enter when leaving the app while playing) | **Mini player**: borderless always-on-top (`Topmost = true`) resizable window locked to the video aspect (clamp 1:2.39–2.39:1), bottom-right of the work area, hover shows ⏪10 / ⏯ / ⏩10 + "expand" + close; no other overlays; subtitles ×1.4. Reuse the same `MediaPlayer` (move the `VideoView`). Optional: enter automatically on minimize while playing. |
| Pausing when the activity stops (unless in PiP) | Pause when the player window closes; keep playing when minimized only if the mini player is used (decide in UX). Always save progress on minimize/close. |
| Brightness swipe | Drop. |
| System volume swipe + LoudnessEnhancer boost (+10 dB = 1000 mB) | libVLC volume 0–200. |
| Rotate button / auto orientation by video shape | Drop; offer Fullscreen. |
| Immersive system bars, display cutout | Fullscreen window (WindowStyle None + Maximized, or true borderless). |
| MediaCodec hardware/software selection, FFmpeg audio extension, constant-bitrate seeking flag, patched MKV extractor, `BufferedDataSource` | libVLC handles codecs/containers; only the hardware-decoding toggle remains (`:avcodec-hw`). |
| `MediaSession` | `SystemMediaTransportControls` (title, subtitle, artwork, play/pause/next/previous). |
| Chromecast (`player/cast`), "Play on TV" link (`LinkArgs`, `vlink://`) | Out of scope; when a remote stream id is ever used, never save progress/track memory for it (Android rule). |

---

## 14. Settings the player reads (defaults)
| Setting | Default | Use |
|---|---|---|
| `seekSeconds` | 10 | Centre buttons, double-tap step, labels "Back 10s"/"Forward 10s" |
| `skipSeconds` | 85 | Skip intro jump, chip "+85s" |
| `autoPlayNext` | true | Up-next card buttons and end-of-video behaviour |
| `preferredAudioLanguage` | "en" | Audio fallback after per-video and per-show memory |
| `preferredSubtitleLanguage` | "" (= off) | Subtitle fallback |
| `subtitleScale` | 1.0 | Subtitle size multiplier |
| `subtitleBackground` | false | Black 70% box behind subtitles |

## 15. Timings summary
| What | Value |
|---|---|
| Controls auto-hide | 4 000 ms (TV 5 000) |
| HUD pill | 1 000 ms |
| Double-tap ripple / accumulation window | 900 ms / 1 200 ms |
| Resume prompt | 7 000 ms |
| Resume threshold | position > 10 000 ms and not watched |
| Progress save while playing | every 10 000 ms (+ on pause, switch, close) |
| Watched | ≥ 92% or < 120 000 ms left; keep watched if re-watching and < 60 000 ms |
| Skip intro window | 5 000–180 000 ms |
| Up next window | last 30 000 ms |
| Loading hint stages | 5 000 / 15 000 ms |
| Swipe seek range | full width = 180 000 ms |
| Zoom | 1×–5×, snap back below 1.05× |
| Clock refresh | 100 ms |
| Sleep options | 15, 30, 45, 60, 90 min, end of video |
| Subtitle max size | 8 MiB |
| Subtitle sync steps | ±100 ms, ±1 000 ms |
| Last cue open end | +5 s |
