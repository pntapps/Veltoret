# Porting spec: Watchlist, reminders, upcoming episodes, settings, voice, app start

Source: Veltoret Android (Kotlin/Compose), commit `e64fe84d`. Target: Veltoret for Windows (C# .NET 10, WPF).

This spec covers:
- `data/plans/*` (Plans, PlansRepository, PlanNotifications + DeepLinks, ReminderReceiver + RescheduleReceiver, UpcomingWorker)
- `ui/details/TitlePlans.kt`
- `data/settings/SettingsRepository.kt`
- `ui/settings/SettingsScreen.kt`, `ScanText.kt`
- `data/library/VoiceQuery.kt`, `ui/navigation/VoiceRequests.kt` / `VoiceActivity.kt` / `OpenRequests.kt`
- `ui/util/*`
- `AppContainer.kt`, `VeltoretApp.kt`, `MainActivity.kt`
- `data/db/VeltoretDatabase.kt` plus the Room schema `app/schemas/.../4.json`
- the unit tests `PlansTest`, `VoiceQueryTest`, `PlayTargetsTest`, `RelatedTitlesTest`, `TrailerPickTest`

Conventions in this document:
- **[SRC]** means the behavior is taken directly from the Android source. Keep it exactly.
- **[WIN]** means a porting decision for Windows. It does not exist in the source.
- Every user-visible string is quoted exactly. `·` is U+00B7 (middle dot); `“ ”` are U+201C/U+201D; `…` is U+2026; `→` is U+2192.

---

## 1. SQLite schema (Room database v4, `veltoret.db`)

[SRC] Room database `VeltoretDatabase`, `version = 4`, `exportSchema = true`. AutoMigrations exist for 1→2 (adds `archive_files`), 2→3 (adds `recommendations`) and 3→4 (adds `watchlist`, `reminders` and the four `shows.nextEpisode*` columns). Identity hash: `37acc5d9deffaee0e7b3819ca38a2a49`.

The schema has **no foreign keys and no views**. Room stores booleans as INTEGER (0/1) and enums as TEXT (the enum name).

[WIN] Create these tables with Microsoft.Data.Sqlite (or EF Core using exactly these names). Keep `PRAGMA user_version = 4` so a later migration path stays the same. The `room_master_table` is Room bookkeeping. Create it only if you want byte-for-byte compatibility with an Android DB copy; Windows never reads it. Never use a destructive migration: CLAUDE.md says users must not lose their library or watch history.

```sql
-- Accounts: a Google account (email), the device pseudo-account "device", or a network server "smb://host".
CREATE TABLE IF NOT EXISTS `accounts` (
  `email`       TEXT    NOT NULL,
  `displayName` TEXT    NOT NULL,
  `photoUrl`    TEXT,                 -- nullable
  `addedAt`     INTEGER NOT NULL,     -- epoch ms
  PRIMARY KEY(`email`)
);

-- Library folders. type = 'MOVIES' | 'SHOWS' (enum LibraryType).
CREATE TABLE IF NOT EXISTS `library_folders` (
  `id`            INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  `accountEmail`  TEXT    NOT NULL,
  `driveFolderId` TEXT    NOT NULL,
  `name`          TEXT    NOT NULL,
  `type`          TEXT    NOT NULL,
  `lastScannedAt` INTEGER NOT NULL     -- epoch ms, 0 = never (entity default 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS `index_library_folders_accountEmail_driveFolderId_type`
  ON `library_folders` (`accountEmail`, `driveFolderId`, `type`);

-- Video files. kind = 'MOVIE' | 'EPISODE'. matchState = 'PENDING'|'MATCHED'|'UNMATCHED'|'MANUAL'|'IGNORED'.
CREATE TABLE IF NOT EXISTS `media_files` (
  `driveId`         TEXT    NOT NULL,  -- Drive id / device URI / smb://host/share/path (global PK)
  `accountEmail`    TEXT    NOT NULL,
  `libraryFolderId` INTEGER NOT NULL,
  `name`            TEXT    NOT NULL,
  `parentId`        TEXT    NOT NULL,
  `relativePath`    TEXT    NOT NULL,  -- folder names between library root and file, joined with "/"
  `sizeBytes`       INTEGER NOT NULL,
  `modifiedTime`    TEXT,              -- nullable
  `mimeType`        TEXT    NOT NULL,
  `durationMs`      INTEGER NOT NULL,
  `width`           INTEGER NOT NULL,
  `height`          INTEGER NOT NULL,
  `kind`            TEXT    NOT NULL,
  `parsedTitle`     TEXT    NOT NULL,
  `parsedYear`      INTEGER,
  `season`          INTEGER,
  `episode`         INTEGER,
  `episodeEnd`      INTEGER,
  `movieId`         INTEGER,           -- TMDB movie id
  `showId`          INTEGER,           -- TMDB tv id
  `matchState`      TEXT    NOT NULL,
  `addedAt`         INTEGER NOT NULL,
  PRIMARY KEY(`driveId`)
);
CREATE INDEX IF NOT EXISTS `index_media_files_movieId`         ON `media_files` (`movieId`);
CREATE INDEX IF NOT EXISTS `index_media_files_showId`          ON `media_files` (`showId`);
CREATE INDEX IF NOT EXISTS `index_media_files_libraryFolderId` ON `media_files` (`libraryFolderId`);
CREATE INDEX IF NOT EXISTS `index_media_files_matchState`      ON `media_files` (`matchState`);

CREATE TABLE IF NOT EXISTS `subtitle_files` (
  `driveId`         TEXT    NOT NULL,
  `accountEmail`    TEXT    NOT NULL,
  `libraryFolderId` INTEGER NOT NULL,
  `parentId`        TEXT    NOT NULL,
  `name`            TEXT    NOT NULL,
  PRIMARY KEY(`driveId`)
);
CREATE INDEX IF NOT EXISTS `index_subtitle_files_parentId` ON `subtitle_files` (`parentId`);

CREATE TABLE IF NOT EXISTS `movies` (
  `tmdbId`         INTEGER NOT NULL,
  `title`          TEXT    NOT NULL,
  `originalTitle`  TEXT,
  `overview`       TEXT    NOT NULL,
  `tagline`        TEXT,
  `releaseDate`    TEXT,               -- "yyyy-MM-dd"
  `year`           INTEGER,
  `runtimeMin`     INTEGER,
  `rating`         REAL    NOT NULL,
  `certification`  TEXT,
  `posterPath`     TEXT,
  `backdropPath`   TEXT,
  `genres`         TEXT    NOT NULL,   -- comma-separated genre names
  `collectionId`   INTEGER,
  `collectionName` TEXT,
  `director`       TEXT,
  `updatedAt`      INTEGER NOT NULL,
  PRIMARY KEY(`tmdbId`)
);

CREATE TABLE IF NOT EXISTS `shows` (
  `tmdbId`             INTEGER NOT NULL,
  `name`               TEXT    NOT NULL,
  `overview`           TEXT    NOT NULL,
  `tagline`            TEXT,
  `firstAirDate`       TEXT,
  `year`               INTEGER,
  `lastAirDate`        TEXT,
  `status`             TEXT,           -- TMDB status, e.g. "Returning Series", "Ended"
  `rating`             REAL    NOT NULL,
  `certification`      TEXT,
  `posterPath`         TEXT,
  `backdropPath`       TEXT,
  `genres`             TEXT    NOT NULL,
  `network`            TEXT,
  `seasonCount`        INTEGER NOT NULL,
  `episodeCount`       INTEGER NOT NULL,
  `episodeRuntimeMin`  INTEGER,
  `creator`            TEXT,
  `updatedAt`          INTEGER NOT NULL,  -- epoch ms of last TMDB refresh (UpcomingWorker uses it)
  `nextEpisodeSeason`  INTEGER,           -- v4; from TMDB next_episode_to_air
  `nextEpisodeNumber`  INTEGER,           -- v4
  `nextEpisodeName`    TEXT,              -- v4; blank stored as NULL
  `nextEpisodeAirDate` TEXT,              -- v4; "yyyy-MM-dd", blank stored as NULL
  PRIMARY KEY(`tmdbId`)
);

CREATE TABLE IF NOT EXISTS `seasons` (
  `showId`       INTEGER NOT NULL,
  `seasonNumber` INTEGER NOT NULL,
  `name`         TEXT    NOT NULL,
  `overview`     TEXT    NOT NULL,
  `posterPath`   TEXT,
  `episodeCount` INTEGER NOT NULL,
  `airDate`      TEXT,
  `fetchedAt`    INTEGER NOT NULL,
  PRIMARY KEY(`showId`, `seasonNumber`)
);

CREATE TABLE IF NOT EXISTS `episodes` (
  `showId`        INTEGER NOT NULL,
  `seasonNumber`  INTEGER NOT NULL,
  `episodeNumber` INTEGER NOT NULL,
  `name`          TEXT    NOT NULL,
  `overview`      TEXT    NOT NULL,
  `stillPath`     TEXT,
  `airDate`       TEXT,
  `runtimeMin`    INTEGER,
  `rating`        REAL    NOT NULL,
  PRIMARY KEY(`showId`, `seasonNumber`, `episodeNumber`)
);

-- mediaType = 'movie' | 'tv'
CREATE TABLE IF NOT EXISTS `credits` (
  `mediaType`   TEXT    NOT NULL,
  `mediaId`     INTEGER NOT NULL,
  `personId`    INTEGER NOT NULL,
  `name`        TEXT    NOT NULL,
  `character`   TEXT,
  `profilePath` TEXT,
  `ord`         INTEGER NOT NULL,
  PRIMARY KEY(`mediaType`, `mediaId`, `personId`)
);

-- Watch progress keyed by WHAT was watched: "movie:<id>", "ep:<showId>:<season>:<episode>", "file:<driveId>".
CREATE TABLE IF NOT EXISTS `watch_state` (
  `key`           TEXT    NOT NULL,
  `positionMs`    INTEGER NOT NULL,
  `durationMs`    INTEGER NOT NULL,
  `watched`       INTEGER NOT NULL,     -- boolean 0/1
  `lastWatchedAt` INTEGER NOT NULL,
  `lastFileId`    TEXT,
  `movieId`       INTEGER,
  `showId`        INTEGER,
  `season`        INTEGER,
  `episode`       INTEGER,
  PRIMARY KEY(`key`)
);
CREATE INDEX IF NOT EXISTS `index_watch_state_showId` ON `watch_state` (`showId`);

CREATE TABLE IF NOT EXISTS `archive_files` (
  `driveId`         TEXT    NOT NULL,
  `accountEmail`    TEXT    NOT NULL,
  `libraryFolderId` INTEGER NOT NULL,
  `parentId`        TEXT    NOT NULL,
  `name`            TEXT    NOT NULL,
  `sizeBytes`       INTEGER NOT NULL,
  `relativePath`    TEXT    NOT NULL,
  PRIMARY KEY(`driveId`)
);
CREATE INDEX IF NOT EXISTS `index_archive_files_libraryFolderId` ON `archive_files` (`libraryFolderId`);

-- TMDB recommendations; recommendedIds = comma-separated TMDB ids of the same type, best first.
CREATE TABLE IF NOT EXISTS `recommendations` (
  `mediaType`      TEXT    NOT NULL,
  `mediaId`        INTEGER NOT NULL,
  `recommendedIds` TEXT    NOT NULL,
  `fetchedAt`      INTEGER NOT NULL,
  PRIMARY KEY(`mediaType`, `mediaId`)
);

-- "Watch later". mediaType = 'movie' | 'tv'.
CREATE TABLE IF NOT EXISTS `watchlist` (
  `mediaType` TEXT    NOT NULL,
  `mediaId`   INTEGER NOT NULL,
  `addedAt`   INTEGER NOT NULL,
  PRIMARY KEY(`mediaType`, `mediaId`)
);

-- "Remind me". season+episode set = one episode; both NULL = whole movie/show. at = epoch ms (UTC instant).
CREATE TABLE IF NOT EXISTS `reminders` (
  `id`        INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  `mediaType` TEXT    NOT NULL,
  `mediaId`   INTEGER NOT NULL,
  `season`    INTEGER,
  `episode`   INTEGER,
  `title`     TEXT    NOT NULL,   -- kept so it still reads well if the title leaves the library
  `at`        INTEGER NOT NULL,
  `createdAt` INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS `index_reminders_mediaType_mediaId` ON `reminders` (`mediaType`, `mediaId`);

-- Room bookkeeping (optional on Windows)
CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES (42, '37acc5d9deffaee0e7b3819ca38a2a49');
```

### 1.1 PlansDao queries [SRC]

| Method | SQL |
|---|---|
| observeWatchlist | `SELECT * FROM watchlist ORDER BY addedAt DESC` (live) |
| watchlist | `SELECT * FROM watchlist` |
| observeInWatchlist / isInWatchlist | `SELECT EXISTS(SELECT 1 FROM watchlist WHERE mediaType = :type AND mediaId = :id)` |
| addToWatchlist | Upsert (INSERT OR REPLACE on PK) |
| removeFromWatchlist | `DELETE FROM watchlist WHERE mediaType = :type AND mediaId = :id` |
| observeReminders / reminders | `SELECT * FROM reminders ORDER BY at` |
| observeRemindersFor | `SELECT * FROM reminders WHERE mediaType = :type AND mediaId = :id ORDER BY at` |
| reminder(id) | `SELECT * FROM reminders WHERE id = :id` |
| insertReminder | INSERT, returns the new rowid |
| deleteReminder(id) | `DELETE FROM reminders WHERE id = :id` and **returns the number of rows deleted** (needed for the fire-once rule) |
| WatchDao.watchedShowIds | `SELECT DISTINCT showId FROM watch_state WHERE showId IS NOT NULL` |

[WIN] The live `Flow` queries need change notification. Use one in-process event per table (for example `PlansChanged`) that repository writes raise. View models re-query when it fires.

---

## 2. Settings

### 2.1 AppSettings keys [SRC]

Android stores these in a Preferences DataStore named `settings`.

| Key (DataStore) | Property | Type | Default | Meaning |
|---|---|---|---|---|
| `onboarding_complete` | onboardingComplete | bool | `false` | First-run setup done. It gates the main shell, the periodic scan, UpcomingWorker and the reconnect rescan. |
| `tmdb_key` | tmdbKeyOverride | string | `""` | The key the user typed (trimmed on save). Empty means use `BUNDLED_TMDB_KEY` (`tmdbKey => override.IsBlank ? Bundled : override`). It can be a v3 API key or a v4 Read Access Token. |
| `oled_black` | oledBlack | bool | `false` | "Pure black" page background. |
| `auto_play_next` | autoPlayNext | bool | `true` | Count down and play the next episode at the end of an episode. |
| `skip_seconds` | skipSeconds | int | `85` | Skip button size. Options: 30, 60, 85, 90, 120. |
| `seek_seconds` | seekSeconds | int | `10` | Double-tap seek. Options: 5, 10, 15, 30. |
| `audio_lang` | preferredAudioLanguage | string | `"en"` | ISO 639-1 code. |
| `sub_lang` | preferredSubtitleLanguage | string | `""` | `""` = subtitles off by default. |
| `sub_scale` | subtitleScale | float | `1.0` | Options: 0.8, 1.0, 1.25, 1.5. |
| `sub_background` | subtitleBackground | bool | `false` | Dark box behind subtitle text. |
| `last_scan` | lastScanAt | long | `0` | Epoch ms of the last scan. |
| `new_episode_alerts` | newEpisodeAlerts | bool | `true` | Notify on the air day of a new episode of a Watchlist show. |
| `play_from_phone` | playFromPhone | bool | `true` | TV only ("Play on TV" listener). Not applicable on Windows; keep the key for parity, unused. |

Other persisted preferences [SRC]:
- SharedPreferences `plans`, key `alerted_episodes`: StringSet of `"yyyy-MM-dd|showId:season:episode"`. Pruned to the newest 200 by sorting the strings and keeping the last 200.
- SharedPreferences `player` (PlayerPrefs; this belongs to the player area but is listed so nothing is missed):
  - `video:<videoKey>`: a 0x1F-separated record with 8 fields: audioIndex, audioLanguage, subtitleMode (`off`/`embedded`/`external`), subtitleIndex, subtitleLanguage, externalSource (`drive:<id>`/`device:<uri>`), externalName, subtitleOffsetMs.
  - `audio:<showId>`: the show's audio language.
  - `sub:<showId>`: a language code, or `off`.
  - `resize`: the ResizeMode name. Default `Fit`.
- `smb_servers` (encrypted) and the TvLink store belong to other areas.

[WIN] Store settings in `%LOCALAPPDATA%\Veltoret\settings.json` with the same key names, for example `{"onboarding_complete":true,"skip_seconds":85,...}`. Missing keys take the defaults above. Write atomically: write a temp file, then `File.Replace`. Expose `IObservable<AppSettings>` (or an event plus `Current`) so the theme and other subscribers react to changes, the way the DataStore Flow does. Put `alerted_episodes` in `%LOCALAPPDATA%\Veltoret\plans.json` as a string array.

### 2.2 LANGUAGES list [SRC] (order matters)

`en` English, `hi` Hindi, `es` Spanish, `fr` French, `de` German, `it` Italian, `pt` Portuguese, `ja` Japanese, `ko` Korean, `zh` Chinese, `ru` Russian, `ar` Arabic, `ta` Tamil, `te` Telugu, `ml` Malayalam, `bn` Bengali, `ur` Urdu, `tr` Turkish.

`languageLabel(code)` returns the name, or `code.ToUpperInvariant()` when the code is unknown.

---

## 3. Settings screen (phone/tablet `SettingsScreen.kt`; WPF should follow this one)

Layout [SRC]:
- Header "Settings" (`ScreenHeader`).
- Expanded width (≥ 840 dp): two columns side by side. The left column holds Sources and Library. The right column holds Playback, Subtitles, Reminders & alerts, Appearance, TMDB and About.
- Narrower: one column, max width 760 dp, centered, left content then right content.
- Snackbar at the bottom center for messages.
- Group titles are shown **UPPERCASE**, amber, small label style (padding start 24, top 28, bottom 10).
- Groups are panels with 1 px dividers between rows (16 px side inset).

[WIN] A window ≥ 840 px wide gives two columns. Use a snackbar-like transient banner at the bottom.

Row types:
- **SettingRow**: title, optional subtitle, optional amber icon, and a chevron when clickable.
- **SwitchRow**: title, subtitle and a toggle. The whole row toggles.
- **ChoiceRow**: title on the left, the selected label in amber on the right (`—` if none). A click opens a dropdown; the selected item is amber.

### 3.1 Sources (left)

- One panel per account, showing the avatar (40), displayName, the account subtitle, and a "Remove" text button (muted).
  - With no folders: "No library folders yet."
  - Per folder: a Movie or LiveTv icon (amber), the folder name (1 line, ellipsis) and the `ScanText.folder(...)` line (2 lines, Danger color if the folder has an error, else faint). Then a pill "Movies" or "TV".
  - Per-folder scan control: a spinner (18) while this folder is scanning, else a Sync icon button "Scan this folder", disabled while the folder is waiting.
  - Per-folder remove: a Close icon button "Remove folder".
  - Ghost button "Add library folder" (CreateNewFolder icon).
  - SMB accounts also get a ghost button "Send to TV" (Tv icon). [WIN] Omit it; there are no TVs on Windows.
- Secondary button "Add Google account" (PersonAdd). It shows loading while connecting.
- Secondary button "Add network server" (Dns).
- Secondary button "Use files on this device" (PhoneAndroid). Shown only when no `device` account exists. [WIN] Label it "Use files on this PC" (Windows folder picker), or keep the original string if parity is preferred.

Messages (snackbar):
- `Scanning "<folder name>"`
- `Added "<name>" — scanning now`
- `Connected <email>`
- `<error title>. <error message>`
- `Connected to <server name>. Choose a Movies or TV Shows folder.`
- `TMDB key saved`
- `TMDB rejected this key: <message>`
- `No browser to open <url>`
- `Couldn't open that folder` (fallback when adopting a device folder fails)

Folder picker dialog: title "Choose a library folder", actions "Movies" and "TV Shows".

Remove-account confirm dialog:
- Title: `Remove <displayName>?` for device/SMB accounts, else `Remove <email>?`.
- Body:
  - Device: "Its folders will be removed from your library. Nothing is deleted from this device."
  - SMB: "Its folders will be removed from your library and Veltoret forgets its password. Nothing is deleted from the server."
  - Google: "Its folders will be removed from your library. Nothing is deleted from Google Drive."
- Buttons: "Remove" (Danger color) and "Cancel".

### 3.2 Library (left)

- While a scan runs, the **ScanProgress** block shows:
  - Spinner, `ScanText.title`, `ScanText.step`.
  - Text button "Cancel" (amber).
  - A progress bar: determinate when `progress` is known (animated 400 ms), else indeterminate.
  - `ScanText.counts` and `NN%`.
  - `currentPath` (faint, 1 line) while `toMatch == 0`.
  - "Keeps going if you leave the app."
- Otherwise: SettingRow "Scan library now" with subtitle `ScanText.idle(scan, lastScanAt)` and a Sync icon. A click asks for notification permission, then runs `scanNow`.
- If unmatched > 0: "Unmatched files", subtitle `"<n> file(s) need identifying"` (singular "file" when n == 1, else "files"). Opens the Unmatched screen.
- "ZIP archives": subtitle "None found in your library" when 0, else `"<n> waiting to be extracted"`. Opens the Archives screen.

### 3.3 Playback (right)

- SwitchRow "Auto-play next episode": "Counts down at the end of an episode".
- ChoiceRow "Skip button": `+30s`, `+60s`, `+85s`, `+90s`, `+120s`.
- ChoiceRow "Double-tap seek": `5s`, `10s`, `15s`, `30s`. [WIN] Double-click maps to fullscreen in most Windows players. Keep the setting as the ←/→ key seek step, or relabel it "Seek step". This is a decision for the player spec.
- ChoiceRow "Preferred audio": the LANGUAGES list.
- ChoiceRow "Default subtitles": "Off" (value `""`) followed by the LANGUAGES list.

### 3.4 Subtitles (right)

- ChoiceRow "Text size": `0.8` Small, `1.0` Normal, `1.25` Large, `1.5` Extra large.
- SwitchRow "Background box": "Dark box behind subtitle text".

### 3.5 Reminders & alerts (right)

- SwitchRow "New episode alerts": "A notification on the day a show on your Watchlist airs a new episode". Turning it on asks for notification permission first.
- With no reminders: divider, then "No reminders. Use "Remind me" on a movie, show or episode." (muted, bodySmall, padding 16). The inner quotes are literal ASCII `"`.
- With reminders but notifications not allowed: divider, then (Danger color) "Notifications are off for Veltoret, so reminders can't appear. Turn them on in Android's settings for the app."
  - [WIN] Use: "Notifications are off for Veltoret, so reminders can't appear. Turn them on in Windows Settings → System → Notifications." Detect this with `ToastNotifierCompat.Setting != NotificationSetting.Enabled`.
- Each reminder, ordered by `at`, gets a divider and a row:
  - Amber bell icon.
  - `r.title` (titleSmall, 1 line).
  - `Plans.reminderLabel(r.at, now)` (muted).
  - Close icon button "Cancel reminder", which calls `cancelReminder(id)`.

### 3.6 Appearance

- SwitchRow "Pure black": "True black background for OLED screens".

### 3.7 TMDB (TmdbKeyPanel)

- Help text: "Paste your TMDB API key or API Read Access Token. Get one free at themoviedb.org → Settings → API."
- When the override is blank and a bundled key exists, append on a new line: "Currently using the key built into this copy of the app. Paste your own to replace it."
- Password field with label "TMDB key", a Key icon, and a show/hide toggle (Visibility icon, content description "Show key").
- Button "Save key", enabled only while the text differs from the current value. Save stores the key trimmed, then validates with TMDB. On success it shows "TMDB key saved" and starts a scan. On failure it shows `TMDB rejected this key: <msg>`.

### 3.8 About

- "Veltoret": `Version <VERSION_NAME> · open source · Developed by PNT Apps`.
- "Website": subtitle "pntapps.com", Language icon. Opens `https://www.pntapps.com`.
- "About us": subtitle "Who makes Veltoret", Info icon. Opens `https://www.pntapps.com/about`.
- "Privacy policy": subtitle "What happens to your data", PrivacyTip icon. Opens `https://www.pntapps.com/privacy`.
- TmdbAttribution: the TMDB logo plus the notice "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB." This is **required** by TMDB's terms.

[WIN] Open links with `Process.Start(new ProcessStartInfo(url){UseShellExecute=true})` inside try/catch. On failure show `No browser to open <url>`.

(The TV settings differ only in: a "Play from your phone" section ("Veltoret on a phone can open this TV, play here and be the remote"), "True black background for OLED TVs", and an About subtitle reading "Free and open source · Developed by PNT Apps". None of this applies to Windows.)

### 3.9 ScanText (exact wording) [SRC]

- `videos(n)` = `"<n> video"` + (`"s"` unless n == 1).
- `title(s)`:
  - `folderIds == null` → "Scanning your library"
  - `currentFolder != ""` → `Scanning <currentFolder>`
  - else → "Scanning folder"
- `step(s)`:
  - `toMatch > 0` → `Matching with TMDB · <matched> of <toMatch>`
  - currentFolder set and foldersTotal > 1 → `Reading <currentFolder> · folder <min(foldersDone+1, foldersTotal)> of <foldersTotal>`
  - currentFolder set → `Reading <currentFolder>`
  - else → `phase`, or "Starting" if phase is blank
- `counts(s)`: join with `" · "` of `videos(filesFound)`, then `"<newFiles> new"` if > 0, then `"<identified> identified"` if > 0.
- `idle(s, lastScanAt)`:
  - Broken folders > 0 → `"<n> folder(s) couldn't be read. Details are under Sources."` ("folder" if 1, else "folders").
  - Cancelled → `Last scan was cancelled <relative(lastFinishedAt).lower()>`.
  - Error → `Last scan had a problem: <error>`.
  - `lastFinishedAt > 0` → `<what> <relative.lower()>: <counts>`, where what is:
    - `folderIds == null` → "Last scan"
    - 1 folder → "Folder scan"
    - n folders → `Scan of <n> folders`
  - else → `Last scanned <relative(lastScanAt).lower()>`.
- `folder(folder, count, s)`:
  - This folder is scanning now → `Scanning… <currentPath or "top folder">`
  - The folder has an error → the error text
  - Waiting → `<videos(count)> · waiting to scan`
  - `lastScannedAt <= 0` → "Not scanned yet"
  - else → `<videos(count)> · scanned <relative(lastScannedAt).lower()>`

### 3.10 Format helpers (ui/util/Format.kt) [SRC]

| Function | Rule |
|---|---|
| `bytes(b)` | `b <= 0` → "—". Units B, KB, MB, GB, TB, dividing by 1024. GB and above use `"%.1f"`; below GB use `"%.0f"` (Locale US). |
| `runtime(min)` | null/≤0 → null. `"48m"`, `"2h"`, `"2h 46m"`. |
| `runtimeMs(ms)` | ≤0 → null, else `runtime(max(1, ms/60000))`. |
| `clock(ms)` | `"4:05"` or `"1:02:09"`. |
| `remaining(pos, dur)` | left = max(1, (dur-pos)/60000) → `"<h>h <m>m left"` if ≥ 60, else `"<m>m left"`. |
| `driveDate(iso)` | an ISO instant in local zone, formatted `"MMM d, yyyy"`. |
| `date(isoDate)` | `"yyyy-MM-dd"` formatted `"MMM d, yyyy"`; blank or invalid → null. |
| `relative(t)` | `t <= 0` → "Never"; < 1 min → "Just now"; < 60 min → `"<m> min ago"`; < 24 h → `"<h> h ago"`; else `"<d> days ago"` (note: "1 days ago" is the actual output). |
| `rating(v)` | ≤0 → null, else `"%.1f"`. |
| `episodeCode(s, e)` | either null → `""`; s == 0 → `"Special <e>"`; else `"S<s> · E<e>"`. |

[WIN] Use `CultureInfo.GetCultureInfo("en-US")` everywhere (the product is English US only).

### 3.11 Other ui/util items

- `WidthClass`: Expanded when ≥ 840 dp, Medium when ≥ 600, else Compact. Gutter: 20 / 28 / 40. [WIN] Base it on the window width in DIPs.
- `canPlayNow(accountEmail, online) = online || accountEmail == "device"`.
- `rememberOnline` uses Connectivity. [WIN] Use `NetworkInformation.GetInternetConnectionProfile()` plus the `NetworkStatusChanged` event.
- `AppIdentity` (OAuth SHA-1), `LocalNetworkAccess` (Android 17 permission) and `isTv`: Android-only. [WIN] Not needed; `isTv` is always false.
- `VoiceInput`: see section 8.

---

## 4. Watchlist [SRC]

- `setInWatchlist(type, id, saved)`: when saved, upsert `WatchlistEntity(type, id, now)`; otherwise delete.
- The detail page bookmark (`WatchlistButton`, 48 px):
  - Not saved: BookmarkBorder icon, tooltip "Watch later", text color.
  - Saved: filled Bookmark icon in amber, tooltip "Remove from Watchlist".
  - A click shows the toast "Added to your Watchlist" or "Removed from your Watchlist", then toggles.
  - In the overflow menu the same label is "Watch later" / "Remove from Watchlist".
- Home row "Watchlist": entries in `addedAt DESC` order.
  - A movie appears only when it is in the library **and not watched** (`watch_state["movie:<id>"].watched != true`).
  - A show appears whenever it is in the library.
  - Entries missing from the library are skipped.
- A new reminder also adds its title to the Watchlist if it isn't there yet (a snooze does not).

## 5. Reminders

### 5.1 Pure rules: `Plans` [SRC] (port to a static class and unit test it)

- Constants: `MOVIE = "movie"`, `TV = "tv"`, `STALE_AFTER_MS = 12 h = 43_200_000`.
- `stillAiring(status)` is true for "Returning Series", "In Production", "Planned" and "Pilot". Null or anything else is false.
- `quickTimes(now: LocalDateTime)` takes local time and returns ordered pairs (label, time):
  1. `"Tonight, 8 PM"` → today 20:00, **only if** `now.time < 19:30`.
  2. `"Tomorrow, 8 PM"` → today+1 at 20:00 (always).
  3. `"Saturday, 8 PM"` → the next Saturday **strictly after** today (`TemporalAdjusters.next`, so on a Saturday it means a week later) at 20:00. It is omitted when that Saturday is tomorrow, i.e. today is Friday.
- `airLabel(date "yyyy-MM-dd"?, today)`:
  - Unparseable, blank or null → null.
  - days = date - today:
    - < 0 → null
    - 0 → "Today"
    - 1 → "Tomorrow"
    - < 7 → the full weekday ("Friday", format `EEEE`)
    - else `"EEE, MMM d"` → "Mon, Oct 26"
  - C# formats: `"dddd"` / `"ddd, MMM d"` in en-US.
- `isUpcoming(date, today)` = parsed date ≥ today (so today counts). Null or invalid → false.
- `reminderLabel(at epochMs, now, zone = system)`:
  - Convert `at` to local time.
  - time = `"h:mm a"` (C# `"h:mm tt"` en-US → "8:00 PM").
  - dayDiff = `localDate(at) - now.date`: 0 → "Today", 1 → "Tomorrow", anything else (including past or negative) → `"EEE, MMM d"`.
  - Result: `"<day> at <time>"`.
- `due(at, now)`:
  - `at > now` → **Schedule**
  - `now - at <= STALE_AFTER_MS` → **FireNow** (inclusive at exactly 12 h)
  - else **Drop**
- `toMillis(LocalDateTime, zone)` converts local time to an epoch ms instant.
- `parse` accepts only ISO `yyyy-MM-dd` (`LocalDate.parse`). [WIN] Use `DateOnly.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out d)`.

### 5.2 PlansRepository [SRC]

- `addReminder(type, id, season?, episode?, title, at, addToWatchlist = true)`:
  1. Insert the row with `createdAt = now`.
  2. `schedule(saved)`.
  3. If `addToWatchlist` and the title isn't on the Watchlist yet, add it.
- `cancelReminder(id)`: delete the row and cancel its alarm.
- `schedule(r)` uses an **inexact** alarm: `AlarmManager.setWindow(RTC_WAKEUP, r.at, WINDOW_MS = 10 min, ...)`. It may fire anywhere in `[at, at+10min]`.
- `fire(id)` implements the **fire-once rule**:
  1. `r = dao.reminder(id)`. Return if it is gone.
  2. If notifications can't be posted, return **and keep the row**. Settings then shows the warning, and the row is retried at the next restore until it goes stale and is dropped.
  3. `if (dao.deleteReminder(id) == 0) return`. Another caller (the alarm, app start or boot) already took it.
  4. Only the caller whose DELETE removed the row posts the notification.
- `rescheduleAll()`: for every reminder, apply `Plans.due(r.at, now)`. Schedule → schedule it; FireNow → collect it; Drop → delete the row silently. Returns the collected overdue list.
- `restore()`: `for r in rescheduleAll(): fire(r.id)`. It runs on **every app start** and on boot or package-replaced.
- Snooze ("Snooze 1 hour", `SNOOZE_MS = 60 min`):
  1. Cancel the notification.
  2. `addReminder(type, media, season, episode, title, at = now + 1h, addToWatchlist = false)`.
  3. The extras carry the full reminder because the original row was deleted when it fired.

### 5.3 [WIN] Reminder scheduling on Windows

Android alarms map onto two Windows mechanisms. Both are needed, because the app may not be running at the reminder time.

1. **In-process scheduler** (always, while the app or tray process runs). Keep one `System.Threading.Timer` (or a `PeriodicTimer` that ticks every 30 s) aimed at the earliest `at`. When it fires, call `PlansRepository.Fire(id)` for each due row. A 30 s tick is fine: the Android tolerance is 10 minutes. Re-arm after every add, cancel or snooze. Also handle `SystemEvents.PowerModeChanged` (Resume) and `SystemEvents.TimeChanged` by running `Restore()` again.
2. **Scheduled toast**, for when the app is closed. Use `ToastNotifierCompat.AddToSchedule(new ScheduledToastNotification(xml, at))` with `Tag = "r{id}"` and `Group = "reminders"`. Remove it on cancel (`GetScheduledToastNotifications()` → match Tag → `RemoveFromSchedule`). Two limitations:
   - A scheduled toast's artwork and "Play" availability are computed when the reminder is created, not when it fires.
   - Windows shows the toast without running app code, so the DB row would remain.
   
   To keep the **fire-once rule**: in `Restore()`, before calling `Fire`, check whether Windows already delivered the toast. A row whose time has passed and whose Tag is no longer in the scheduled list was delivered (or the PC was off). Use `ToastNotificationManagerCompat.History.GetHistory()` to see whether a toast with Tag `r{id}` is present. If it is, delete the row without posting again. If there is no history entry and the row is FireNow, post it now. This keeps the Android guarantee ("never shown twice"). As a simpler alternative, ship only option 1 and add an optional "Start Veltoret in the background when I sign in" setting (tray icon, `HKCU\...\Run`). Pick one and document it.
3. App start equals `Restore()` (the boot receiver is unnecessary on Windows because there are no alarms to lose; the startup restore covers it).
4. "Can post" = `ToastNotifierCompat.Setting == NotificationSetting.Enabled`.

### 5.4 Reminder notification content [SRC → WIN toast]

Android channel "reminders": name "Reminders", importance HIGH, description "The movies and episodes you asked to be reminded about". Notification id = `0x4E000000 + reminderId`. Category REMINDER, subText "Reminder", amber accent `#E8A33D`. Large icon: the poster cropped to a top square (side = min(w, h), x = (w - side)/2, y = 0). Big picture: the backdrop or still at `w780` (the poster is hidden when expanded). Without a picture, BigText. Auto-cancel. Artwork comes through the image cache with an 8 s timeout and is null on failure.

Content by case. `episodeCode` is from Format; the separator is two spaces, a dot and two spaces: `"  ·  "`.

| Case | Title | Text | Picture | Playable |
|---|---|---|---|---|
| Movie in library | `Time for <movie.title>` | `[year, firstGenre, runtime]` non-null, joined with `" · "` (single spaces) | backdrop w780 | `playback.movieFile(id) != null` |
| Show with season and episode | `Time for <show.name>` | `[episodeCode, episodeName]` joined with `"  ·  "` | episode still w780, else show backdrop w780 | `playback.episodeFile(id,s,e) != null` |
| Show without an episode | `Time for <show.name>` | `target == null` → "Your reminder"; else `[ "Continue" if resuming else "Up next", episodeCode or omitted, episodeName ]` joined with `"  ·  "` | still of the target episode, else backdrop | `showPlayTarget(id) != null`. The Play button uses the target's season and episode. |
| Title gone from library | `Time for <r.title>` | "Your reminder" | none | false |

Actions:
- **"Play"**: only when playable and the movie or show exists. It opens the app with `play = true`. For a show reminder it also carries the target season and episode.
- **"Snooze 1 hour"**: always.
- **Body click**: opens the title's page (`OpenTarget(type, id, r.season, r.episode, play = false)`).

[WIN] Build it with `Microsoft.Toolkit.Uwp.Notifications` (`ToastContentBuilder`), or CommunityToolkit.WinUI.Notifications:

```csharp
new ToastContentBuilder()
  .AddArgument("action", "open").AddArgument("type", r.MediaType).AddArgument("id", r.MediaId)
  .AddArgument("season", r.Season?.ToString() ?? "").AddArgument("episode", r.Episode?.ToString() ?? "")
  .AddArgument("tag", $"r{r.Id}")                                // body click → open page
  .AddText(title).AddText(text)
  .AddAttributionText("Reminder")
  .AddHeroImage(new Uri(localBackdropFile))                       // optional
  .AddAppLogoOverride(new Uri(localPosterSquareFile))             // optional, square-top crop
  .AddButton(new ToastButton().SetContent("Play")                 // only when playable
      .AddArgument("action", "play").AddArgument("type", ...).AddArgument("id", ...)
      .AddArgument("season", targetSeason).AddArgument("episode", targetEpisode).AddArgument("tag", $"r{r.Id}"))
  .AddButton(new ToastButton().SetContent("Snooze 1 hour")
      .AddArgument("action", "snooze").AddArgument("type", ...).AddArgument("media", ...)
      .AddArgument("season", ...).AddArgument("episode", ...).AddArgument("title", r.Title)
      .AddArgument("tag", $"r{r.Id}").SetBackgroundActivation())
  .SetToastScenario(ToastScenario.Reminder)   // stays on screen like a HIGH-importance reminder
  .Show(t => { t.Tag = $"r{r.Id}"; t.Group = "reminders"; });
```

- Unpackaged desktop toasts accept only **local file** image URIs. Download the artwork into `%LOCALAPPDATA%\Veltoret\toast-cache\` first, with the 8 s timeout, and skip the image on failure.
- `ToastScenario.Reminder` needs at least one button, which Snooze guarantees.
- Handle `ToastNotificationManagerCompat.OnActivated`. It may run on a background thread, and also when the app was launched by the toast (check `ToastNotificationManagerCompat.WasCurrentProcessToastActivated()` at startup):
  - `open` / `play`: build an `OpenTarget` and push it into `OpenRequests`. Bring the main window forward, starting it if needed. Remove the toast (`History.Remove(tag, group)`); this replaces `DeepLinks.consume` dismissing the notification. Handle each activation exactly once (that rule replaces the Recents-replay guard on Android).
  - `snooze`: remove the toast, then `AddReminder(..., at: now+1h, addToWatchlist: false)`. Do **not** open a window if the app wasn't running (background activation), but the process must stay alive long enough to reschedule, including the scheduled toast.

### 5.5 Reminder dialog (TitlePlans.ReminderDialog) [SRC]

Step 0, choices (AlertDialog):
- Title "Remind me".
- Body: the title label (muted), then rows with an amber bell icon:
  - First, the `extra` options whose time is after now.
  - Then `Plans.quickTimes(now)`.
  - Then a row with an EditCalendar icon: "Pick a date and time…".
- Dismiss button "Cancel". There is no confirm button.

`extra` for an **episode that hasn't aired** (show page):
- Label: `When it airs (<airLabel(airDate)>, 8 PM)`. Time: the air date at 20:00.
- Only added when the episode is upcoming and its airDate parses.

Labels passed as `title` (this is what gets stored in `reminders.title`):
- Movie: `movie.title`.
- Show menu: `show.name`, with season and episode null.
- Episode: `"<show.name> · <episodeCode(season, number)>"`, with season and episode set.

Step 1, date:
- A date picker. The initial selection is today. Only today or later is selectable, and only years ≥ the current year.
- Buttons: "Next" (amber), which keeps the selected date and goes to step 2, and "Cancel".

Step 2, time:
- Title: `Format.date(date)` (for example "Oct 23, 2026"), or "Time".
- A 12-hour time picker, initially 20:00.
- Confirm "Set reminder" (amber), **enabled only if the chosen date-time is after now**.
- Dismiss "Back" returns to step 1.

`pick(at)`:
- If notifications can post: toast `"Reminder set for <reminderLabel>"` (short).
- Otherwise: ask for permission, then a long toast `"Reminder set for <label>. Allow notifications so it can appear."`
- Then `onPick(epochMs)` → `TitlePlans.remind(title, at, season, episode)` → `addReminder`.

[WIN] The dialog is a WPF ContentDialog-style overlay. Use a `Calendar` with `DisplayDateStart = today` plus an hour/minute/AM-PM picker. Toasts here mean an in-app transient message. Windows has no runtime notification permission. When toasts are disabled, show the second message and offer a link to `ms-settings:notifications`.

Where reminders appear [SRC]:
- On movie and show pages, the ⋮ menu item "Remind me…".
- On episode rows: a long-press menu with "Remind me…" and "Mark watched"/"Mark unwatched" (the latter only if available). Tapping an unavailable episode opens this menu. An upcoming episode without a file shows an amber bell button "Remind me". [WIN] Long press becomes right-click (ContextMenu).
- **ReminderList** under the action row lists the title's pending reminders:
  - An amber bell (18), then the text `[episodeCode if both set, "Reminder <reminderLabel>"]` joined with `"  ·  "`.
  - A Close button "Cancel reminder".
- Settings → Reminders & alerts (all reminders).
- The dialog lives outside the scrolling list (CLAUDE.md rule). [WIN] Host it at the page root, not inside a virtualized ItemsControl item.

---

## 6. Upcoming episodes

### 6.1 UpcomingWorker [SRC]

Schedule (`UpcomingWorker.schedule`, called at app start when onboarding is complete, and from onboarding's `startScan`):
- A unique periodic work `upcoming-daily`: every 1 day, initial delay until the next 10:00 local (today's 10:00 if still ahead, else tomorrow's). Network required. Policy KEEP: an existing schedule is not reset.
- A unique one-time work `upcoming-daily-now` that runs as soon as the network is available. Policy KEEP.

`doWork`:
1. If `!onboardingComplete` → success (no-op).
2. `watchlistShows` = the Watchlist entries with mediaType "tv".
3. `followed` = watchlistShows ∪ `watchedShowIds()` (shows that have any watch_state row).
4. For each followed id with a `shows` row: if `stillAiring(status) || nextEpisodeAirDate != null`, call `tmdb.ensureShow(id, seasons = {}, maxAgeMs = 20 h)`. This refetches `/tv/{id}` only when `now - show.updatedAt >= 20h` and rewrites the row, including the `nextEpisode*` fields from TMDB `next_episode_to_air` with blank name/date stored as NULL. Errors are swallowed per show.
5. If `newEpisodeAlerts` (and not on a TV), check alerts:
   - `today` = local date `"yyyy-MM-dd"`. `alerted` = the stored set.
   - For each **watchlist** show (not just followed) with `show.nextEpisodeAirDate == today`:
     - key = `"<today>|<showId>:<nextEpisodeSeason>:<nextEpisodeNumber>"`. A null prints as `null` in Kotlin string templates; reproduce it as `"null"`.
     - If the key is not in `alerted`: `showNewEpisode(show)` and add the key.
   - Save `alerted.sorted().takeLast(200)` (ordinal string sort).
6. Success.

The weekly library scans refresh shows only weekly (the default `maxAgeMs` of 7 days), which is why this worker exists.

### 6.2 New-episode notification [SRC]

- Channel "new-episodes": name "New episodes", importance DEFAULT, description "When a show on your Watchlist airs a new episode".
- id = `0x4F000000 + tmdbId`.
- Title: `New episode of <show.name>`.
- Text: `[episodeCode(nextSeason, nextNumber) or omitted, "“<nextEpisodeName>”" if not null, "out today"]` joined with `"  ·  "`. Example: `S3 · E2  ·  “Pilot”  ·  out today`.
- subText: `show.network`, or "New episode".
- Category RECOMMENDATION.
- Picture: backdrop w780. Icon: poster.
- No action buttons. A body click opens the show page (`OpenTarget("tv", id)`).
- Posted only if notifications are allowed.

[WIN] A toast with Tag `e{tmdbId}`, Group `new-episodes`, the attribution text network or "New episode", a hero image (the backdrop) and an app logo (the poster). Activation args: `action=open&type=tv&id=<id>`. Default scenario.

### 6.3 [WIN] UpcomingWorker on Windows

- At app start (after onboarding is complete), run once in the background when online. This replaces `upcoming-daily-now`. The 20 h `updatedAt` gate stops it from refetching too often, and the alerted set stops repeats.
- While the app (or its tray process) is running, schedule a timer for the next local 10:00 and repeat daily. If offline at that time, run on the next `NetworkStatusChanged` to online.
- Optional: register a Windows Task Scheduler task (`veltoret.exe --upcoming`, daily 10:00, "run only if network available", "run as soon as possible after a missed start") that runs the worker headless and exits. That matches Android's daily-even-when-closed behavior. Mark it optional; the startup run covers most needs.

### 6.4 Coming Up data (Home) [SRC]

- `followedShows` = Watchlist shows ∪ every `watch_state.showId` that is not null.
- `comingUp` = the library shows (`LibraryRepository.shows()`, which offline means only shows with device episodes) where `tmdbId ∈ followedShows && isUpcoming(nextEpisodeAirDate, today)`.
  - Sorted ascending by `nextEpisodeAirDate` (string compare of ISO dates).
  - Each is mapped to a show PosterItem with subtitle = `episodeCode(nextEpisodeSeason, nextEpisodeNumber)`, or null when empty, and **badge** = `airLabel(nextEpisodeAirDate, today)`.
- Home row title "Coming Up", shown only when it isn't empty. The Watchlist row is titled "Watchlist".
- The show detail page shows a CreditLine "Next episode" with `[episodeCode or omitted, “name” if set, airLabel]` joined with `"  ·  "`, shown only while `isUpcoming`.

---

## 7. Deep links / OpenRequests [SRC]

- `OpenTarget(mediaType, mediaId, season?, episode?, play = false)`.
- Android PendingIntents use a unique data URI per target: `veltoret://open/<notificationId>/<type>/<id>/<season>/<episode>/<play>`. This exists because intents that differ only in extras collapse into one PendingIntent. [WIN] The toast argument strings are already unique per toast; no URI is needed. Optionally register a `veltoret:` URL protocol for parity.
- `DeepLinks.consume`:
  - Ignores relaunches from history.
  - Parses the extras (type, id ≥ 0, season ≥ 0 or null, episode ≥ 0 or null, play).
  - Cancels the notification id carried in the extras.
  - Strips the extras so the request is handled once.
  - Puts the result into `AppContainer.openRequests` (a single-value state, `MutableStateFlow<OpenTarget?>`).
- `HandleOpenRequests` is **one long-lived collector**, started once in the app shell. For each non-null request:
  1. Set it back to null.
  2. Navigate to MovieRoute(id) or ShowRoute(id).
  3. If `play`:
     - movie → `playback.movieFile(id)`
     - season and episode both set → `playback.episodeFile(id, s, e)`
     - else → `playback.showPlayTarget(id)?.file`
     - Then play that file. Nothing happens if there is no file.
  
  The second collector reads `searchRequests`: clear it, set `spokenSearch = words`, navigate to Search. These are two separate flows so that navigation and the Search screen each read exactly once.
  
  [WIN] Use `Channel<OpenTarget>` (or an `IObservable` with replay-1 plus clear) consumed by a single loop started in the shell, never by a per-request handler that could be cancelled.
- PlaybackResolver (needed by notifications):
  - `movieFile`: playable copies, device first, then quality (DAO order).
  - `episodeFile`: device first, then the highest `height`.
  - `showTarget` = `PlayTargets.nextEpisode(playable(showFiles), watch.forShow(id))`.
  - `showPlayTarget` = showTarget, or `nextEpisode(playable, emptyList())` (restart at E1 once everything is watched).
  - Offline, `playable` keeps only `accountEmail == "device"` copies.

## 8. Voice

### 8.1 VoiceQuery.parse [SRC] (port exactly)

Regexes (Java/ICU syntax):
```
seasonEpisode = (?i)\bseason\s+(\d{1,2})\s*,?\s*(?:episode|ep)\s+(\d{1,3})\b
code          = (?i)\bs(\d{1,2})\s*e(\d{1,3})\b
episodeOnly   = (?i)\b(?:episode|ep)\s+(\d{1,3})\b
year          = \b(19\d\d|20\d\d)\b
leading       = (?i)^\s*(?:play|watch|start|resume|search(?:\s+for)?|find|open)\s+
trailing      = (?i)\s+(?:on|in|with|using)\s+veltoret\s*$
```

Algorithm:
1. `text = raw.Trim()`. Then **remove the trailing match first**, then the leading match. Kotlin `replace(regex, "")` replaces all matches, but both patterns are anchored, so there is at most one each.
2. `m = seasonEpisode.find(text) ?? code.find(text)` (the first match of each, in that order).
   - If found: season = g1, episode = g2, and remove `m.range` from text.
   - Else if `episodeOnly` matches: **season = 1**, episode = g1, and remove that range.
3. Year: `ym = year.find(text)`. If found and `text` without ym's range is **not blank**: year = ym value and text = text without it. Otherwise (no match, or the whole title is the year, as in "1917") the year stays null and the text is unchanged.
4. Collapse whitespace (`\s+` → `" "`) and trim. Return `Parsed(title, season, episode, year)`.

[WIN] In .NET use `RegexOptions.IgnoreCase | RegexOptions.CultureInvariant` and replace `\d` with `[0-9]`; .NET's `\d` also matches non-ASCII digits, while Java's matches only ASCII. `\b` and `\s` are close enough. "Remove range" is `text.Remove(m.Index, m.Length)`.

### 8.2 VoiceQuery.best [SRC]

- `wanted = normalizeForCompare(parsed.title)`. If empty → null.
- pool = shows only if `parsed.episode != null`, else every candidate.
- `score(wanted, year, c)`:
  - `title = normalizeForCompare(c.title)`. Empty → 0.
  - base:
    - `title == wanted` → **100**
    - `title.StartsWith(wanted + " ") || wanted.StartsWith(title + " ")` → **80**
    - `title.Contains(wanted) && wanted.Length >= 4` → **65**
    - else: `words` = the distinct words of `wanted` split on `' '` with length > 1. `have` = the words of `title`. If words is empty → 0. Otherwise `s = 50 * count(words ∈ have) / words.Count` (**integer division**), and base = `s >= 35 ? s : 0`.
  - yearBonus: year null or c.year null → 0; equal → +10; different → **−20**.
  - Return base + yearBonus.
- Keep only scores ≥ **40** (MIN_SCORE).
- Choose the max by (score, then `!isShow` so a movie beats a show, then `-title.Length` so the shorter original title wins). On full ties Kotlin `maxWithOrNull` keeps the **first** one. [WIN] Loop and replace only when strictly greater by that comparison.

`FilenameParser.normalizeForCompare(s)` [SRC], also used by the library and filename parser:
1. NFD normalize, remove the code points U+0300–U+036F, NFC normalize.
2. Lowercase. Kotlin `lowercase()` is locale-root, so use `ToLowerInvariant()`.
3. Remove apostrophes: `['`‘’ʼ]` → "".
4. `"&"` → `" and "`.
5. `[^\p{L}\p{M}\p{N} ]` → `" "`.
6. `\s+` → `" "`, then trim.
7. Remove the prefix `"the "` (once, only at the start).

### 8.3 VoiceRequests (Assistant intents) [SRC]

- `MEDIA_PLAY_FROM_SEARCH` and `ACTION_SEARCH` arrive at `VoiceActivity`, which consumes them and starts MainActivity.
- `said` = `EXTRA_MEDIA_TITLE`, else `SearchManager.QUERY`, trimmed. The action is then cleared so the request is used once.
  - Empty → nothing.
  - SEARCH → `searchRequests = parse(said).title`, or `said` if the parsed title is empty.
  - PLAY:
    1. Build candidates from the library movies `(tmdbId, false, title, year)` plus the shows `(tmdbId, true, name, year)`.
    2. `match = best(parse(said), candidates)`.
    3. No match → `searchRequests = parsed.title` or `said`.
    4. Match → `openRequests = OpenTarget(match.isShow ? "tv" : "movie", match.id, season if show, episode if show, play = true)`.

### 8.4 Search mic [SRC] and Windows mapping

Android behavior:
- `rememberVoiceInput("Say a title, actor or director", vm::speak)` uses the system RecognizerIntent: free-form, 1 result, no mic permission.
- The mic is hidden when the device has no voice input.
- The Search field's trailing slot: a Clear "X" when the query isn't empty, else the mic (amber Mic icon, "Search by voice").
- The search field label is "Titles, actors, directors, collections".
- `speak(text)`: `query = text.Trim()`, then `spoken++`. When `spoken > 0` the keyboard hides and the field isn't auto-focused, so spoken results show at once. Searches debounce for 200 ms.

[WIN] Mic button in Search:
- Use `Windows.Media.SpeechRecognition.SpeechRecognizer` (target `net10.0-windows10.0.19041.0` for WinRT projections), with `SpeechRecognitionTopicConstraint(SpeechRecognitionScenario.Dictation, "search")` (or `WebSearch`) and `RecognizeWithUIAsync()`. That shows a system listening UI; or use `RecognizeAsync()` with your own "Listening…" popup showing the prompt "Say a title, actor or director".
  - Dictation needs **Settings → Privacy → Speech → Online speech recognition**. On `HResult 0x80045509` (privacy policy not accepted), fall back to the offline `System.Speech.Recognition.SpeechRecognitionEngine` with a `DictationGrammar`, or hide the mic and tell the user how to enable it (`ms-settings:privacy-speech`).
  - Windows asks for microphone permission per app. A denied mic (`UnauthorizedAccessException`) also hides the mic or shows a message.
- Show the mic only when the query is empty and a recognizer is available; otherwise show Clear.
- On a non-blank result: `Speak(result)`. Set the query, show results immediately and don't select or focus the text box.
- Optional: if the recognized text starts with a play verb ("play …", "watch …"), run the VoiceRequests PLAY flow above (best match → open and play; no match → search). The mic in Android Search does **not** do this; it only searches. Treat it as an optional enhancement and keep the default identical (search only).
- Optional parity for "Hey Google": none on Windows. A `veltoret:play?q=<text>` protocol handler, or a `--play "<text>"` command-line argument, can route into the same PLAY flow (useful for Windows shortcuts or scripts).

---

## 9. App start sequence

### 9.1 Android [SRC]

`VeltoretApp.onCreate`:
1. `container = AppContainer(app)`. This constructs, in order:
   - appScope (SupervisorJob + Default)
   - Json (ignoreUnknownKeys, explicitNulls = false, coerceInputValues)
   - SettingsRepository
   - GoogleAuthManager
   - the Room DB
   - the OkHttp clients: base (connect 20 s, read 30 s); drive (+auth interceptor, read/write 60 s); media (read 45 s); tmdb (+TMDB auth from the live settings key)
   - Retrofit Drive (`https://www.googleapis.com/`) and TMDB (`https://api.themoviedb.org/3/`)
   - DriveRepository, LocalStorage, SmbServerStore, SmbStorage, SmbDiscovery, Storage
   - TmdbRepository, WatchRepository, Connectivity, LibraryRepository, AccountRepository
   - PlansRepository
   - openRequests, searchRequests, spokenSearch (each null)
   - PlaybackResolver
   - lazy cast / tvLink objects
   - LibraryScanner
2. Launch on the app scope:
   - a. `accountRepository.ensureServerAccounts()` (SMB servers without an account row get one).
   - b. If `onboardingComplete`: `SyncWorker.schedulePeriodic` (12 h, no network constraint, KEEP) and `UpcomingWorker.schedule` (daily at 10 AM plus once now).
   - c. `plans.restore()`: reschedule future reminders, fire those up to 12 h overdue (fire-once), drop older ones.
3. TV only: TvLink host init and the listener service (ignore on Windows).
4. Connectivity: for `online` transitions after the first value, distinct, true only: if onboarding is complete, `SyncWorker.runNow()` (catch-up rescan).
5. Coil ImageLoader: the OkHttp base client, crossfade 220 ms, disk cache `cacheDir/image_cache`, 512 MB.

`MainActivity.onCreate`:
1. The splash screen stays until settings load.
2. Edge-to-edge with dark bars.
3. `cast.init()`.
4. On a first launch (no saved state): `DeepLinks.consume(intent)` → openRequests.
5. Content:
   - `VeltoretTheme(oledBlack)`, with the width class from the window width.
   - settings null → blank.
   - Debug `preview_onboarding` extra → that onboarding step.
   - `!onboardingComplete` → OnboardingScreen.
   - else AppShell (TvApp on TV). The AppShell hosts `HandleOpenRequests`.

`onNewIntent` → `DeepLinks.consume` → openRequests. `RescheduleReceiver` (BOOT_COMPLETED / MY_PACKAGE_REPLACED) → `plans.restore()` (25 s timeout).

### 9.2 [WIN] Startup order for `App.OnStartup`

1. Single-instance guard: a named Mutex plus a pipe that forwards arguments and toast activations to the running instance, which is how activation reaches an already-open app (the `onNewIntent` equivalent).
2. Register `ToastNotificationManagerCompat.OnActivated` **before** anything else, and check `WasCurrentProcessToastActivated()`. A pure background "snooze" activation runs the snooze and exits if no window was open.
3. Build the AppContainer: settings.json, DB (create or migrate to v4), HttpClients with the same timeouts, repositories, PlansRepository, the OpenRequests / SearchRequests / SpokenSearch channels, PlaybackResolver, LibraryScanner, the image cache (512 MB disk cache).
4. Load settings, keeping the splash or blank window until they are loaded. Apply the theme (oledBlack). Show Onboarding when `!onboarding_complete`, else the shell. The shell starts the single long-lived OpenRequests and SearchRequests consumers.
5. Background tasks, in order:
   - `EnsureServerAccounts()`.
   - If onboarding is complete: start the periodic scan timer (12 h) and the Upcoming scheduler (run now if online, then daily at 10:00).
   - `Plans.Restore()`: re-arm the in-process timer, sync scheduled toasts, and fire overdue reminders up to 12 h late, once each.
6. Subscribe to `NetworkStatusChanged`: on a transition offline → online (ignore the initial value) with onboarding complete, run the library scan now.
7. Subscribe to `SystemEvents.PowerModeChanged` (Resume) and `TimeChanged`, and run `Plans.Restore()` again (this replaces the Android reboot receiver).
8. Process any pending activation (toast or command line) into OpenRequests.

---

## 10. Unit test cases to port to xUnit

### 10.1 PlansTest (Plans static class). Reference date: `monday = 2026-10-19` (a Monday)

**quickTimes**

| now (local) | expected labels | extra check |
|---|---|---|
| 2026-10-19 15:00 | ["Tonight, 8 PM", "Tomorrow, 8 PM", "Saturday, 8 PM"] | |
| 2026-10-19 21:00 | ["Tomorrow, 8 PM", "Saturday, 8 PM"] | |
| 2026-10-23 10:00 (Fri) | ["Tonight, 8 PM", "Tomorrow, 8 PM"] | times[1] == 2026-10-24 20:00 |

**airLabel(date, today = 2026-10-19)**

| date | expected |
|---|---|
| "2026-10-19" | "Today" |
| "2026-10-20" | "Tomorrow" |
| "2026-10-23" | "Friday" |
| "2026-10-26" | "Mon, Oct 26" |
| "2026-10-18" | null |
| "" | null |
| "not a date" | null |

**isUpcoming(date, today = 2026-10-19)**

| date | expected |
|---|---|
| "2026-10-19" | true |
| "2027-01-01" | true |
| "2026-10-18" | false |
| null | false |

**reminderLabel(at, now = 2026-10-19 12:00, zone = UTC)**. `at` is the UTC epoch ms of the local time.

| at (UTC local time) | expected |
|---|---|
| 2026-10-19 20:00 | "Today at 8:00 PM" |
| 2026-10-20 09:30 | "Tomorrow at 9:30 AM" |
| 2026-10-23 20:00 | "Fri, Oct 23 at 8:00 PM" |

**due(at, now = 1_000_000_000_000)**. `STALE_AFTER_MS = 43_200_000`.

| at | expected |
|---|---|
| now + 60_000 | Schedule |
| now - 60_000 | FireNow |
| now - STALE_AFTER_MS | FireNow |
| now - STALE_AFTER_MS - 1 | Drop |

**stillAiring**

| status | expected |
|---|---|
| "Returning Series" | true |
| "In Production" | true |
| "Ended" | false |
| "Canceled" | false |
| null | false |

[WIN] Give `ReminderLabel` a `TimeZoneInfo` parameter and pass `TimeZoneInfo.Utc` in tests. Give `QuickTimes` a `DateTime now` (Kind Unspecified, meaning local).

### 10.2 VoiceQueryTest

Library candidates (id, isShow, title, year):

| id | isShow | title | year |
|---|---|---|---|
| 1 | false | The Wrecking Crew | 2026 |
| 2 | false | Hokum | 2026 |
| 3 | false | Spider-Man: No Way Home | 2021 |
| 4 | true | Below | 2025 |
| 5 | false | Below Deck Movie | 2019 |
| 6 | false | Dune | 2021 |
| 7 | false | Dune | 1984 |
| 8 | true | House of the Dragon | 2022 |
| 9 | false | 1917 | 2019 |
| 10 | false | Don't Look Up | 2021 |

**parse**: expected `Parsed(title, season, episode, year)`.

| input | title | season | episode | year |
|---|---|---|---|---|
| "Below season 1 episode 2" | "Below" | 1 | 2 | null |
| "play House of the Dragon S02E05 on Veltoret" | "House of the Dragon" | 2 | 5 | null |
| "Below episode 3" | "Below" | 1 | 3 | null |
| "watch Dune 2021" | "Dune" | null | null | 2021 |
| "1917" | "1917" | null | null | null |

**pick(said) = best(parse(said), library)?.id**

| said | expected id |
|---|---|
| "the wrecking crew" | 1 |
| "wrecking crew" | 1 |
| "hokum" | 2 |
| "spider man no way home" | 3 |
| "dont look up" | 10 |
| "1917" | 9 |
| "Below" | 4 (exact show beats the longer movie) |
| "below deck movie" | 5 |
| "Below season 1 episode 2" | 4 (episodes match only shows) |
| "Dune 2021" | 6 |
| "Dune 1984" | 7 |
| "the godfather" | null |
| "" | null |

### 10.3 PlayTargetsTest

Fixture:
- show = 42.
- `file(s, e)` = MediaFile with driveId `"f{s}-{e}"`, accountEmail "a@b.c", libraryFolderId 1, name `"S{s}E{e}.mkv"`, parentId "p", relativePath "", sizeBytes 1, modifiedTime null, mime "video/x-matroska", durationMs/width/height 0, kind EPISODE, parsedTitle "Show", parsedYear null, season s, episode e, episodeEnd null, movieId null, showId 42, matchState MATCHED, addedAt 0.
- `state(s, e, watched, at, position = 0)` = WatchState with key `"ep:42:{s}:{e}"`, positionMs position, durationMs 3_000_000, watched, lastWatchedAt at, lastFileId null, movieId null, showId 42, season s, episode e.
- files = [file(1,1), file(1,2), file(1,3), file(2,1), file(0,1)].

| test | states | expected |
|---|---|---|
| freshShowStartsAtS1E1 | [] | S1E1, `fresh == true` |
| continuesAfterLastWatched | [state(1,1,true,10), state(1,2,true,20)] | S1E3 |
| crossesSeasonBoundaryAndSkipsSpecials | [state(1,3,true,30)] | S2E1 |
| resumesNewerInProgressEpisode | [state(1,1,true,10), state(1,2,false,20, position 600_000)] | S1E2, `resuming == true` |
| allCaughtUp | [state(2,1,true,99)] | null |

The algorithm, needed for the port:
1. Keep files with a season and episode. Sort by (season == 0 ? int.MaxValue : season, episode). Keep only the first file per (season, episode).
2. Empty → null.
3. `lastWatched` = the watched state with a season and the max `lastWatchedAt`.
4. `inProgress` = the state that is not watched, has `positionMs > 30_000` and a season, with the max `lastWatchedAt`.
5. If inProgress exists and (lastWatched is null or `inProgress.lastWatchedAt > lastWatched.lastWatchedAt`), and a playable file matches its season and episode → return that file with `resuming = true`.
6. If lastWatched exists: return the first playable f where `after && state(f)?.watched != true`, else null.
   - If lastSeason == 0: `after = f.season == 0 && f.episode > lastEp`.
   - Else: `after = (f.season > lastSeason && f.season != 0) || (f.season == lastSeason && f.episode > lastEp)`.
   - lastEp = `lastWatched.episode ?? 0`.
7. Otherwise return the first file with season != 0 (or the first file), with `fresh = true`.

The state lookup uses `WatchKeys.forFile`:
- movieId set → `"movie:{id}"`
- show, season and episode set → `"ep:{show}:{s}:{e}"`
- else `"file:{driveId}"`

### 10.4 RelatedTitlesTest

Library map: {1:"Self", 2:"Two", 3:"Three", 4:"Four", 5:"Five"}, selfId = 1, default LIMIT = 20.

| call | expected |
|---|---|
| inLibrary([99,4,2,77,5]) | ["Four","Two","Five"] |
| inLibrary([1,3,3,2,1]) | ["Three","Two"] |
| inLibrary([2,3,4,5], limit=2) | ["Two","Three"] |
| inLibrary(parseIds(null)) | [] |
| inLibrary(parseIds("")) | [] |
| parseIds("12,345, 6,,x") | [12,345,6] |

Implementation:
- `parseIds` = split on ',', trim each, keep those that parse as int.
- `inLibrary` = filter `!= selfId` → distinct (first occurrence) → map through the library, dropping misses → take(limit).
- [WIN] Parse with `int.TryParse(s.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out v)`. Kotlin `toIntOrNull` accepts a leading '-' or '+'.

### 10.5 TrailerPickTest (`pickTrailer(videos, newest)` → key or null)

`video(key, type = "Trailer", official = true, date = "2020-01-01", site = "YouTube")`.

| test | videos | newest | expected |
|---|---|---|---|
| trailerBeatsTeaserAndClips | clip(Clip), teaser(Teaser), trailer, bts(Behind the Scenes) | false | "trailer" |
| teaserWhenThereIsNoTrailer | clip(Clip), teaser(Teaser) | false | "teaser" |
| officialBeatsFanUploads | fan(official=false, 2019-01-01), official | false | "official" |
| moviesTakeTheOriginalTrailer | rerelease(2021-05-01), original(1999-02-01), undated(null) | false | "original" |
| …showsTheLatest | same | true | "rerelease" |
| onlyYouTube | vimeo(site Vimeo), ""(YouTube, blank key) | false | null |

Algorithm:
1. Filter: `site.Equals("YouTube", OrdinalIgnoreCase) && key not blank && type ∈ ["Trailer","Teaser"]`.
2. Stable sort by:
   - the index of type in that list (Trailer first),
   - then official first,
   - then date: if either date is empty, the dated one comes first (`compare = y.Length.CompareTo(x.Length)` clamped to −1..1); else, when `newest`, descending ordinal string order, otherwise ascending.
3. Take the first key, or null.

[WIN] Use LINQ `OrderBy(...).ThenBy(...)` with a custom `IComparer<string>` for the date. LINQ ordering is stable; `List.Sort` is not, so don't use it.

---

## 11. Don't-break rules carried over (from CLAUDE.md)

- Reminders fire within about 10 minutes of the chosen time and need no exact timing. Restore runs on every start. Overdue by ≤ 12 h → fire; older → drop silently.
- **Fire once**: post only if your DELETE removed the row. With notifications off, keep the row (Settings warns).
- Snooze re-creates the reminder from the toast arguments and **must not** re-add the title to the Watchlist.
- Each toast action must carry its own complete arguments. One reminder's Play must never open another title.
- Handle each activation once, and dismiss the toast when it is acted on.
- OpenRequests needs a single long-lived consumer. Clearing the request must not cancel the playback lookup.
- New-episode alerts are once per episode (the `alerted_episodes` key set, newest 200), for Watchlist shows only, on the air day, and only when "New episode alerts" is on.
- The UpcomingWorker refreshes followed shows (Watchlist ∪ watched) that are still airing or have a next air date, at most once per 20 h each.
- Dialogs on scrolling pages live outside the virtualized list.
- DB changes need a migration. Never use destructive fallback.
- The TMDB attribution (logo plus notice) stays in Settings → About.
