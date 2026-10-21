# Porting spec: Google sign-in, Drive, Storage facade, Files, ZIP extraction, uploads, accounts

Source of truth: Android app `Veltoret` (Kotlin/Compose), commit `e64fe84`. Files read:
`data/auth/GoogleAuthManager.kt`, `data/drive/{DriveApi,DriveModels,DriveRepository,UploadWorker,ExtractWorker}.kt`,
`data/storage/{Storage,LocalStorage}.kt`, `data/library/{AccountRepository,ArtworkPrefetch,SyncWorker}.kt`,
`data/library/LibraryScanner.kt` (ScanState only), `data/net/Connectivity.kt`, `VeltoretApp.kt`, `AppContainer.kt` (HTTP clients),
`player/DriveMedia.kt`, `ui/files/*`, `ui/accounts/AccountConnector.kt`, `ui/settings/{SettingsScreen,ScanText}.kt`,
`ui/util/Format.kt`, `data/tmdb/TmdbApi.kt` (TmdbImages), test `DriveStreamingUploadTest.kt`.

Target: C# / .NET 10 / WPF (`net10.0-windows10.0.19041.0` or later recommended so WinRT network APIs are available).

Conventions in this document:
- **[A]** = exact Android behaviour (port it as-is).
- **[W]** = recommended Windows design (a decision for the port; Android has no equivalent).
- **[!]** = gotcha / something that must be checked or decided.
- UI strings are quoted exactly as they appear in the Android source, including curly vs straight quotes and the `…` / `—` / `·` / `×` characters.

---

## 1. Accounts and identifiers [A]

| Source | Account id (`accountEmail` column) | Display name | Root folder id | Root name |
|---|---|---|---|---|
| Google Drive | the Google email | `about.user.displayName` (fallback: part of email before `@`) | `"root"` | `"My Drive"` |
| This device | `"device"` (`LocalStorage.ACCOUNT`) | `"This device"` | `"device-root"` | `"This device"` |
| Network share | `"smb://host"` | saved server name (fallback: host) | the account id itself | server name |

File ids: Drive file id; device = Android SAF document URI string (Windows: absolute path, see section 5.3); SMB = `smb://host/share/path`.
Several accounts merge into one library. Any code that must work for all sources goes through the `Storage` facade (section 5).

`AccountEntity(email, displayName, photoUrl, addedAt)` and `LibraryFolderEntity(id, accountEmail, driveFolderId, name, type: MOVIES|SHOWS, lastScannedAt)` are the DB rows involved (schema itself is covered by the DB spec).

### 1.1 AccountRepository operations [A]

- `addAccount(email, accessToken?)`: if a token is supplied, cache it (`auth.remember`). Then `GET about` (section 3.4) and upsert
  `AccountEntity(email, displayName = about.user.displayName ?: email.substringBefore('@'), photoUrl = about.user.photoLink, addedAt = now)`.
  Failure here surfaces as "Couldn't open your Drive" (section 2.3).
- `ensureDeviceAccount()`: insert `("device", "This device", null, now)` if missing. Called when the user adds a device folder or picks "Files on this device".
- `addServerAccount(server)`: upsert `(server.account, server.name, null, existing.addedAt ?: now)`. `ensureServerAccounts()` runs at every app start (back-fills rows for saved servers).
- `removeAccount(email)`:
  1. if device: release folder permissions of each of its library folders (Windows: nothing to release),
  2. delete its library folders, media files, subtitle files, archive rows, the account row,
  3. `catalog.prune()` (drops titles no longer in any source),
  4. SMB: disconnect and forget the saved server (incl. password). Google: `auth.forget(email)` (drop cached token). **Android does not revoke the grant.**
     [W] On Windows delete the stored refresh token for that account (section 2.2). Do not call the revoke endpoint by default (matches Android, and revocation kills the grant for that client on other PCs too); optional.
- `addLibraryFolder(email, folderId, name, type)`: ensures device account if `email == "device"`; inserts; returns new row id or `null` when the folder was already in the library (unique constraint → insert returns <= 0).
- `removeLibraryFolder(folder)`: deletes its media/subtitle/archive rows and the folder row; device: release permission only if no other library folder uses the same `driveFolderId`; `catalog.prune()`.

---

## 2. Google sign-in

### 2.1 Android today [A]

- Play services `Identity.getAuthorizationClient(context).authorize(AuthorizationRequest)` with
  `setRequestedScopes([Scope("https://www.googleapis.com/auth/drive")])` and `setAccount(Account(email, "com.google"))`.
- **Only one OAuth scope: `https://www.googleapis.com/auth/drive`** (full Drive). No `openid`/`email`/`profile`; the email comes from the
  Android account chooser and the name/photo from Drive `about`.
- There is no client id in the app: Google matches the build by package name + SHA-1 (Android OAuth client). Play services holds the long-lived grant.
- Connect flow (`rememberAccountConnector`):
  1. System account chooser (`AccountManager.newChooseAccountIntent`, type `com.google`) → email.
  2. `authorize(email)`; if `hasResolution()` → launch consent `PendingIntent`; result → `getAuthorizationResultFromIntent`.
  3. `accountRepository.addAccount(email, accessToken)`.
  - `reconnect(email)` skips step 1.
- Tokens (`GoogleAuthManager`): in-memory cache per email, **TTL 45 minutes** from the moment it was obtained (`TOKEN_TTL_MS = 45*60*1000`).
  `accessToken(email)`: return cached if not expired; otherwise under a single global mutex (double-checked) call `authorize(email)` silently;
  if it needs a resolution or returns no token → throw `AuthRequiredException(email)` ("Google account {email} needs to be reconnected").
  Other failures → `IOException("Could not authorize {email}: {message}")`.
  `invalidate(email)` removes the cached token and calls `GoogleAuthUtil.clearToken` (used on HTTP 401).
- Every Drive REST call is tagged with the account; an OkHttp interceptor adds `Authorization: Bearer <token>` and, **on HTTP 401, invalidates and retries exactly once** with a fresh token.
- Player streaming (`DriveMedia`): media URI `veltoret-drive://media/<fileId>?account=<email>` resolved on every open (and every seek re-open) to
  `https://www.googleapis.com/drive/v3/files/<fileId>?alt=media&supportsAllDrives=true` with a fresh `Authorization: Bearer` header — so seeking works after the original token expired.

### 2.2 Windows: OAuth 2.0 installed-app loopback flow with PKCE [W]

Use Google's "Desktop app" OAuth client and the loopback redirect (RFC 8252). Either hand-roll it (about 200 lines, no dependency) or use
`Google.Apis.Auth` (`GoogleWebAuthorizationBroker` + `LocalServerCodeReceiver`, Apache-2.0, GPL-3 compatible). Hand-rolled is recommended so
per-account storage, cancellation and error messages stay under our control.

**Client configuration.** The user creates the client (section 2.4) and either imports the downloaded `client_secret_*.json`
(`{"installed": {"client_id": "...", "client_secret": "...", ...}}`) or pastes Client ID + Client secret. Store in
`%APPDATA%\Veltoret\google-client.json`. Never ship one in the repo (CLAUDE.md "Users bring their own Google Cloud OAuth client"). For a Desktop
client Google does not treat the secret as confidential, but it is still required by the token endpoint.

**Authorization request** (open in the default browser with `Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })`):

```
GET https://accounts.google.com/o/oauth2/v2/auth
  ?client_id={client_id}
  &redirect_uri=http://127.0.0.1:{port}/          (any free port; Desktop clients accept any loopback port, nothing to register)
  &response_type=code
  &scope=https://www.googleapis.com/auth/drive    (same single scope as Android; space-separate if more are ever added)
  &code_challenge={BASE64URL(SHA256(code_verifier))}
  &code_challenge_method=S256
  &state={random 32 bytes, base64url}
  &access_type=offline                            (needed to get a refresh_token)
  &prompt=consent select_account                  ("Add Google account": force chooser + consent so a refresh_token is always returned)
  &login_hint={email}                             (reconnect only; with prompt=consent)
  &include_granted_scopes=true
```

- `code_verifier`: 43–128 chars from `[A-Za-z0-9-._~]` (e.g. 32 random bytes base64url = 43 chars).
- Listener: `HttpListener` on `http://127.0.0.1:{port}/` (pick a free port by binding a `TcpListener` to port 0 first). Accept one request,
  verify `state`, read `code` or `error`, reply with a small HTML page ("Veltoret is connected. You can close this tab and go back to the app."
  / an error page), then stop. Timeout 5 minutes and a Cancel button in the app's "Connecting…" state (Android's `busy()` shows a spinner on the
  "Add Google account" button).

**Code exchange:**

```
POST https://oauth2.googleapis.com/token
Content-Type: application/x-www-form-urlencoded
  code={code}&client_id=...&client_secret=...&redirect_uri=http://127.0.0.1:{port}/&grant_type=authorization_code&code_verifier={verifier}
→ { access_token, expires_in (s, ~3599), refresh_token, scope, token_type: "Bearer" }
```

Check the returned `scope` contains `https://www.googleapis.com/auth/drive` (the consent screen lets users untick it). If missing → treat as
"Google didn't grant access".

**Which account was that?** Android knows the email from the chooser. On Windows call `GET drive/v3/about?fields=user(displayName,emailAddress,photoLink),storageQuota(limit,usage)`
with the new access token and use `user.emailAddress` as the account id (no extra `openid email` scopes needed, which keeps the consent screen
identical to the Android setup). On reconnect, if the returned email differs from the account being reconnected, show an error and discard the token.
Then call the same `addAccount(email, accessToken)` logic.

**Refresh:**

```
POST https://oauth2.googleapis.com/token
  client_id=...&client_secret=...&refresh_token={rt}&grant_type=refresh_token
→ { access_token, expires_in, scope, token_type }      (refresh_token normally not rotated; store it if one is returned)
```

- `400 {"error":"invalid_grant"}` (revoked, expired, password change, Testing-mode 7-day expiry) → delete the stored refresh token and throw
  `AuthRequiredException(email)` → UI shows the account as needing reconnection (reconnect = run the flow with `login_hint`).
- `401 invalid_client` / `unauthorized_client` → configuration problem ("Google sign-in isn't set up for this build").
- Network errors → `IOException` (offline handling elsewhere).

**Token cache (port of `GoogleAuthManager`):**
- `Task<string> AccessTokenAsync(email, ct)`: cached in memory per email; treat as valid until `obtainedAt + min(expires_in - 300 s, 45 min)`.
  Use one `SemaphoreSlim` (Android uses one global mutex; per-account semaphores are fine too) with double-checked lookup so parallel calls refresh once.
- `Invalidate(email)`: drop cached access token (called on 401).
- `Forget(email)`: drop cache and stored refresh token.
- `Remember(email, token, expiresIn)`.

**Per-account storage:** `%LOCALAPPDATA%\Veltoret\accounts\{sha256(email) hex}.bin` containing JSON `{email, refreshToken, scope, savedAt}` encrypted with
DPAPI (`System.Security.Cryptography.ProtectedData.Protect(..., DataProtectionScope.CurrentUser)`, package `System.Security.Cryptography.ProtectedData`).
Never log tokens. Access tokens are memory-only.

**HTTP auth handler** (port of `DriveAuthInterceptor`): a `DelegatingHandler` that reads the account from `HttpRequestMessage.Options`
(e.g. `HttpRequestOptionsKey<string>("veltoret.account")`), sets `Authorization: Bearer`, and on 401 calls `Invalidate` + gets a fresh token and
re-sends **once**. A `HttpRequestMessage` cannot be sent twice: clone it (method, URI, headers, and a re-creatable content — the upload chunk is a
`ByteArrayContent` over the reusable buffer, so recreate it).

**[!] Testing-mode refresh tokens expire after 7 days.** Google issues 7-day refresh tokens to apps whose consent screen is External + "Testing"
when they request anything beyond name/email/profile. Android's Play services flow hides this; a desktop app would ask the user to reconnect weekly.
Options to document in SETUP (section 2.4): (a) accept weekly reconnects, or (b) set the app's publishing status to "In production" without
submitting for verification — users then see the "Google hasn't verified this app" warning (same as now) and the project is capped at 100 users,
but refresh tokens do not expire after 7 days. Verify the current Google policy when implementing.

### 2.3 Error mapping for the connect flow [A strings, W triggers]

Android `ConnectError(title, message, setupProblem)`; Settings shows them as a snackbar `"{title}. {message}"`. Keep the strings:

| Title | Message | setupProblem | Android trigger | Windows trigger |
|---|---|---|---|---|
| "Google didn't grant access" | "If you closed the Google screen, just try again. If Google showed \"Access blocked\" or an error like 400 / 401 / 403, this copy of the app isn't registered with Google Cloud yet." | yes | consent activity not RESULT_OK | redirect has `error=access_denied`, scope missing, or browser timeout |
| "Google sign-in isn't set up for this build" | "Google doesn't recognise this app yet. Register its package name and SHA-1 fingerprint as an Android OAuth client in Google Cloud, then try again." | yes | `DEVELOPER_ERROR` | no client configured, `invalid_client`, `redirect_uri_mismatch`. **[W] reword**: "Google doesn't recognise this app yet. Create a Desktop app OAuth client in Google Cloud and import its client file in Settings, then try again." |
| "No connection" | "Check your internet connection and try again." | no | `NETWORK_ERROR` | `HttpRequestException`/socket errors |
| "Sign-in cancelled" | "Tap Connect to try again." | no | `CANCELED` | user pressed Cancel in the app ([W] "Click Connect to try again.") |
| "Couldn't connect" | "{message or 'Google sign-in failed.'}{ ' (code N)' if a status}" | if no status or INTERNAL_ERROR | other | other token-endpoint errors |
| "Couldn't open your Drive" | "{message or 'Google Drive didn't respond. Check your connection and try again.'}" | no | `addAccount` (about) failed | same |

On success Settings shows `"Connected {email}"`. Android's error card for setup problems has a "Setup details for this build" section
(package name + SHA-1 with copy buttons). [W] Desktop equivalent: show the configured Client ID (masked middle), the redirect form
`http://127.0.0.1:<port>/`, and "Application type: Desktop app" with copy buttons.

### 2.4 SETUP.md draft for Windows (replaces Android Steps 2 and 6)

> Steps 3, 4 and 5 (create project, enable **Google Drive API**, configure **Google Auth Platform**, add **test users**, add the
> `.../auth/drive` scope under **Data Access**) are identical to the Android guide and can be reused word for word.

**Step 6 · Create a Desktop OAuth client**

1. In Google Cloud, open **Google Auth Platform → Clients → + Create client**.
2. **Application type:** **Desktop app**. **Name:** `Veltoret for Windows` (only you see it).
3. Click **Create**. In the dialog that appears, click **Download JSON** (the file is named `client_secret_….apps.googleusercontent.com.json`).
   You can download it again later from the client's page.
4. In Veltoret, open **Settings → Google sign-in → Import client file** and pick that JSON file
   (or paste the **Client ID** and **Client secret** shown in the console).
5. Click **Add Google account**. Your browser opens Google's sign-in page. Pick the account, then on *"Google hasn't verified this app"* click
   **Continue**, make sure **See, edit, create, and delete all of your Google Drive files** is ticked, and click **Continue**.
6. The browser says Veltoret is connected; go back to the app.

> [!NOTE] No redirect URI to enter: Desktop clients accept `http://127.0.0.1` on any port automatically.
>
> [!IMPORTANT] Google can take **5–10 minutes** to apply a new client.
>
> [!NOTE] While the app is in **Testing**, Google makes you sign in again every 7 days. To avoid that for personal use, open
> **Google Auth Platform → Audience → Publish app** (no verification needed for up to 100 users; everyone still sees the "unverified app" warning once).
>
> The same Desktop client works on every PC — there is no per-machine fingerprint as on Android. Keep the JSON private: anyone with it can show
> *your* app name on Google's sign-in screen (they still can't access anyone's Drive without that person signing in).

Troubleshooting rows to add:

| What you see | Meaning | Fix |
|---|---|---|
| "Google sign-in isn't set up for this build" | No client imported, or it isn't a Desktop client | Import the JSON of a **Desktop app** client (Step 6). |
| `Error 400: redirect_uri_mismatch` in the browser | The client is a **Web application** client | Create a **Desktop app** client instead. |
| "Access blocked … has not completed the Google verification process" / `Error 403: access_denied` | Account isn't a test user | Add it under **Audience → Test users**. |
| An account says it needs reconnecting every week | App is in Testing (7-day tokens) | Reconnect, or publish the app (note above). |
| Browser didn't open / page says "unable to connect" | Firewall or security tool blocks `127.0.0.1` | Allow Veltoret on loopback, try again. |

---

## 3. Google Drive REST (v3) — exact calls [A]

Base URL `https://www.googleapis.com/`. JSON with unknown keys ignored; nulls omitted in request bodies (`explicitNulls = false`), so an all-null
update body serializes as `{}`. Drive sends int64 fields (`size`, `durationMillis`, quota values) as **JSON strings**.

```
DRIVE_FILE_FIELDS = id,name,mimeType,size,modifiedTime,parents,fileExtension,videoMediaMetadata(width,height,durationMillis),capabilities(canRename,canTrash,canDelete,canAddChildren)
DRIVE_LIST_FIELDS = nextPageToken,files(<DRIVE_FILE_FIELDS>)
FOLDER_MIME       = application/vnd.google-apps.folder
```

Query-string values must be URL-encoded (`Uri.EscapeDataString`). Escaping inside `q` string literals: `\` → `\\`, then `'` → `\'` (`DriveRepository.escape`).

### 3.1 List (files.list)

`GET drive/v3/files?q=…&pageToken=…&orderBy=…&fields=DRIVE_LIST_FIELDS&pageSize=…&supportsAllDrives=true&includeItemsFromAllDrives=true`
(`pageToken` omitted on the first page; `orderBy` omitted when null.)

| Use | `q` | `orderBy` | `pageSize` | Paging |
|---|---|---|---|---|
| Folder children (Files tab, folder picker, extract) | `'<escaped folderId>' in parents and trashed = false` | `folder,name_natural` (default) | 1000 | all pages, follow `nextPageToken` until null |
| Library scan walk (`LibraryScanner`) | same | `folder` | 1000 | all pages |
| Shared with me | `sharedWithMe = true and trashed = false` | `folder,name` | 1000 | all pages |
| Search (whole account) | `name contains '<escaped text>' and trashed = false` | `folder,name` | **200** | **first page only** |

Root folder id is the alias `root`.

### 3.2 Get (files.get)
`GET drive/v3/files/{id}?fields=DRIVE_FILE_FIELDS&supportsAllDrives=true`

### 3.3 Update (files.update) — rename, move, trash
`PATCH drive/v3/files/{id}?fields=DRIVE_FILE_FIELDS&supportsAllDrives=true[&addParents=X][&removeParents=Y]`, JSON body:
- rename: `{"name":"<new>"}` (returns the same id)
- move: body `{}`, `addParents=<target>`, `removeParents=<current parent>` (`removeParents` omitted when the source parent is unknown)
- trash: `{"trashed":true}` ("recoverable for 30 days")

### 3.4 About
`GET drive/v3/about?fields=user(displayName,emailAddress,photoLink),storageQuota(limit,usage)`
- `freeBytes(email)` = `max(0, limit - usage)`; `null` when `storageQuota`, `limit` or `usage` is missing (no `limit` = unlimited, e.g. some Workspace accounts).
- `space(email)` = `StorageSpace(name = "Google storage", used = usage, total = limit?, free = limit? - usage (>= 0))`; `null` if no quota or usage.

### 3.5 Create folder (files.create)
`POST drive/v3/files?fields=DRIVE_FILE_FIELDS&supportsAllDrives=true`, body `{"name":"<n>","mimeType":"application/vnd.google-apps.folder","parents":["<parentId>"]}`.

### 3.6 Delete permanently (files.delete)
`DELETE drive/v3/files/{id}?supportsAllDrives=true` → 204. Non-2xx: 403 → `"Only the owner of this file can delete it permanently"`, else `"Delete failed (HTTP {code})"`.

### 3.7 Download (alt=media)
`GET https://www.googleapis.com/drive/v3/files/{id}?alt=media&supportsAllDrives=true` (auth header). Read with `HttpCompletionOption.ResponseHeadersRead`;
length = `Content-Length` or -1. Errors:
- 403 → `"Google Drive refused the download (it may have hit its daily download limit, or be flagged by Google)."`
- 404 → `"The file is no longer in Google Drive."`
- other → `"Download failed (HTTP {code})."`

Player uses the same URL with `Range` requests (player spec).

### 3.8 Resumable upload — exact protocol (`DriveRepository.upload`)

Inputs: `email, parentId, name, mimeType, size (bytes, or -1 = unknown), open() -> Stream, onProgress(sent, total)`.

1. **Start session**
   ```
   POST https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields=<DRIVE_FILE_FIELDS>
   Authorization: Bearer …
   X-Upload-Content-Type: <mimeType>
   X-Upload-Content-Length: <size>                (only when size >= 0)
   Content-Type: application/json; charset=UTF-8
   {"name":"<name>","mimeType":"<mimeType>","parents":["<parentId>"]}
   ```
   Non-2xx → error (see 6 below) with prefix `"Upload could not start"`. Session URL = `Location` response header; missing →
   `"Drive did not return an upload session"`.
2. **Chunks.** `CHUNK_SIZE = 8 * 1024 * 1024` (8 MiB; a multiple of 256 KiB as Drive requires). Loop:
   - `read = readChunk(buffer)`: keeps reading until the 8 MiB buffer is full or the stream ends; returns -1 if it read 0 bytes.
   - `last = read < CHUNK_SIZE` (a short or empty chunk only happens at end of stream), `count = max(read, 0)`.
   - `total` = `size` if known; else if `last` → `offset + count`; else `*`.
   - `Content-Range` = `count == 0` ? `bytes */{total}` : `bytes {offset}-{offset+count-1}/{total}`.
   - `PUT <session URL>` with that header and the `count` bytes as body (no content type; `Content-Length: count`), auth header included.
   - Response **308** (Resume Incomplete): if `last` → throw `"File ended before upload completed"`; else `offset += count`, `onProgress(offset, size)`.
   - Response **2xx**: `onProgress(offset + count, size)`; parse body as `DriveFile` and return it.
   - Other → error with prefix `"Upload failed"`.
3. Exact sequences (from `DriveStreamingUploadTest`, port these as xUnit tests against a fake handler):
   - unknown size, `2*CHUNK + 12345` bytes → `bytes 0-8388607/*`, `bytes 8388608-16777215/*`, `bytes 16777216-16789560/16789561`.
   - unknown size, exactly `CHUNK` bytes → `bytes 0-8388607/*`, then `bytes */8388608` (empty final PUT).
   - known size `CHUNK + 10` → `bytes 0-8388607/8388618`, `bytes 8388608-8388617/8388618`.
   - ZIP entries piped straight into uploads must arrive byte-identical.
   - 403 with body containing `storageQuotaExceeded` → `DriveStorageFullException`; 403 `insufficientFilePermissions` → plain `IOException`.
4. **Errors (`uploadError`)**: read body; `403 && body contains "storageQuotaExceeded"` → `DriveStorageFullException` (message `"Google Drive is full"`);
   else `IOException("{what} (HTTP {code})")`.
5. **Retries.** There is **no per-chunk retry and no session resume** inside `upload`; the 308 response's `Range` header is not read (it assumes the whole
   chunk was stored). Retries happen at job level by starting a **new session from byte 0**: UploadWorker up to 3 attempts, ExtractWorker up to 4 (section 7/8).
   [W] Optional improvement, safe because it doesn't change the wire format for the happy path: on a network exception mid-chunk, query
   `PUT <session>` with `Content-Range: bytes */{total-or-*}` and resume from the `Range: bytes=0-N` the 308 returns (requires re-reading the
   unsent bytes, so only possible for seekable sources such as local files — not for the ZIP stream unless the current 8 MiB buffer is still held).
6. **[!] .NET gotchas:**
   - `HttpClientHandler`/`SocketsHttpHandler` treat **308 as a redirect** when a `Location` header is present. Use `AllowAutoRedirect = false` on the
     Drive upload client (and check `(int)response.StatusCode == 308` explicitly).
   - Timeouts (Android): base connect 20 s / read 30 s; Drive client read 60 s / write 60 s; media client read 45 s. In .NET set
     `SocketsHttpHandler.ConnectTimeout = 20 s`, `HttpClient.Timeout = Infinite` for downloads/uploads and enforce idle-read timeouts with a
     per-operation `CancellationTokenSource` reset on each successful read/chunk (60 s), otherwise a 2 GB download would hit `HttpClient.Timeout`.

---

## 4. Connectivity (offline mode) [A → W]

[A] `Connectivity.online` = default network has `NET_CAPABILITY_INTERNET` **and** `NET_CAPABILITY_VALIDATED` (Wi-Fi without internet = offline).
Updated by a network callback; exposed as a state flow + `isOnline`.

[W] Windows: `Windows.Networking.Connectivity.NetworkInformation.GetInternetConnectionProfile()?.GetNetworkConnectivityLevel() == NetworkConnectivityLevel.InternetAccess`
(this is NCSI-validated, the equivalent of VALIDATED), re-evaluated on `NetworkInformation.NetworkStatusChanged` (marshal to UI thread, debounce
~1 s). Fallback for non-WinRT TFMs: `NetworkListManager` COM (`INetworkListManager.IsConnectedToInternet`). Expose `IObservable<bool>`/`INotifyPropertyChanged Online`
and `bool IsOnline`.

Used for: offline library filtering; Files shows the offline state for any non-device source; scans skip non-device folders and TMDB; a
transition offline → online triggers a rescan (section 9); artwork prefetch only when online.

[W] "Only on Wi-Fi" for extraction maps to "not metered": `ConnectionProfile.GetConnectionCost().NetworkCostType == Unrestricted` (or `Unknown`).
Suggested Windows label: "Only on unmetered networks" — or keep "Only on Wi-Fi" and check `IsWlanConnectionProfile || IsWwanConnectionProfile == false`. Decide; default checked.

---

## 5. Storage facade

### 5.1 API [A]

```csharp
record StorageSpace(string Name, long Used, long? Total, long? Free);   // Total/Free null = unknown or unlimited

interface IStorage {
    bool IsLocal(string? account);            // account == "device"
    bool IsSmb(string? account);              // starts with "smb://"
    string RootId(string account);            // "device-root" | account (smb) | "root"
    string RootName(string account);          // "This device" | server name ?? host | "My Drive"
    Task<IReadOnlyList<DriveFile>> ListAsync(string account, string folderId, string orderBy = "folder,name_natural", CancellationToken ct = default);
    Task<IReadOnlyList<DriveFile>> SearchAsync(string account, string query, string currentFolder, CancellationToken ct = default);
    Task<string> RenameAsync(string account, string id, string newName);       // returns the id afterwards (may change)
    Task RemoveAsync(string account, string id);                               // Drive: trash; device/SMB: permanent delete
    Task DeletePermanentlyAsync(string account, string id);                    // Drive: files.delete; device/SMB: same as Remove
    Task MoveAsync(string account, string id, string? fromParent, string toParent);
    Task CreateFolderAsync(string account, string parentId, string name);
    Task<T> ReadAsync<T>(string account, string id, Func<Stream, Task<T>> block);  // whole small file, e.g. subtitles
    Task<StorageSpace?> SpaceAsync(string account, string folderId);
    string? SpaceKey(string account, string folderId);                         // same key ⇒ same space; null ⇒ don't show
}
```

All sources return items as the Drive model (`DriveFile`): `id, name, mimeType (folders = application/vnd.google-apps.folder), size (string), modifiedTime (ISO-8601),
parents, videoMediaMetadata?, fileExtension?, capabilities?`. `sizeBytes = long.TryParse(size) ?: 0`. Capabilities defaults when absent:
`canRename = true, canTrash = true, canDelete = false, canAddChildren = true`.

### 5.2 Semantics per source [A]

| Operation | Drive | Device (Android SAF) | SMB |
|---|---|---|---|
| list | 3.1 children, `orderBy` passed | `device-root` → granted folder roots sorted by lowercase name; else children (`parents=[folderId]`) | `smb.list(folderId)` |
| search | whole account, 3.1 search (200 max) | `list(currentFolder)` filtered by `name.Contains(query, IgnoreCase)` (current folder only, not recursive) | same as device |
| rename | PATCH name → same id | rename, **returns new id** | rename → new id (path changes) |
| remove | **trash** | **permanent** delete | **permanent** (no trash) |
| deletePermanently | DELETE (owner only; folder takes contents) | same as remove | same as remove |
| move | PATCH add/removeParents | move; needs `fromParent` (error `"Unknown source folder"` if null); unsupported → `"This storage doesn't support moving files between these folders"` | `smb.move(id, toParent)` |
| createFolder | create folder | create dir; failure `"Couldn't create the folder here"` | create dir |
| read | download stream | open stream | smb read |
| space | `drive.space(account)` (Google storage) | volume of the folder via StatFs, name "Internal storage"/volume label | share size |
| spaceKey | `account` | volume path or null | `"{host}/{share}"` or null (server root) |

Device errors: listing a missing folder → `"This folder isn't available. If it's on an SD card or USB drive, make sure it's connected."`;
delete failure → `"Couldn't delete it"`; adopt failure → `"That folder isn't available"`; open failure → `"This file isn't available"`.
TV media library ids are read-only (`"Files in the TV's media library can't be changed from here"`) — not needed on Windows.

### 5.3 Windows "device" source [W]

- Keep account id `"device"` and root id `"device-root"` (DB compatibility with exported data/other specs). Ids = absolute normalized paths (`Path.GetFullPath`, no trailing separator).
- Granted folders = user-picked folders persisted in settings/DB (no OS permission model). Picker: `Microsoft.Win32.OpenFolderDialog` (WPF, .NET 8+).
  Android refuses whole internal storage / Download root ("Can't use this folder"); on Windows refuse drive roots? — decision; recommended: allow.
- Display name: Android says "This device" and subtitle "Phone storage, SD card and USB". Suggested Windows: "This PC" / "Folders on this PC, external drives and USB". (Decide once; the strings appear in Files, Settings, onboarding.)
- list: `DirectoryInfo.EnumerateFileSystemInfos()` (skip hidden/system), map `Length`, `LastWriteTimeUtc` → ISO string, `parents=[folderId]`,
  capabilities from attributes (read-only → `canRename/canTrash/canDelete = false`).
- rename: `File.Move`/`Directory.Move` within the same parent; return new path. move: `File.Move(src, Path.Combine(dst, name))`; `Directory.Move`
  across volumes throws `IOException` → map to `"This storage doesn't support moving files between these folders"`.
- delete: **permanent** (`File.Delete` / `Directory.Delete(recursive: true)`), matching Android and the dialogs. [!] Recycle Bin
  (`Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(..., RecycleOption.SendToRecycleBin)`) would be friendlier but then the "deleted permanently…
  can't be undone" dialog text must change — product decision, default to Android behaviour.
- space: `new DriveInfo(Path.GetPathRoot(folder))` → `Name = VolumeLabel` (fallback "Local Disk (C:)"), `Total = TotalSize`, `Free = AvailableFreeSpace`,
  `Used = Total - Free`; spaceKey = path root. Network-mapped drives: `DriveInfo` works too.
- After rename/move the id changes → scanner must forget old ids and rescan (section 6.4), exactly as on Android.

---

## 6. Files screen (port of `FilesScreen` + `FilesViewModel`)

### 6.1 State [A]

`FilesState { account, sharedRoot=false, stack=[Crumb(rootId, rootName)], items, loading=true, refreshing=false, error, sort=Name, selection:Set<id>, searchQuery:string? (null = search closed), space }`.
`current = stack.Last()`, `atSharedRoot = sharedRoot && stack.Count == 1`, `selecting = selection.Any()`.

- Accounts list observed; if current account is null or disappears, select the first account; none → empty "Nothing connected yet" screen.
- `selectAccount(email)`: reset to a fresh state (keep `sort`), stack `[Crumb(rootId, rootName)]`, reset space key, load.
- `setSharedRoot(shared)`: stack `[Crumb("shared","Shared with me")]` or `[Crumb("root","My Drive")]`, clear selection and search, load.
- `open(folder)`: push crumb, clear selection/search, load. `goTo(index)`: truncate stack. Breadcrumb click → `goTo`.
- **Back** (Esc / Back mouse button / Alt+Left on Windows): selection → clear; else search open → close search; else stack > 1 → up one level; else not handled.
- **Load**: cancel previous load; `loading = !refresh`, `refreshing = refresh`, clear error; refresh space (6.6). Items:
  search open with `query.Length >= 2` → `storage.Search(account, query, current.id)`; at shared root → `listSharedWithMe`; else `storage.List(account, current.id)`.
  **Keep only useful items**: folders, videos (`isVideo(name, mime)` = extension in VIDEO set, or `video/*` mime with an extension; or any `video/*` mime),
  subtitles (`srt vtt ass ssa ttml dfxp`), and archives (`.zip`). Error → `error = message ?? "Couldn't load this folder"`.
  VIDEO set: `mkv mp4 m4v avi mov wmv flv webm ts m2ts mts mpg mpeg 3gp ogv vob divx rmvb asf f4v mxf`.
- **Search typing**: `setSearch(q)`: set; if `q == null` reload folder; else reload only when `q.Length >= 2` (no debounce on Android; [W] add ~300 ms debounce).
- **Sort** (`FileSort`): "Name" (case-insensitive ascending), "Last modified" (`modifiedTime` descending, string compare of ISO), "Size" (descending).
  Folders always first, each group sorted the same way. Default Name. Sorting is client-side.
- Reload the open folder (refresh) when: an upload whose parent is the open folder succeeds; any extraction succeeds; coming back online (non-device source).

### 6.2 Header and layout [A]

- Title "Files"; below it the account switcher text: `"This device"` / server name / email, followed by `"  ▾"` (two spaces). Click → menu listing every
  account (name, subtitle = `accountSubtitle`, avatar; check-circle on the current one), plus "Files on this device" if no device account exists
  (calls `ensureDeviceAccount` then selects it).
  - `accountSubtitle`: device → "Phone storage, SD card and USB"; SMB → "Network server · {host}"; Google → email.
  - Avatar: Google = first letter of display name in a circle; device = phone icon; SMB = server (Dns) icon.
- Search button (tooltip "Search Drive" for Drive, "Search this folder" otherwise) toggles search (`""` ↔ `null`).
  Search field label: "Search this Drive" (Drive) / "Search this folder"; max width 720.
- Sort button (tooltip "Sort") → menu "Name", "Last modified", "Size" (current one in amber).
- When search is closed: chips "My Drive" / "Shared with me" (Drive and online only); breadcrumbs (hidden when offline); storage summary (hidden offline).
- Pull-to-refresh → `load(refresh: true)`. [W] F5 and a Refresh button.
- List: adaptive grid of rows, min column width 360 (one column on narrow windows), bottom padding 120 for the FAB.

### 6.3 Selection (multi-select) [A]

- Long-press toggles selection (Windows: Ctrl+click / Shift+click range / checkbox on hover, and Ctrl+A); while selecting, click toggles.
- Selection bar replaces the header: close icon ("Cancel selection"), "{n} selected", Move icon ("Move"), Delete icon in danger colour with tooltip
  "Delete" (device/SMB) or "Move to trash" (Drive) → Trash dialog with label `"{n} items"`; Drive only and only if **every** selected item has
  `capabilities.canDelete == true`: DeleteForever icon ("Delete permanently") → DeleteForever dialog with label `"{n} items"`, `hasFolder = any selected is folder`.
- Row checkbox look: selected row background AmberDim, icon replaced by a check-circle.

### 6.4 Row and its menu [A]

Row: 44×44 icon tile (folder amber, video, subtitles, ZIP amber-soft, image, generic file), name (1 line ellipsis), second line:
optional pill "Movies library" / "TV library" (folder is a library folder), then `"{size} · {Mon d, yyyy}"` (size omitted for folders; size via `Format.bytes`).

Click: selecting → toggle; folder → open; video → play (`playFile(id, account, title = name)`); `.zip` on Drive → Extract dialog; else Details dialog.

"More" (⋮) menu, hidden while selecting; items in order and conditions:
1. "Play" — video.
2. "Use as Movies library" / "Use as TV library" — folder not already a library folder → `setLibrary` → snackbar `"{name} added to your Movies library"` / `"… TV Shows library"`, then scan.
3. "Rename" — `capabilities.canRename != false`.
4. "Move" — `movable`.
5. "Extract to Drive" — `.zip` and source is Drive (not device, not SMB).
6. "Details".
7. "Delete" (device/SMB) or "Move to trash" (Drive), danger colour — `capabilities.canTrash != false && movable`.
8. "Delete permanently", danger colour — Drive && `canDelete == true` && `movable`.

`movable = !(permanent && stack.Count == 1)` where `permanent = device || SMB` (device root lists granted folders; a server's root lists shares — neither can be moved or deleted).

Side effects after operations (keep exactly; they keep the library consistent):
- rename: new id == old → `scanner.onFileRenamed(id, newName)` and, if folder, background rescan; new id != old → `scanner.onFilesRemoved([oldId])` + rescan. Name is trimmed.
- trash/delete: delete each id in sequence, `scanner.onFilesRemoved(ids)`, clear selection, rescan if any was a folder.
- move: for each id `storage.Move(account, id, parentsById[id] ?? current.id, target.id)`; device/SMB → `onFilesRemoved(ids)`; clear selection; always rescan.
- create folder: `storage.CreateFolder(account, current.id, name.Trim())`.
- Every mutation then refreshes the folder. Errors → snackbar `e.Message ?? "Something went wrong"`.

### 6.5 Dialogs — exact text [A]

**Rename** — title "Rename", field pre-filled with the name, for files the base name (before the last `.`) is pre-selected; buttons "Rename" (disabled when blank) / "Cancel".
**New folder** — title "New folder", empty field, buttons "Create" / "Cancel". Snackbar "Folder created".

**Trash / Delete** (`FileDialog.Trash(ids, label)`; label = file name or `"{n} items"`):
- Title: device/SMB "Delete permanently?" ; Drive "Move to trash?"
- Text:
  - device: `"\"{label}\" will be deleted permanently from this device. This can't be undone."`
  - SMB: `"\"{label}\" will be deleted permanently from {serverName ?? "the server"}. Network shares have no trash, so this can't be undone."`
  - Drive: `"\"{label}\" will be moved to Google Drive's trash. You can restore it from Drive for 30 days."`
- Confirm (danger): "Delete" (device/SMB) / "Move to trash" (Drive). Dismiss: "Cancel".
- Snackbar: device/SMB `"Deleted 1 item"` / `"Deleted {n} items"`; Drive `"Moved to trash"` (1) / `"{n} items moved to trash"`.

**Delete permanently** (Drive only):
- Title "Delete permanently?"
- Text: `"\"{label}\"" + (hasFolder ? " and everything in it" : "") + " will be deleted from Google Drive right away. It won't go to the trash, so this can't be undone."`
- Confirm "Delete" (danger) / "Cancel". Snackbar `"Deleted 1 item"` / `"Deleted {n} items"`.

**Move** — full-screen folder picker (6.7) titled "Move to", one action "Move here", the items being moved are disabled (cannot be entered or picked).
Snackbar `"Moved to {target name}"`.

**Details** — title = file name (max 3 lines); lines (label column 90 wide): "Type" = mimeType; "Size" (files only); "Modified" = `MMM d, yyyy` or "—";
"Resolution" = `"{w} × {h}"` when both present; "Duration" = clock `m:ss` / `h:mm:ss`. Button "Close".

**Add to library** (after picking a device folder from Files) — `LibraryTypeDialog`: title `"What's in \"{folder}\"?"`, text
"Veltoret will scan it and match everything with TMDB.", buttons "Movies" (primary, movie icon) and "TV Shows" (secondary, TV icon), dismiss "Not now"
(Settings uses dismiss "Cancel").

**Extract** — section 8.4.

### 6.6 Storage summary [A]

Text: `storageSummary(space)` = join with `" · "` of: `name`; `"{used} used of {total}"` if total > 0 else `"{used} used"`; `"{free} free"` if free known.
Sizes via `Format.bytes` but `<= 0` shows `"0 B"`. Example: "Google storage · 4.2 GB used of 15 GB · 10.8 GB free".
Below it a 4 px flat bar (rounded 2) on Outline colour, filled `used/total` (clamped 0..1) in Amber, **Danger when ≥ 0.9**; no bar when total unknown. Max width 480.
Fetch rules: computed with `spaceKey(account, folderId)`; only fetched again when the key changes or on refresh (so browsing doesn't call `about` each time);
clears to null when the key changes; key null → nothing shown; failures → nothing shown; results discarded if account/key changed meanwhile.

`Format.bytes`: `<= 0` → "—"; units B, KB, MB, GB, TB with 1024 steps; `"%.1f"` for GB and above, `"%.0f"` below (US locale).

### 6.7 Folder picker (`DriveFolderPicker`) [A]

Used for "Move to" and "Choose a library folder". Header title + subtitle (`rootName` for device/SMB, email for Drive), close button ("Close").
Drive: chips "My Drive" / "Shared with me" (switching resets the stack to `root`/`shared`). Breadcrumbs. Lists **folders only** of the current folder
(shared root → `listSharedWithMe` folders). Disabled ids greyed and not enterable. States: loading; error → "Couldn't load folders" + message;
empty → "No subfolders" / "You can pick this folder, or go back up.". Bottom bar: `"Current folder: {name}"` and one button per action
(Settings: "Movies", "TV Shows"; Move: "Move here"). Actions disabled when at shared root, at device/SMB root, or current folder is disabled.
Optional `startAt` crumbs open below the root.

### 6.8 Empty / error / offline states [A]

| Condition | Title | Text | Action |
|---|---|---|---|
| no accounts at all | "Nothing connected yet" | "Add a folder from your phone storage, SD card or USB drive. To browse Google Drive, connect an account in Settings." | "Add a folder from this device" |
| non-device source and offline | "You're offline" | SMB: "Network servers need this device to be on their network. Folders on this device still work." ; Drive: "Google Drive needs an internet connection. Folders on this device still work." | "Show this device" |
| error | device "Couldn't open this folder" / SMB `"Couldn't reach {server ?? "the server"}"` / Drive "Couldn't reach Drive" | the error message | "Retry" |
| device root empty | "No folders yet" | "Pick a folder on your phone storage, SD card or USB drive. Veltoret only sees the folders you choose." | "Add a folder" |
| folder empty | "This folder is empty" | Drive: "Upload files or create a folder with the + button." ; else "Create a folder with the + button." | — |

[W] Replace "phone storage, SD card or USB drive" with PC wording if the device source is renamed (5.3).

### 6.9 Add (+) button and transfers [A]

FAB (58×58, rounded 18, amber, tooltip "Add") shown unless selecting, at shared root, offline (non-device), or at an SMB server root. Menu:
- device root → "Add a folder from this device" (folder picker → adopt → Add-to-library dialog); otherwise "New folder".
- Drive → also "Upload files" (multi-file picker, any type; Windows `OpenFileDialog { Multiselect = true }`).

Upload start: at shared root → snackbar "Open a folder first to upload into it"; else one job per file into `current.id`, snackbar
`"Uploading {n} file"` / `"Uploading {n} files"`.

Transfer cards stacked above the FAB (width 300): up to **2 extraction** jobs that are active or failed, then up to **3 upload** jobs that are unfinished or failed.
`TransferCard`: icon (upload cloud / unarchive; error icon when failed, check when done), title (1 line), status right-aligned: "Failed" / "Done" /
"Waiting" (enqueued or blocked) / `"{percent}%"`; optional detail (2 lines, danger colour when failed); progress bar while not finished; border danger 50% when failed.
Extraction detail: error text; succeeded → `"{n} file(s) extracted" · {zipNote} · "scanning library"` joined with `" · "`; enqueued →
"Waiting for a connection (Wi-Fi only?)"; running → `"Unpacking {current}"`.
Snackbars: extraction start `"Extracting {name} in the background"`; device folder adopt failure `e.Message ?? "Couldn't open that folder"`.

Android asks for the notification permission before uploads/extractions/scans; [W] not needed (see 7.3 for Windows notifications).

---

## 7. Uploads (`UploadWorker`) [A → W]

[A] One WorkManager job per file (tag `drive-upload`), not unique, no network constraint. Steps: read display name (fallback "Upload") and size
(-1 if unknown) and MIME (`resolver.getType` ?? `application/octet-stream`); progress 0; `drive.upload(email, parentId, name, mime, size, open = openInputStream(uri))`.
Progress reported only when the integer percent changes (`sent/total`, 0 when total unknown). Success output `{name, parent}`; failure: retry while
`runAttemptCount < 2` (so **3 attempts**, WorkManager default exponential backoff starting at 30 s), then FAILED with `error = message`.
Each retry restarts the whole upload (new session). Notification channel "Uploads": title "Uploading to Drive", text = file name, ongoing progress.

[W] Windows:
- `TransferQueue` service (singleton) running jobs on background tasks; uploads may run in parallel (Android runs them concurrently up to WorkManager's executor limit); recommend max 2 concurrent.
- MIME from extension: `mkv → video/x-matroska`, `srt → application/x-subrip`, `ass/ssa → text/x-ssa`, `vtt → text/vtt`, else a small table / `application/octet-stream`.
- Size from `FileInfo.Length` (known), so `X-Upload-Content-Length` is sent.
- Backoff 30 s, 60 s; persist the queue (`%LOCALAPPDATA%\Veltoret\transfers.json`: job id, kind, account, parent, path/zip id, options, attempt) so jobs resume after restart like WorkManager.
- Keep finished-FAILED jobs visible until dismissed (Android keeps them until WorkManager prunes) — clicking a card could dismiss it (`TransferCard.onDismiss` exists).
- On success: if parent == open folder → refresh Files.

### 7.3 Windows notifications [W]
Optional: a toast with progress for long transfers/scans (requires an AppUserModelID shortcut for unpacked apps), or a tray icon tooltip. In-app cards
are the primary UI. Keep the Android strings: "Uploading to Drive"; "Extracting {zip}"; scan titles in section 9.3.

---

## 8. ZIP extraction (`ExtractWorker`) — streaming download → unzip → upload

### 8.1 Rules (CLAUDE.md "Don't break these") [A]
- Drive only (never device or SMB sources).
- Streams download → unzip → upload with **no temp files** and never buffers the whole archive in memory or on disk.
- Keep / Trash / Delete the archive afterwards, and **only after every file was extracted**; never remove an archive that produced nothing.
- Needs free Drive space ≈ ZIP size (ZIP stays until the end; trashed files still count). The dialog checks `freeBytes` and won't start when it can't fit, unless an earlier attempt's folder exists.
- A full Drive (403 `storageQuotaExceeded`) fails at once — no retry, because each retry downloads the whole ZIP again.

### 8.2 Job [A]
Inputs: `account, zipId, zipName (default "Archive.zip"), parentId (folder holding the ZIP; Files uses file.parents[0] ?? current folder), after ∈ {Keep, Trash, Delete} (default Keep), wifiOnly`.
Unique per ZIP: unique name `extract-{zipId}`, policy KEEP (tapping Extract twice doesn't duplicate); tags `drive-extract` and `zip:{zipId}`.
Constraint: unmetered network if wifiOnly else any connection (job waits while not met → card shows "Waiting for a connection (Wi-Fi only?)").
Runs as a foreground (dataSync) job with notification channel "Extracting archives": title `"Extracting {zipName}"`, text = current file, progress.

### 8.3 Algorithm [A]
```
report(progress 0, current "Preparing…", done 0)
extracted = 0; alreadyThere = 0
folders = FolderCache(account)      // children map per folder id (name → DriveFile, listChildren with all pages), and resolved relative paths
root = folders.child(parentId, baseName(zipName))   // existing folder with that exact name is reused, else created
download(zipId) { raw, length ->
  counter = CountingStream(raw)                         // counts compressed bytes read (read/skip)
  zip = ZipInputStream(Buffered(counter, 256 KiB))
  for each entry:
    path = entry.name.Replace('\\','/').Trim('/')
    skip if entry.isDirectory or junk(path)
    dirId = folders.path(root, path before last '/' or "")   // creates missing folders; ignores "", ".", ".." segments (no escaping the root)
    fileName = path after last '/'
    existing = folders.files(dirId)[fileName]
    if existing != null && (entry.size < 0 || existing.sizeBytes == entry.size): alreadyThere++; continue   // resume: earlier run uploaded it
    report(fraction = counter.count / length (0 if length unknown), fileName, extracted)
    drive.upload(account, dirId, fileName, mimeFor(fileName), size = entry.size (-1 when unknown), open = KeepOpen(zip),
                 onProgress = report again whenever the integer percent of `fraction` changes)
    extracted++
}
// whole archive read and every file in Drive
zipNote = null
if after != Keep && extracted + alreadyThere > 0:
   try   Delete → deletePermanently(zipId), note "ZIP deleted";  Trash → trash(zipId), note "ZIP moved to trash";  then libraryRepository.forgetArchive(zipId)
   catch → note "ZIP kept: {message}"
SyncWorker.runNow()                                  // automatic background rescan
success {name, count = extracted + alreadyThere, folder = root, zipNote}
```
- `junk(path)`: starts with `__MACOSX/`, or file name starts with `._`, or equals `.DS_Store`, `Thumbs.db`, `desktop.ini`.
- `KeepOpen`: the uploader disposes the stream it opened; wrapping prevents closing the archive stream. Only the current entry's bytes are read, the next `nextEntry` skips any remainder.
- Folder names: `baseName("Show.S01.zip") = "Show.S01"` (text before the last dot).
- Duplicate names in a folder: `associateBy(name)` keeps the last one; `child()` only reuses an existing item if it is a folder.
- Progress semantics: compressed bytes consumed / ZIP length; there is no per-file percentage.

Failure handling:
- `DriveStorageFullException` → FAILED immediately, error =
  `"Google Drive is full" + (done > 0 ? " after 1 file" / " after {done} files" : "") + ". Free up space (and empty Drive's trash), then extract again: it continues where it stopped."` where `done = extracted + alreadyThere`.
- `ZipException` → FAILED (no retry) with `describeZipError`:
  - message contains "encrypt" → "This ZIP is password-protected, which isn't supported."
  - contains "compression method" or "invalid" → "This ZIP uses a compression format Android can't read. Re-create it with standard ZIP compression." ([W] say "Veltoret can't read")
  - else → `"The ZIP looks damaged or incomplete ({message})."`
- other `IOException` → retry while `runAttemptCount < 3` (**4 attempts**, exponential backoff from 30 s) — each retry re-downloads from the start but skips files already in Drive; then FAILED with message or "Network problem".
- any other exception → FAILED with message or "Extraction failed".
- Cancellation propagates (no special cleanup; partial upload sessions simply expire on Drive's side, no partial file is created).

### 8.4 Extract dialog — exact text [A]
Opened from Files (click a ZIP on Drive, or menu "Extract to Drive") and from the Archives screen. On open it fetches `freeBytes(account)` and checks
whether `parentId` already contains a **folder** named `baseName(zip)` (`resuming`). `tooBig = free != null && free < size && !resuming`.

- Icon: unarchive (amber). Title: "Extract to Google Drive?"
- `"The videos in \"{name}\" will be unpacked into a new folder named \"{baseName}\" right next to it, then added to your library."`
- (small, muted) `"Nothing is saved on this phone — the archive streams through it. It does use about {Format.bytes(size * 2)} of data (downloading and uploading once), and runs in the background."` ([W] "this PC")
- While checking: "Checking free space in Google Drive…"
- When `free` known: `"Needs about {bytes(size)} of free space in Google Drive. You have {bytes(free)} free."` + one of:
  - tooBig → `" Free up space first (Gmail and Google Photos share it), or the extraction would stop part-way."` (whole line in Danger colour)
  - resuming && free < size → `" Files from an earlier attempt are already there and are skipped, so it may fit."`
  - (unlimited/unknown quota → this line is not shown)
- Checkbox "Only on Wi-Fi" (default **on**).
- Section label "When it's done" (amber). Radio options:
  - "Keep the ZIP" (default)
  - "Move the ZIP to trash" — "Recoverable for 30 days. It keeps using space until Drive's trash is emptied."
  - "Delete the ZIP permanently" — "Frees the space now. This can't be undone."
- (faint) "The ZIP is only removed after every file inside it has been extracted successfully, so it can't make room during extraction."
- Confirm: "Extract & delete ZIP" when Delete chosen, else "Extract"; enabled only when the check finished and not tooBig. Dismiss: "Cancel".

### 8.5 Archives screen [A]
Settings → "ZIP archives". Header "Archives", subtitle "ZIP files in your library folders", back. Archives are rows found by the scanner in **Drive**
library folders (`ArchiveFileEntity: driveId, accountEmail, name, sizeBytes, parentId, relativePath`). Intro text:
"Videos inside a ZIP can't be streamed. Extracting unpacks them into a folder next to the ZIP without saving anything on this phone."
Empty: "No archives" / "When a ZIP turns up in your Movies or TV folders, it appears here so you can unpack it into Drive."
Card: ZIP icon, name (2 lines), `"{size} · {relativePath} · {account}"`; then either a TransferCard (title "Extracting" while active, else "Extraction")
for the latest job of that zip (active one preferred) when active/succeeded/failed, plus "Try again" (secondary) when failed; or the button "Extract to Drive".
Grid min column width 420.

### 8.6 Windows implementation notes [W]
- **Do not use `System.IO.Compression.ZipArchive`** on the HTTP stream: in Read mode on a non-seekable stream it copies the whole archive into memory.
  Use a forward-only reader: **SharpCompress** `ZipReader.Open(stream)` / `reader.MoveToNextEntry()` / `reader.OpenEntryStream()` (MIT; supports
  Deflate, **Deflate64** (Windows Explorer uses it for large files), BZip2, LZMA, ZIP64, data descriptors). SharpZipLib's `ZipInputStream` is the closest
  semantic match to Java but lacks Deflate64. Entry size: when the entry uses a data descriptor (general-purpose flag bit 3) the local header carries size 0, so pass
  `size = -1` (unknown) to the uploader in that case, exactly like Java's `entry.size < 0`; otherwise pass `entry.Size`. The resume check then treats any existing same-name file as done, as on Android. [!] Verify how the chosen library exposes bit 3 / unknown sizes.
- Map SharpCompress exceptions: `CryptographicException`/"encrypted" → password message; `NotSupportedException` (compression type) → format message; `InvalidFormatException`/`ZlibException`/unexpected EOF → damaged message.
- Wrap the response stream with a counting stream, then `BufferedStream(…, 256 * 1024)`.
- Entry stream → `upload(open: () => new NonClosingStream(entryStream))`.
- "Only on Wi-Fi" → wait (poll connection profile changes) until the network is unmetered, showing "Waiting".
- After success trigger an automatic background scan; Files refreshes on any extraction success.

---

## 9. Library scan scheduling and progress

### 9.1 Scheduling [A]
- **Periodic**: every **12 hours**, no network constraint (unique work `library-sync-periodic`, policy KEEP). Scheduled at app start (only when onboarding
  is complete), after onboarding, and whenever a library folder is added. WorkManager runs the first periodic instance right after it's first enqueued;
  later app starts do not trigger a scan (KEEP).
- **App start**: no scan of its own (beyond the periodic schedule).
- **Back online**: `connectivity.online` transitions (ignoring the initial value, distinct) to `true` → automatic whole-library scan if onboarding complete.
- **Automatic scans** (`runNow(folderIds = null, notify = false)`): after rename/move/delete of folders, extraction, Fix match, setting a library from Files,
  reconnect. Policy KEEP: **dropped if a scan is already queued or running**.
- **User scans** (`notify = true`: "Scan library now", Home's scan, per-folder scan, adding a folder, saving a TMDB key) and folder scans:
  policy APPEND_OR_REPLACE — **queued behind** the running scan. Shown as a foreground job with progress notification and a "Cancel" action.
- Periodic/automatic scans are plain background work without notification.
- Worker failure → retry while `runAttemptCount < 2`; cancelled scans keep what was found; a folder cut short is never treated as "files gone".
- `cancel()`: `scanner.cancel()` (stops at next checkpoint) and drop queued "now" scans.
- After a successful scan, if online and not cancelled: `ArtworkPrefetch.run()` (failures ignored).

[W] Windows: a `ScanScheduler` with a serial queue: `RequestAutomatic()` (ignored if queue non-empty or running), `RequestUser(folderIds?)` (append),
`Cancel()`. A timer every 12 h while the app runs, plus at startup run one if `now - lastPeriodicScanAt >= 12 h` (persist the timestamp) — equivalent to
the WorkManager behaviour for an app that isn't always running. Subscribe to Connectivity for the back-online trigger. Optionally a tray/background mode keeps periodic scans running when the window is closed (decision).

### 9.2 ScanState fields [A]
`running, phase, filesFound, toMatch, matched, error, lastFinishedAt, folderIds (null = whole library), foldersTotal, foldersDone, doneFolderIds, currentFolderId,
currentFolder, currentPath ("Breaking Bad/Season 2"), newFiles, identified, cancelled, folderErrors: Map<folderId, message>`.
`covers(id) = running && (folderIds == null || id in folderIds)`; `waiting(id) = covers(id) && id != currentFolderId && id ∉ doneFolderIds`;
`progress = !running → null; toMatch > 0 → matched/toMatch; foldersTotal > 1 → foldersDone/foldersTotal; else null (indeterminate)`.

### 9.3 Scan UI strings (`ScanText`, Settings, notification) [A]
- `videos(n)` = `"{n} video"` / `"{n} videos"`.
- Title: whole library → "Scanning your library"; folder scan with name → `"Scanning {currentFolder}"`; else "Scanning folder".
- Step: `toMatch > 0` → `"Matching with TMDB · {matched} of {toMatch}"`; folder known and `foldersTotal > 1` → `"Reading {folder} · folder {min(done+1,total)} of {total}"`;
  folder known → `"Reading {folder}"`; else `phase` or "Starting".
- Counts: `"{videos(filesFound)}"` + `" · {newFiles} new"` (if > 0) + `" · {identified} identified"` (if > 0).
- Idle line under "Scan library now":
  - folder errors → `"{n} folder couldn't be read. Details are under Sources."` / `"{n} folders couldn't be read. …"`
  - cancelled → `"Last scan was cancelled {relative(lastFinishedAt).lower()}"`
  - error → `"Last scan had a problem: {error}"`
  - finished this session → `"{Last scan | Folder scan | Scan of {n} folders} {relative.lower()}: {counts}"`
  - else → `"Last scanned {relative(lastScanAt).lower()}"`
- Folder line in Sources: running on this folder → `"Scanning… {currentPath or 'top folder'}"`; folder error → the error (Danger colour); waiting → `"{videos(count)} · waiting to scan"`;
  never scanned → "Not scanned yet"; else `"{videos(count)} · scanned {relative.lower()}"`.
- `Format.relative`: `<= 0` "Never"; < 1 min "Just now"; < 60 min `"{m} min ago"`; < 24 h `"{h} h ago"`; else `"{d} days ago"`.
- ScanProgress panel: spinner, title, step, "Cancel" (amber); progress bar (determinate animated 400 ms, or indeterminate); counts + `"{percent}%"` when determinate;
  current path (when not matching, faint); footer "Keeps going if you leave the app."
- Notification (channel "Library scans"): title as above; text: `toMatch > 0` → `"Matching with TMDB · {matched} of {toMatch}"`; `foldersTotal > 1` →
  `"Folder {min(done+1,total)} of {total} · {videos(found)} found"`; else `"{videos(found)} found"`; action "Cancel"; refreshed every 700 ms.

---

## 10. Settings — Sources and Library sections [A]

**Group "SOURCES"** (group titles are uppercased in amber). One panel per account:
- avatar (40), display name, `accountSubtitle`, text button "Remove" (muted).
- "No library folders yet." when empty.
- Each folder row: movie/TV icon, name, folder line (9.3), pill "Movies" / "TV", then a spinner if it is the folder being scanned, else a scan icon button
  (tooltip "Scan this folder", disabled while `waiting`) → `"Scanning \"{name}\""` snackbar + user folder scan; close icon "Remove folder" (removes immediately, no confirmation).
- Ghost button "Add library folder": device → folder picker then LibraryTypeDialog (dismiss "Cancel"); otherwise the folder picker titled
  "Choose a library folder" with actions "Movies" / "TV Shows". Adding → schedule periodic, user scan of that folder, snackbar `"Added \"{name}\" — scanning now"`.
- SMB only: ghost "Send to TV" (Android TV pairing — out of scope on Windows).

Below the panels (secondary buttons): "Add Google account" (shows a spinner while connecting), "Add network server", and "Use files on this device"
only if there is no device account.

Remove account dialog: title `"Remove {displayName}?"` for device/SMB, `"Remove {email}?"` for Google. Text:
- device: "Its folders will be removed from your library. Nothing is deleted from this device."
- SMB: "Its folders will be removed from your library and Veltoret forgets its password. Nothing is deleted from the server."
- Google: "Its folders will be removed from your library. Nothing is deleted from Google Drive."
Buttons "Remove" (danger) / "Cancel".

**Group "LIBRARY"**: running → ScanProgress; else row "Scan library now" with the idle line (sync icon). If unmatched > 0: "Unmatched files" —
`"{n} file need identifying"` / `"{n} files need identifying"`. Row "ZIP archives" — "None found in your library" / `"{n} waiting to be extracted"` → Archives screen.

[W] Add a "Google sign-in" sub-panel (client import status, "Import client file", "Change") — needed only on Windows; and show "Reconnect" on an account
whose refresh token was rejected (`AuthRequiredException`), calling the flow with `login_hint`. Android's `reconnect(email)` exists in `AccountConnector` for the same purpose.

---

## 11. Artwork prefetch [A]

After each online, non-cancelled scan, download into the image disk cache every URL the screens use, skipping URLs already cached
(the cache is keyed by URL). TMDB base `https://image.tmdb.org/t/p/{size}{path}`:

| Item | Sizes prefetched | Used by |
|---|---|---|
| Movie & show poster | `w342` (default) and `w500` | grids/rows/search; detail page |
| Movie & show backdrop | `w1280` (default) and `w780` | detail/featured/TV backdrop; Continue Watching |
| Episode still | `w300` | only for shows with at least one **device** episode (`deviceEpisodes > 0`) |

(`profile` default `w185` is **not** prefetched.) Android decodes at 32×32 with memory cache disabled — only the downloaded bytes matter.
Disk cache: 512 MB fixed (`cacheDir/image_cache`).

[W] Windows: a URL-keyed disk cache at `%LOCALAPPDATA%\Veltoret\image_cache` (file name = SHA-256 of URL), LRU-trimmed to 512 MB, shared with the
image loading used by the screens so offline artwork works. Prefetch downloads sequentially (or 4 at a time) without decoding. **Any screen that changes an
image size must update the prefetch list** (CLAUDE.md rule).

---

## 12. Test plan to port

- `DriveStreamingUploadTest` (all six cases in 3.8) against a fake `HttpMessageHandler` that: answers the POST with 200 + `Location`; records each PUT's
  `Content-Range` and body; returns 200 `{"id":"f1",...}` once total is known and reached, else 308; and can be switched to refuse with a given status/body.
- ZIP: build an in-memory ZIP with `Season 1/S01E01.mkv` (CHUNK + 500 bytes) and `Season 1/S01E02.mkv` (3000 bytes), read it with the forward-only reader
  through a non-seekable wrapper, upload each entry, assert byte equality. Add: junk entries skipped, `..` segments ignored, resume skips existing same-size files,
  Keep/Trash/Delete not applied when nothing was extracted, quota error fails without retry.
- OAuth: PKCE challenge = base64url(SHA256(verifier)) without padding; state mismatch rejected; refresh `invalid_grant` → `AuthRequiredException` and stored token deleted; 401 → one retry with a fresh token.
- Storage summary formatting and the ≥ 90% danger threshold; `Format.bytes` examples.
