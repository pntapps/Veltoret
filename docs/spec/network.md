# Network spec: SMB shares, Play on TV, Send to TV, Chromecast

Porting spec for the Windows app (C# / .NET 10 / WPF). It covers the Android sources under
`data/smb`, `data/tvlink`, `data/pairing`, `player/cast`, `player/SmbDataSource.kt`,
`player/LinkDataSource.kt`, `ui/settings/AddServerViewModel.kt` and `ui/settings/NetworkServers.kt`, plus
the unit tests `SmbPathTest`, `SmbDiscoveryTest`, `PairingCryptoTest`, `TvLinkTest`, `CastTest` and
`CastAudioTest`.

**Interop rule.** The Windows app must work with the **unchanged** Android TV app. Everything marked
**WIRE** has to match byte for byte: packet layouts, HTTP framing, JSON field names, crypto parameters and
canonical strings. Anything not marked WIRE is local behavior and only needs to match in effect.

Role of the Windows app: it is the **phone side** of every protocol. It is the TvLink client, the Send to
TV sender, the CastServer streamer and the Chromecast sender. The TV-side server behavior is still written
out below, because the client has to produce exactly what that server accepts.

---

## 0. Shared conventions

### 0.1 JSON (WIRE)
Android uses a single kotlinx.serialization `Json` with these settings:
```
ignoreUnknownKeys = true
explicitNulls     = false   // nulls are NOT written; a missing nullable field reads as null
coerceInputValues = true    // a null or unknown value for a non-null field falls back to its default
encodeDefaults    = false   // (kotlinx default) a field equal to its default value is NOT written
```
What this means for C# (`System.Text.Json`):
- Property names are **camelCase** and identical to the Kotlin names listed below. Use
  `JsonNamingPolicy.CamelCase` or explicit `[JsonPropertyName]`.
- **Writing:** `DefaultIgnoreCondition = WhenWritingNull`. Always write the required fields, the ones
  with no default (marked *req* below). Writing default-valued fields is harmless, since the TV ignores
  nothing it knows.
- **Reading:** the TV **omits** every field that equals its default. `LinkStatus(active=false)` is sent as
  `{}`, and `LinkReply(ok=true)` as `{"ok":true}`. Every C# DTO property needs a default that matches the
  Kotlin default (`false`, `""`, `0`, empty list, `null`). Set `PropertyNameCaseInsensitive = false` and
  ignore unknown members.
- Body encoding is UTF-8 with no BOM.

### 0.2 HTTP framing used by all Veltoret mini-servers (WIRE)
The TV-side servers (`TvLinkServer`, `PhoneSetupServer`) and the phone-side `CastServer` are hand-rolled
HTTP/1.1 over raw sockets.

Request as the Android clients send it. Copy it exactly; `HttpClient` also works, see the note below.
```
<METHOD> <path> HTTP/1.1\r\n
Host: <host>:<port>\r\n
Connection: close\r\n
[X-Veltoret-Phone: ...\r\n X-Veltoret-Time: ...\r\n X-Veltoret-Signature: ...\r\n]   (signed only)
[Content-Type: application/json\r\nContent-Length: <n>\r\n]                          (when a body is sent, even if n = 0)
\r\n
<body bytes>
```
How the server parses it:
- It reads the head byte by byte until it sees `\r\n\r\n`. The head may be **at most 8 KiB**.
- The request line is split on `' '`, then `method = [0]` and `target = [1]`. The query string is
  dropped (`substringBefore('?')`).
- Header names are **lowercased**, and values are trimmed.
- The body is exactly `content-length` bytes; a missing header means 0. The limit is **64 KiB** for
  TvLink and **16 KiB** for PhoneSetup. Anything larger gets the connection closed with no response.
- Socket read timeout is 15 s.
- Only clients with **site-local, link-local or loopback** addresses are answered (Java
  `isSiteLocalAddress` / `isLinkLocalAddress` / `isLoopbackAddress`: 10/8, 172.16/12, 192.168/16,
  169.254/16, fe80::/10, fec0::/10, 127/8, ::1). Any other address gets the socket closed with no reply.

Response:
```
HTTP/1.1 <code> <reason>\r\n
Content-Type: application/json; charset=utf-8\r\n      (PhoneSetup 404 uses text/plain; the QR page uses text/html; charset=utf-8)
Content-Length: <n>\r\n
Cache-Control: no-store\r\n
Connection: close\r\n
\r\n
<body>
```
The Android client reads until EOF, takes the status from line 1 (split on `' '`, element 1), and takes the
body as everything after the first `\r\n\r\n`, decoded as UTF-8.

**C# note.** `HttpClient` against `http://ip:port` works, because Windows has no cleartext block. The
Android "plain socket" rule exists only because Android blocks cleartext OkHttp. Requirements if you use
`HttpClient`:
- Send `Connection: close`, or let it pool; the server closes after every reply anyway.
- Send `Content-Length` (use `ByteArrayContent`, never chunked). The TV ignores `Transfer-Encoding` and
  would read a 0-byte body.
- `Expect: 100-continue` must be **off** (`DefaultRequestHeaders.ExpectContinue = false`). The TV never
  sends a 100 response.
- Sign over the exact bytes you put in the content.

A raw `TcpClient` implementation that mirrors Android is about 40 lines and the safest choice.

### 0.3 Base64 (WIRE)
Standard alphabet **with padding** (`java.util.Base64.getEncoder()`), no line breaks. C#:
`Convert.ToBase64String` / `Convert.FromBase64String`.

### 0.4 Home-network check (CastServer variant)
`isSiteLocal || isLinkLocal || isLoopback ||` IPv6 ULA `fc00::/7` (`(addr[0] & 0xFE) == 0xFC` for
16-byte addresses). Test vectors (`CastTest.onlyHomeNetworkClients`):
- Accepted: 192.168.0.125, 10.0.0.7, 127.0.0.1, fd12:3456::1.
- Rejected: 8.8.8.8, 2001:4860:4860::8888.

C#: `IPAddress.IsLoopback`, `IsIPv6LinkLocal`, `IsIPv6SiteLocal`, `IsIPv6UniqueLocal` (.NET 6+), plus
manual IPv4 range checks. Map IPv4-mapped IPv6 back to IPv4 first (`MapToIPv4`).

---

## 1. SMB network shares

### 1.1 Ids and paths (`SmbPath`): local format, but persisted and used as library primary keys

**Id format** (also the media URI the player opens):
| Thing | Id |
|---|---|
| Server (lists its shares) | `smb://host` |
| Share | `smb://host/share` |
| Anything in a share | `smb://host/share/seg1/seg2/file.mkv` |

- Scheme constant: `smb://`. `isSmb(id) = id != null && id.StartsWith("smb://")` (ordinal,
  case-sensitive).
- The **host is always lowercased.** Share and segment names keep the server's case.
- Ids are **not URL-encoded**: spaces and parentheses stay raw, as in
  `smb://192.168.0.10/h/Movies/Heat (1995).mkv`.
- `id` is built as `"smb://" + host`, then, when share is not null, `"/" + share`, then each segment as
  `"/" + seg`.
- `sharePath` = segments joined with `\` (`"Movies\\Heat (1995).mkv"`). For the share itself it is `""`.
- `name` = last segment, else share, else host.
- `parent` = drop the last segment. With no segments, drop the share. A server has no parent.
- `child(n)` = sets the share if share is null, else appends a segment.
- **Account id** of a server: `"smb://" + host.Trim().ToLowerInvariant()` (`account(" NAS ") == "smb://nas"`).

`parse(id)` for ids:
1. Require the `smb://` prefix.
2. Strip it, split on `/`, and drop empty parts.
3. Require at least 1 part.
4. `host = parts[0].ToLowerInvariant()`, `share = parts[1]` or null, `segments = parts[2..]`.

`fromUserInput(text)` for typed or pasted addresses:
1. `cleaned = text.Trim()`. Remove the prefix `"smb:"` (**case-sensitive**, `"SMB://"` is *not*
   stripped). Replace every `\` with `/`, then trim `/` from both ends.
2. Split on `/`, trim each part, and drop empty parts.
3. `host = first.ToLowerInvariant()`. If there is no first part, or the host contains any whitespace,
   return null.
4. `share = parts[1]` or null, `segments = parts[2..]`.

Test vectors (`SmbPathTest`):
```
\\192.168.0.10\h\My Movies   -> host 192.168.0.10, share h, segments [My Movies]
smb://NAS/Media/Films/        -> (nas, Media, [Films])
" 192.168.0.10/share "        -> (192.168.0.10, share, [])
router                        -> (router, null, [])
"   " / "\\"                  -> null
SmbPath(192.168.0.10,h,[Movies,Heat (1995).mkv]).id == smb://192.168.0.10/h/Movies/Heat (1995).mkv ; parse(id) round-trips
smb://nas  .child(Media).sharePath == "" ; .child(Media).child(TV).id == smb://nas/Media/TV
parent(smb://nas/Media/TV) == smb://nas/Media ; parent(smb://nas/Media) == smb://nas ; parent(smb://nas) == null
isSmb("smb://nas/Media") true ; isSmb("device") false ; isSmb(null) false
```
Windows mapping: `smb://host/share/a/b` maps to UNC `\\host\share\a\b`. Keep the `smb://` id as the
stored key, so the library DB stays compatible and the ids the TV understands stay identical. TvLink
`/play` sends `fileId`, and the TV plays the same file when **its** library has that exact id, so a
Windows `smb://` id must be built exactly like Android's.

Renaming or moving changes the id (forget the old one and rescan). Deleting on a share is permanent, with
no trash, and the UI must say so. ZIP extract and upload are Drive-only and never offered for `smb://`.

### 1.2 Discovery (`SmbDiscovery`): runs the mDNS browse and the subnet sweep in parallel and streams results

The flow completes when both halves finish. It only runs on a Wi-Fi or Ethernet network with an IPv4
address. It returns nothing on mobile data or with no network.

**Local network selection.** Take the active network first, then all networks. Keep the first one with
transport Wi-Fi or Ethernet and an IPv4 link address. Record `ownAddress`, `prefixLength` and `gateway`
(the IPv4 gateway of the default route).
Windows: `NetworkInterface.GetAllNetworkInterfaces()`, filtered to `OperationalStatus.Up`, type
`Wireless80211` or `Ethernet` (also `GigabitEthernet` and similar). Skip loopback, tunnel and virtual
adapters (Hyper-V, VPN, WSL) where possible. Prefer the interface that has a default gateway. Take the
`UnicastIPAddressInformation` with `AddressFamily.InterNetwork` and its `PrefixLength`, and the IPv4
`GatewayAddresses` entry.

**A) mDNS / DNS-SD**
- Browse service type `_smb._tcp` (`"_smb._tcp."`, domain `local`).
- Browse window: **5,000 ms**, then stop.
- Resolve each instance, one at a time (mutex), with a **3,000 ms** timeout per resolve. Use the first
  IPv4 address.
- Emit `FoundServer(address = ipv4, name = serviceInstanceName, isRouter = false)`.
- If browsing fails to start, the half ends quietly.

**B) Subnet sweep on TCP 445**
- `subnetHosts(own, prefix)`: `bits = prefix if 22 <= prefix <= 30, else 24`.
  `mask = -1 << (32-bits)`, `base = own & mask`, `size = 1 << (32-bits)`. The hosts are
  `base+1 .. base+size-2`, so the network and broadcast addresses are excluded. Skip `own`.
- Test vectors: 192.168.0.57/24 gives 254 hosts, first .1 and last .254. 10.1.2.3/8 falls back to /24,
  giving 254 hosts with the first 10.1.2.1. A /22 gives 1022 hosts.
- Up to **64 concurrent** probes (semaphore).
- Probe: TCP connect to `host:445` with a **400 ms** connect timeout. Success means the server accepts
  SMB.
- For each hit, look up the NetBIOS name (below). Emit `FoundServer(address, netbiosName or null,
  isRouter = address == gateway)`.

**NetBIOS node-status query** (WIRE: the format the servers expect), UDP to `host:137`, receive timeout
**700 ms**, receive buffer 1024 bytes. The transaction id is `(nanoTime & 0x7FFF)` (any value works).

Request, 50 bytes:
```
off  len  value
0    2    transaction id, big-endian
2    2    0x0000 flags (no broadcast, no recursion)
4    2    0x0001 QDCOUNT
6    6    0x00 (AN/NS/AR counts)
12   1    0x20 (encoded name length 32)
13   32   "CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"   ("*" + 15 NULs, each byte -> 'A'+hi nibble, 'A'+lo nibble)
45   1    0x00 (end of name)
46   2    0x0021 (type NBSTAT)
48   2    0x0001 (class IN)
```
Test vector: `nodeStatusQuery(0x1234)` gives size 50, `q[0] == 0x12`, `q[12] == 32`, bytes 13..44 equal to
`CKAAAA…A` (32 chars), `q[47] == 0x21`.

Reply parse:
1. `offset = 12`. Skip the answer name: while `data[offset] != 0`, `offset += data[offset] + 1`.
2. Then `offset += 1 + 2 + 2 + 4 + 2`: the terminating 0, type, class, TTL and RDLENGTH.
3. `count = data[offset]`, then `offset++`.
4. Each entry is 18 bytes: 15 bytes of name (ASCII, `Trim()`), 1 byte suffix, 2 bytes flags. The entry
   is a group name if `flags[0] & 0x80`. Entries that would run past the received length are skipped.
5. Keep unique (non-group) entries with non-empty names. Return the first with suffix **0x20** (file
   server). Failing that, return the first with suffix **0x00** (workstation). Failing that, null.
6. Any exception returns null.

Test vectors:
- `[WORKGROUP/0x00/group, ROUTER-AX/0x00, ROUTER-AX/0x20]` gives `ROUTER-AX`.
- `[HOME/0x20/group, NAS/0x00]` gives `NAS`.
- `[WORKGROUP/0x00/group]` gives null.
- A 5-byte buffer gives null.

`nameOf(address)` runs the same query for a typed numeric address.

On Windows, sending to UDP 137 from an ephemeral port works even though NetBT owns 137 locally.
`nbtstat -A` is not needed.

**Merging** (`AddServerViewModel.scan`):
- Results are keyed by `address`. A duplicate keeps one row: `name = existing.name ?? new.name`, and
  `isRouter = existing || new`.
- Sort order: routers first, then rows with a name, then by address string (ordinal).
- Display label: `name`, else `"Your router"` for the gateway, else `"File server"`. The subtitle is
  `"<ip> · router"` for the gateway, else `<ip>`.
- The scan starts automatically when the dialog opens. "Scan again" re-runs it.

Windows mDNS options:
- Win32 `DnsServiceBrowse` / `DnsServiceResolve` (dnsapi.dll, Windows 10 1903+). This needs no extra
  dependency and coexists with the OS mDNS responder on UDP 5353.
- **Makaretu.Dns.Multicast** / `Makaretu.Dns.Multicast.New` (MIT).
- **Zeroconf** (novotnyllc, MIT).

### 1.3 Server record and login (`SmbServer`, `SmbStorage`)
```
SmbServer { host: string (lowercased), port: int = 445, username: string = "" (empty means guest),
            domain: string = "", name: string = host (display name) }
account = "smb://" + host ; guest = username == ""
```
**Add server flow** (`AddServerViewModel.attempt(address, guest, username, password, name?)`). It returns
null on success, or the user-facing sentence on failure. The "Use your phone" flows show that same
sentence.
1. `path = fromUserInput(address)`. If null, fail with
   `Enter the server's address, like 192.168.0.10 or \\192.168.0.10\Movies`.
2. If not guest and the username is blank, fail with
   `Enter the username, or choose Guest if the server has no password`.
3. Split the domain: if the username (trimmed) contains `\`, then
   `domain = before first '\'` and `user = after first '\'`. Otherwise `domain = ""`. Guest forces both
   to `""`.
4. `knownName = name ?? picked.name`, where `picked` is a found server whose address equals `path.host`
   (case-insensitive). Then `server.name = knownName ?? host`.
5. Run `test(server, password)`: connect, authenticate, list shares, close. The password is `""` for
   guest.
6. If the user typed a share, match it **case-insensitively** to the listed share names and use the
   server's spelling. If none matches, fail with
   `There's no shared folder called "<typed>" on <host>.` followed by
   ` It shares: A, B, C` when the list is not empty.
7. If `knownName` is null and the host is all digits and dots, set `name` to the NetBIOS name when one
   answers.
8. Disconnect any cached session, save the server and password, add the `smb://host` library account,
   and return breadcrumbs (share, then each typed segment) so the browser opens there.
9. On error, take the message from `describe(e)`. **For guest**, if the message is the wrong-login or
   account-disabled sentence, replace it with
   `This server doesn't allow guests. Sign in with its username and password.`

**Authentication.**
- smbj 0.15.0. Multi-protocol negotiate is on: SMB1-style negotiate with upgrade to SMB2/3, dialects
  2.0.2 to 3.1.1. NTLM uses a BouncyCastle provider for MD4.
- **User login:** `(username, password, domain or null if blank)`.
- **Guest login:** smbj `AuthenticationContext.guest()`, which is user **`"Guest"`** with an empty
  password and no domain, over NTLM. This is not anonymous (anonymous is user `""`).
- Port is `server.port`, 445 by default. There is no NetBIOS-session (139) fallback.
- Request timeout: **20 s**. **No socket read timeout.** An idle player connection must survive minutes
  without reads. A read timeout killed the reader thread while the connection still reported itself
  connected. Keep the same rule on Windows: set no `ReceiveTimeout` on the SMB socket. Per-request
  timeouts are fine.
- One session per host is cached. Open shares are cached per `host/share` and reused while connected and
  tied to the same session. A host whose player read failed is marked `broken`, so its next call
  reconnects. Each call retries **once** with a fresh session when the error counts as "dropped":
  - transport errors, timeouts or IOExceptions;
  - `STATUS_NETWORK_NAME_DELETED`;
  - `STATUS_USER_SESSION_DELETED`.

**Listing shares (DCERPC srvsvc).**
- Over the session, open the IPC$ named pipe `\PIPE\srvsvc`, bind to the SRVSVC interface
  (`4b324fc8-1670-01d3-1278-5a47bf6ee188` v3.0) and call **NetrShareEnum level 1**
  (`SHARE_INFO_1`: netname, type, remark). rapid7 dcerpc `ServerService.getShares1()` does this.
- Filter: keep `(type & 0xFF) == 0` (`STYPE_DISKTREE`), which excludes printers, IPC and devices, and
  drop names ending in `$` (admin and hidden shares).
- Sort case-insensitively.

**Listing a folder.**
- `share.list(sharePath)` (SMB2 QUERY_DIRECTORY).
- Drop `.` and `..`, and any entry with the HIDDEN (0x2) or SYSTEM (0x4) attribute.
- An entry is a directory when `attributes & 0x10`.
- A file maps to `DriveFile`:
  - `id` = child id
  - `name`
  - `mimeType` = MIME type from the extension (`application/octet-stream` when unknown)
  - `size` = EndOfFile, as a string
  - `modifiedTime` = LastWriteTime as an ISO-8601 instant, only when greater than 0
  - `parents` = [folder id]
  - capabilities: rename, trash, delete and addChildren all true
- Sort folders first, then case-insensitive name.

**Other operations.**
- **Read for playback:** open with GENERIC_READ and share mode READ|WRITE|DELETE, disposition FILE_OPEN.
  Size comes from the standard info's EndOfFile. Positional reads return -1 at or past EOF and clamp the
  length to the bytes left. The player wraps this in a 256 KB buffered reader.
- **Rename / move:** open with DELETE|GENERIC_READ, then call `rename(targetSharePath, replace=false)`.
  A move is allowed only within the same host and share (`Files can only be moved within the same shared
  folder`).
- **Delete:** a folder is removed with `rmdir(recursive=true)`, a file with `rm`. Shares themselves can't
  be renamed or deleted.
- **Space:** `shareInformation` gives `used = total - free` and `free = callerFreeSpace` (per-user
  quota). It is null at server level.
- **mkdir** is supported.

**Error sentences** (`describe`, which walks the cause chain):
| Cause | Text |
|---|---|
| UnknownHost | Couldn't find that server on your network. Check the address. |
| NoRoute / Connect refused / socket timeout | Couldn't reach the server. Check that it's on and that you're on the same Wi-Fi. |
| STATUS_LOGON_FAILURE | Wrong username or password |
| STATUS_ACCOUNT_DISABLED | This user account is disabled on the server |
| STATUS_PASSWORD_EXPIRED | This user's password has expired on the server |
| STATUS_ACCESS_DENIED | This user isn't allowed to open that folder |
| STATUS_BAD_NETWORK_NAME | The server has no shared folder with that name |
| STATUS_OBJECT_NAME/PATH_NOT_FOUND | That folder or file isn't on the server any more |
| STATUS_NOT_SUPPORTED | The server doesn't support this |
| Transport lost | The connection to the server was lost |
| fallback | exception message, else "Something went wrong talking to the server" |

Other messages:
- Server not in the store: `This network server was removed from Veltoret`.
- Password can't be decrypted: `Sign in to <name> again`.
- A share is needed: `Pick a shared folder on <host> first`.
- The tree isn't a disk share: `"<name>" isn't a shared folder`.

### 1.4 Password storage
Android:
- SharedPreferences file `smb_servers`.
- Key `server:<account>` holds the SmbServer JSON (§0.1 rules). Key `password:<account>` holds `""` for
  guest or an empty password, else `Base64(iv[12] || AES-256-GCM ciphertext || tag[16])`.
- The key is an Android Keystore AES key with alias `veltoret-smb`, which never leaves the device.
- The file is excluded from backup. If decryption fails, `password()` returns null and the user must
  sign in again.

**Windows proposal (DPAPI).**
- File `%LOCALAPPDATA%\Veltoret\smb_servers.json`, shaped like this:
  `{ "servers": [ { "host","port","username","domain","name","password": "<b64 or empty>" } ] }`
- `password = Base64(ProtectedData.Protect(UTF8(pw), entropy: UTF8("veltoret-smb"),
  DataProtectionScope.CurrentUser))`, using `System.Security.Cryptography.ProtectedData`, MIT, in-box on
  Windows.
- The blob is bound to the Windows user's logon credentials, the closest match to "never leaves this
  device". A failed `Unprotect` (profile copied to another PC) counts as "sign in again".
- Keep `""` for guest, and never log the password.
- Alternative: Windows Credential Manager (`CredWrite`, target `Veltoret:smb://host`, type GENERIC),
  which also shows the entry in Control Panel. DPAPI is simpler and matches the Android design more
  closely.
- Use the same scheme for TvLink secrets (§2.6), with entropy `"veltoret-link"`.

The Windows app is not backed up the way Android is. Still keep these files out of any settings
export or sync.

### 1.5 Player data source (`SmbDataSource`)
- The media URI is the `smb://` id.
- `open(position, length)` opens a reader. A position past the size is an out-of-range error.
  `bytesRemaining` is the requested length, or `size - position`.
- `read` reads at the current position. Failures surface as network-connection errors, and the host is
  marked broken so a retry reconnects.
- Routing: `smb://` goes to SMB, the scheme `vlink` goes to LinkDataSource (TV only), and everything else
  goes to HTTP (Drive).
- On Windows, expose an SMB file to the video engine (LibVLC, FFmpeg or Media Foundation) as a seekable
  `Stream`. With LibVLC you can also pass `smb://user:pass@host/share/path` or a UNC path directly, but a
  custom stream keeps the single-session, no-read-timeout behavior.

### 1.6 C# library recommendation
| Option | Notes |
|---|---|
| **SMBLibrary** (Tal Aloni, NuGet `SMBLibrary`) | **License LGPL-3.0**. It is compatible with GPL-3.0: a GPL-3.0 app may link it, and the combined work is GPL-3.0. Keep its notice. Pure managed SMB1/2/3 client: `SMB2Client.Connect(ip, SMBTransportType.DirectTCPTransport)`, `Login(domain, user, pw)`, `ListShares(out status)`, which does srvsvc NetShareEnum internally (filter as in §1.3), `TreeConnect`, `CreateFile`, `QueryDirectory`, `ReadFile(offset)`. It gives full control (guest = user `Guest` with an empty password; anonymous = `""`), adds no system-wide side effects, and runs one session per host like Android. SMB 3.x encryption support is limited (check the current release notes). **Recommended primary.** |
| **Native Windows UNC** (`\\host\share\path` via `System.IO`) | No dependency, fastest, and the OS handles SMB 3.1.1 and signing. Credentials go through `WNetAddConnection2` (mpr.dll, `RESOURCETYPE_DISK`, `\\host\IPC$` or `\\host\share`, user `DOMAIN\user`). Shares come from `NetShareEnum` level 1 (netapi32) with the same filter. Drawbacks: connections are per logon session and **system-wide** (error 1219 "multiple connections with different credentials" when Explorer already has one). **Windows 10 1709+ blocks insecure guest logons** (`AllowInsecureGuestAuth`) for SMB2/3, so guest-only routers and NAS boxes fail even though they work on Android. Use it as the fast path when the user already has access (`Directory.Exists(unc)` succeeds without credentials), else fall back to SMBLibrary. |
| smbj / jcifs | Java only; not applicable. |

Recommendation: implement `ISmbClient` with SMBLibrary, matching Android behavior including guest. Add an
optional native-UNC path for playback speed when Windows already has access.

---

## 2. Play on TV (`data/tvlink`): Windows is the client

### 2.1 Discovery (WIRE)
- DNS-SD service type **`_veltoret-play._tcp`** (Android `"_veltoret-play._tcp."`, domain `local`).
- The instance name is the TV's device name (Settings device name, else `Build.MODEL`). Android may
  append ` (2)` on conflicts.
- Port: an ephemeral port (`ServerSocket(0)`, bound to 0.0.0.0) taken from the SRV record. It **changes
  every time the service starts.**
- **No TXT records** are set. Don't rely on any.
- Resolve with a 4 s timeout, one at a time. Use the first IPv4 address.
- Then call `GET /hello` (3 s timeout) and drop TVs that don't answer.
- De-duplicate by `hello.id`. `paired = (stored secret for hello.id exists)`.
- The TV listener runs as a foreground service at app start and at boot, but only when the TV setting
  "Play from your phone" is on. Android 17 TVs also need the Nearby-devices permission.

### 2.2 Endpoints (WIRE)
Every request is HTTP/1.1 per §0.2. Each one is a separate TCP connection (connect timeout 4 s).

| Method & path | Signed | Request body | Success response | Client read timeout |
|---|---|---|---|---|
| `GET /hello` | no | none (no Content-Type / Length) | 200 `LinkHello` | 3 s |
| `POST /pair/start` | no | `LinkPairStart` | 200 `LinkReply` (ok may be false) | 8 s |
| `POST /pair` | no | `PairMessage` (sealed `LinkPairSecret`) | 200 `LinkReply{ok:true,message:"Paired"}` | 15 s |
| `POST /play` | **yes** | `LinkPlay` | 200 `LinkReply{ok, message:"tv"\|"phone"}` | 15 s |
| `POST /command` | **yes** | `LinkCommand` | 200 `LinkReply` | 8 s |
| `POST /status` | **yes** | empty (Content-Length: 0, still sent with Content-Type) | 200 `LinkStatus` | 5 s |
| anything else | | | 404 `LinkReply{ok:false,message:"Not found"}` | |

Error statuses:
- **400** with `{"ok":false,"message":"The TV didn't understand the request"}` when the body doesn't
  decode.
- **401** with `{"ok":false,"message":"Pair this phone with the TV again","code":"unpaired"}` when the
  signature check fails. The client then deletes its stored secret for that TV.
- **403** with `code:"wrong_code"` on `/pair`.
- **409** with `{"ok":false,"message":"Start pairing again"}` on `/pair` when no code is showing.
- **500** with `{"ok":false,"message":"The TV couldn't do that"}`.

Client handling: on any non-200 response, parse `LinkReply` if possible, then throw `LinkException(message
?? "<tv> couldn't do that (HTTP n)", code)`. An IO failure becomes
`Couldn't reach <tv>. Check it's on and on the same Wi-Fi.`. For `/pair/start`, `/pair`, `/play` and
`/command`, a 200 with `ok:false` also throws, using `reply.message` and `reply.code`.

### 2.3 Message types (WIRE: field names exact; *req* = no default, must be sent)
```
LinkHello      { id*: string (TV's UUID), name*: string, version*: int (=1), tvKey*: string (b64 SPKI), salt*: string (b64 16 bytes) }
LinkPairStart  { phoneId*: string, phoneName*: string }
LinkPairSecret { phoneId*: string, phoneName*: string, secret*: string (b64 32 bytes) }      // plaintext inside PairMessage
PairMessage    { phoneKey*: string (b64 SPKI), iv*: string (b64 12 bytes), data*: string (b64 ciphertext||tag) }
LinkReply      { ok*: bool, message: string = "", code: string? = null }
   codes seen: "open_app", "unpaired", "wrong_code"
LinkPlay {
  title*: string, subtitle: string? , fileId*: string, accountEmail*: string, fileName: string?,
  movieId: int?, showId: int?, season: int?, episode: int?,     // TMDB ids
  streamUrl: string?  ("vlink://ip:port/token/id"), startMs: long = 0,
  audioLanguage: string?, subtitleLanguage: string?  (language code | "off" | null = TV's usual choice)
}
LinkCommand { type*: "play"|"pause"|"seek"|"stop"|"audio"|"subtitle", positionMs: long?, track: string? }
   seek: positionMs >= 0 ; audio: track "a<n>" ; subtitle: track "t<n>" | "x:<externalId>" | omitted/null = subtitles off
LinkTrack  { id*: string, label*: string, detail: string = "" }
LinkStatus {
  active: bool=false, title: string="", source: string="" ("tv"|"phone"), playing: bool=false, buffering: bool=false,
  positionMs: long=0, durationMs: long=0, ended: bool=false, error: string?=null,
  audio: LinkTrack[]=[], audioSelected: string?=null, subtitles: LinkTrack[]=[], subtitleSelected: string?=null
}
```
Example bodies:
- `{"type":"pause"}`, `{"type":"seek","positionMs":754000}`, `{"type":"subtitle"}` (off).
- `/status` with the TV idle returns `{}`.
- After a finished video, `/status` returns `{"ended":true}`.

Track ids on the TV side (`PlayerViewModel.linkStatus`):
- Audio: `a0..aN`, the index into the player's flattened audio track list. The detail is
  `"<codec> · <channels>"`.
- Embedded text: `t0..tN`.
- External subtitles: `x:<id>`.
- Selected: `audioSelected` is the selected index. `subtitleSelected` is the selected external track if
  any, else the selected `t<n>`.

`fileId` / `accountEmail`:
- The TV first looks up `fileId` in **its own** library and uses it if found and playable (online, or a
  device file).
- Next it uses its own copy by TMDB id: `movieId`, or `showId` + `season` + `episode`.
- Otherwise it uses `streamUrl`. With no stream it returns
  `{"ok":false,"message":"The TV doesn't have this video"}`.

Send Android-compatible ids so the first step can match: the Drive file id for Drive, the `smb://host/…`
id for shares. A Windows local path never matches, which is fine because TMDB matching or the stream
covers it.

`accountEmail`: the Google email, `smb://host`, or `"device"` for local files. Android sends
`file?.accountEmail ?: ""`.

If the TV can't bring Veltoret to the front (Android 10+ without "Display over other apps"), `/play`
returns `{"ok":false,"message":"Open Veltoret on the TV to start it","code":"open_app"}` and the TV queues
the request until the app is opened.

### 2.4 Request signing (WIRE)
Applies to `/play`, `/command` and `/status`. The method in the canonical string is always `POST`.
```
secretBytes = Base64Decode(secret)                 // 32 random bytes from pairing
timeMs      = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()   // decimal, no padding
canonical   = UTF8($"POST {path} {timeMs}\n") || bodyBytes      // path exactly as on the request line, e.g. "/command"
signature   = Base64(HMACSHA256(secretBytes, canonical))       // standard b64 with '=' padding (44 chars)
Headers:
  X-Veltoret-Phone:     <this device's link id (UUID string)>
  X-Veltoret-Time:      <timeMs>
  X-Veltoret-Signature: <signature>
```
Note the single spaces, the `\n` (LF only) after the time, and the body bytes appended raw. For
`/status` the body is empty, so only the header line is MACed.

Server verification:
1. All three headers must be present, and `time` must parse as a long.
2. A secret must exist for the `phone` id.
3. `|now - time| <= 300000 ms` (±5 min).
4. Recompute the signature and compare the **Base64 strings** in constant time (`MessageDigest.isEqual`
   on their bytes).
5. **Replay protection:** an in-memory `signature -> seenAt` map, pruned of entries older than 10 min
   (2 × skew) on each check. A signature already in the map is refused. Never send the same signature
   twice. A fresh `timeMs` per request ensures this (two requests in the same millisecond with the same
   body would collide).

Any failure returns the 401 `unpaired` reply, and the client then **forgets the pairing**. The Windows
clock must be within 5 minutes of the TV's.

Test vectors (`TvLinkTest`): `sign(secret, "POST", "/command", 1000000, {"type":"pause"})` verifies at
`now = 1001000`. Changing the path, the time (+1), the body or the secret makes it fail. Checking at
`time + 300001` fails.

### 2.5 Pairing (WIRE)
Client flow (`TvLinkClient`):
1. User picks an unpaired TV. Send `POST /pair/start {"phoneId": <deviceId>, "phoneName": <PC name>}`.
   - The TV generates a new 6-digit code and shows "<phoneName>" with the code, then replies
     `{"ok":true,"message":"Enter the code shown on the TV"}`.
   - If the TV can't come to the front, it replies
     `{"ok":false,"message":"Open Veltoret on the TV to see the code","code":"open_app"}`.
2. User types the 6 digits. The UI auto-submits at 6 digits; only digits are accepted.
3. `GET /hello` again to get the current `tvKey` and `salt`.
4. Make a fresh P-256 key pair for this attempt. Derive the session key (§2.7) with
   `code = typed.Trim()`.
5. `secret = Base64(32 random bytes)`.
6. `plain = UTF8(JSON LinkPairSecret{phoneId, phoneName, secret})`.
7. Seal with AAD = **the phone's own public key SPKI DER bytes**.
8. `POST /pair` with `PairMessage{phoneKey: Base64(SPKI), iv, data}`.
9. On a 200 with `ok`, store `(tvId = hello.id, tvName = hello.name, secret)`. The TV stores
   `(phoneId, phoneName, secret)` and closes its code prompt.
10. On a wrong code the TV replies **403**
    `{"ok":false,"message":"That code didn't match. The TV now shows a new code; enter that one.","code":"wrong_code"}`
    and **shows a new code**. Clear the field.

TV-side facts:
- `tvKey` / `salt` are generated once per TvLinkServer start. They stay stable while the service runs
  and change after a restart, which is why the client re-fetches `/hello`.
- The code is `random.nextInt(900000) + 100000`, uniform over 100000..999999.

The device id is a random UUID (`Guid.NewGuid().ToString()`, lowercase with hyphens), made once and
persisted. The phone name is the Android device name; on Windows use `Environment.MachineName` or the
user-set PC name.

### 2.6 Storage of pairings
Android:
- Prefs file `tv_link`, excluded from backup.
- `device_id` holds the UUID.
- `name:<peerId>` holds the peer name.
- `secret:<peerId>` holds `Base64(iv12 || AES-GCM(secret) || tag)` under the Keystore alias
  `veltoret-link`.

Windows: `%LOCALAPPDATA%\Veltoret\tv_link.json` with `{deviceId, peers:[{id,name,secret: DPAPI-b64}]}`
(§1.4). Offer "Forget TV", which removes the entry.

### 2.7 Pairing crypto (`PairingCrypto`, WIRE): shared by Play on TV and Send to TV
```
Curve:        NIST P-256 (secp256r1)
Public key:   X.509 SubjectPublicKeyInfo DER, named-curve OID, uncompressed point (91 bytes), Base64
              C#: ecdh.ExportSubjectPublicKeyInfo() / ECDiffieHellman.Create().ImportSubjectPublicKeyInfo(bytes, out _)
ECDH secret:  raw shared X coordinate, 32 bytes (Java KeyAgreement "ECDH".generateSecret())
              C#: ecdh.DeriveRawSecretAgreement(other.PublicKey)   (.NET 8+).  NOT DeriveKeyMaterial/DeriveKeyFromHash (those hash it).
Stretch code: PBKDF2-HMAC-SHA256(password = UTF8(code 6 ASCII digits), salt = 16 bytes from offer, iterations = 120000, dkLen = 32)
              C#: Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(code), salt, 120_000, HashAlgorithmName.SHA256, 32)
Session key:  HMAC-SHA256(key = stretched(32), data = ecdhSecret(32) || UTF8("veltoret-send-to-tv-v1"))  -> 32 bytes = AES-256 key
              (same INFO string for both Send to TV and Play on TV)
Seal:         AES-256-GCM, nonce = 12 random bytes, tag = 16 bytes (128-bit), AAD = sender's (phone's) SPKI DER bytes
              iv   = Base64(nonce)
              data = Base64(ciphertext || tag)          // Java appends the tag; C# AesGcm returns them separately -> concatenate
Open:         split data: ct = data[..^16], tag = data[^16..]; failure (AuthenticationTagMismatchException) = wrong code/tampered
```
The TV opens the message with `phoneKey.encoded`, which is the key re-encoded after decoding. Always send
the standard named-curve SPKI, as `ExportSubjectPublicKeyInfo` produces. Use those **same bytes** as the
AAD.

Other random values:
- `newSalt` = 16 bytes.
- `newToken` (QR page) = `Base64(18 random bytes)` with `+` changed to `-` and `/` to `_`, giving 24
  chars with no padding.

Test vectors: phone and TV derive identical keys, and the message round-trips. A wrong code (123456 vs
123457) or another key pair fails to open. Codes are 6 digits; tokens are 24 chars without `+` or `/`.
Port `PairingCryptoTest`, and add a cross-check test with a Java-generated fixture if possible.

### 2.8 Remote-control loop (client behavior)
- Connecting to a TV ends any Chromecast session. Connecting to Chromecast ends the link and sends
  `stop` to the TV.
- **Load:**
  1. Start CastServer facing the TV's IP (§4).
  2. Register the media under id `v<unsigned hash of fileId>`. Any URL-safe unique id works; Android
     uses `Java String.hashCode().toUInt()` in decimal. Use **no audio patches**, since the TV gets all
     tracks.
  3. `streamUrl = "vlink" + httpUrl.Substring("http".Length)`, so `http://192.168.1.20:4000/abc/v1`
     becomes `vlink://192.168.1.20:4000/abc/v1`.
  4. Send `/play` with `startMs`, the current `audioLanguage`, and `subtitleLanguage` (the language of
     the shown subtitle, `"off"` when subtitles are disabled, null when unknown).
  5. The reply message `"tv"` or `"phone"` is the source. With `"phone"`, keep the PC awake and serving:
     `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)`.
- **Poll:**
  - Send `POST /status` every 1,000 ms.
  - After **6** consecutive failures, show `"Lost touch with <tv>"` (or the LinkException message).
  - If `active` was true before and is now false with `ended` false, the TV closed its player: the local
    player takes over at the last position, paused.
  - `ended` means finished.
  - Save watch progress when the video ends, when playback goes from playing to paused, and every 10 s
    while playing.
- **Commands:**
  - play, pause, `seek(positionMs)`, stop (on disconnect).
  - Audio and subtitle choices send the TV's own track ids from `LinkStatus`.
  - The TV never auto-plays the next episode; the client sends it.

### 2.9 `vlink://` stream (WIRE: the TV's `LinkDataSource` is the HTTP client of CastServer)
The TV maps `vlink://host:port/<token>/<id>` to a plain-socket GET:
```
GET /<token>/<id> HTTP/1.1\r\nHost: host:port\r\nRange: bytes=<pos>-[<end>]\r\nConnection: close\r\n\r\n
```
- Port defaults to 80 if missing, so **always include the port**. The path is used as-is (encoded path),
  so keep ids URL-safe (`[A-Za-z0-9._-]`).
- It reads headers line by line (8 KiB limit) and uses only the status code and `Content-Length`. 416
  means the position is out of range; any other non-2xx is an error. A 200 to a request with
  position > 0 makes it skip bytes, but **always answer ranges with 206**.
- Connect timeout 8 s, read timeout 20 s, TCP_NODELAY.

The server side is CastServer (§4).

---

## 3. Send to TV / "Use your phone" (`data/pairing`)
The TV shows this panel while adding a network server. Windows can act as the **phone** and send a saved
SMB server, password included.

**Discovery (WIRE):**
- DNS-SD **`_veltoret._tcp`**. The instance name is the TV device name, with an ephemeral port and no
  TXT records.
- It exists only while the TV's "Use your phone" panel is open. The keys, salt, code and token are new
  each time the panel opens.
- Resolve with a 4 s timeout, then confirm with `GET /pair` (3 s). Use the offer's `name`.
- Keep **one entry per host**; a newer answer replaces the older one, because stale ` (2)` announcements
  linger.
- Search for about 8 s before showing "No TV found".

**Endpoints (WIRE, §0.2 framing, body limit 16 KiB):**
| Method & path | Body | Response |
|---|---|---|
| `GET /s/<token>` | none | 200 text/html QR form page (browser flow) |
| `POST /s/<token>/send` | `PhoneSubmission` JSON, **plaintext** | 200 `SetupReply` / 400 |
| `GET /pair` | none | 200 `PairOffer` |
| `POST /pair` | `PairMessage` sealing `PhoneSubmission` | 200 / 403 / 400 `SetupReply` |
| other | | 404 text/plain `Not found` |

```
PairOffer        { tvKey*: b64 SPKI, salt*: b64 16 bytes, name*: string }
PairMessage      { phoneKey*, iv*, data* }                     // §2.7, AAD = phone SPKI
PhoneSubmission  { address*: string, guest: bool=false, username: string="", password: string="", name: string?=null }
SetupReply       { ok*: bool, message*: string }
```
Phone flow (`SendToTv.send`):
1. `GET /pair` with a 5 s timeout. On failure, show
   `Couldn't reach the TV. Check it's on the same Wi-Fi and still showing "Use your phone".`
2. Create a fresh key pair, derive the session key with `code.Trim()`, and seal
   `UTF8(JSON PhoneSubmission)` with the phone's SPKI as AAD.
3. `POST /pair` with a connect timeout of 5 s and a **read timeout of 75 s**. The TV tries the SMB login
   before answering and gives up after 60 s.
4. Any exception shows
   `The TV stopped answering. Check it's still showing "Use your phone" and try again.`

PhoneSubmission from a saved server:
- `address = server.host` (host only, no share).
- `guest = server.guest`.
- `username` is `domain\user` when there is a domain, else `user`.
- `password` is decrypted, `name = server.name`.

TV replies:
- 200 `{"ok":true,"message":"Connected. Choose your folders on the TV."}` on success.
- `{"ok":false,"message":<the add-server sentence>}` when the SMB attempt fails.
- 403 `"That code didn't match. The TV now shows a new code; enter that one."` with a new code.
- 400 for a body that doesn't decode.

On a reply starting with `That code`, clear the code field. If the local password can't be decrypted,
show `This device can't read the saved password any more. Remove the server and add it again.`

Never log or persist the submission.

---

## 4. CastServer: phone-side HTTP streaming server (WIRE for the Chromecast and the TV)
Used for Chromecast and for the `vlink://` fallback. It runs **only while casting or linked**, and stops
on disconnect, which also clears the entries.

- **Bind:** the local address facing the receiver, port 0 (ephemeral), with `reuseAddress`. Find the
  local IP the same way Android does: UDP `Connect(receiverIp, 8009)` then read `LocalEndPoint`. In C#,
  `new Socket(InterNetwork, Dgram, Udp).Connect(ip, 8009); ((IPEndPoint)s.LocalEndPoint).Address`.
  Restart the server if that address changes.
- **Windows Firewall:** binding a listener prompts the user, or silently blocks, for inbound
  connections. The installer should add an inbound rule for the app on **Private** networks (or use
  `INetFwPolicy2`). Without it, Chromecast and TV streaming fail.
- **Token:** 16 random bytes as **lowercase hex** (32 chars), made once per server instance.
- **URL:** `http://<ip>:<port>/<token>/<id>`. The path must have exactly 2 segments
  (`path.Trim('/').Split('/')`) with `[0] == token`, else 404.
- **Entries:** a media entry is `{uri, mime, length?, patches}`. A text entry is
  `{utf8 bytes, mime "text/vtt"}`.
- Accept loop: thread pool, per-connection socket read timeout 30 s, head read with ISO-8859-1 lines,
  header names lowercased.

**Request handling order:**
1. Not a home-network client (§0.4): `403 Forbidden`, text body `Forbidden`.
2. `OPTIONS` (any path): `204 No Content` with CORS headers and no body.
3. Bad token or path, or unknown id: `404 Not Found`, body `Not found`.
4. Text entry: `200`, `Content-Type: text/vtt; charset=utf-8`, `Content-Length`, then the body (no body
   for `HEAD`).
5. Media entry:
   - `total = length` (the library's known size) or a probe (open the source and read its length).
   - If a `Range` header is present and `parseRange` returns null: `416`, header
     `Content-Range: bytes */<total or *>`, no body.
   - `start = range.first or 0`. `end = range.last` (unless it is OPEN_END), else `total - 1`, else
     unknown. `length = end - start + 1` when known.
   - Headers: `Content-Type: <mime>`, `Accept-Ranges: bytes`, `Content-Length` (if known), and
     `Content-Range: bytes <start>-<end>/<total or *>` (only when a range was given).
   - Status `206 Partial Content` when a Range was given, else `200 OK`. `HEAD` stops here.
   - Body: read through the app's normal data sources (Drive, local, SMB) from `start`, 256 KiB chunks,
     calling `CastAudio.apply(patches, position, buf, n)` before each write. Stop at the requested length
     or EOF. Client disconnects are normal (the Chromecast drops connections when seeking).

**Response head, written in this order (ISO-8859-1):**
```
HTTP/1.1 <code> <reason>\r\n            reasons: 200 OK, 204 No Content, 206 Partial Content, 403 Forbidden, 404 Not Found, 416 Range Not Satisfiable, else "Error"
Access-Control-Allow-Origin: *\r\n
Access-Control-Allow-Headers: Range, Content-Type\r\n
Access-Control-Expose-Headers: Content-Range, Content-Length, Accept-Ranges\r\n
Connection: close\r\n
<entry headers>\r\n...
[Content-Type: text/plain\r\nContent-Length: n\r\n]   (only for the 403/404 text bodies)
\r\n
```
The Default Media Receiver fetches subtitles by XHR, which is why CORS is needed.

**`parseRange(header, total?)`:**
1. `spec = header.Trim()`, with the `bytes=` prefix removed and only the part before the first `,` kept,
   then trimmed.
2. If the header doesn't start with `bytes=`, or `spec` has no `-`: null.
3. Suffix form `-N`: null when total is unknown or N <= 0, else `max(0,total-N) .. total-1`.
4. `start-[end]`:
   - null if `start` isn't a number, or if total is known and `start >= total`.
   - `end = min(end, total-1)` when the end is given and total is known.
   - A missing end becomes `total-1`, or `start..OPEN_END` when total is unknown.
   - null if `end < start`.

`OPEN_END = long.MaxValue - 1`.

Test vectors (`CastTest`), for total 1000:
- `bytes=0-` gives 0..999. `bytes=500-` gives 500..999. `bytes=100-199` gives 100..199.
- `bytes=900-5000` gives 900..999. `bytes=-200` gives 800..999.
- `bytes=1000-`, `bytes=300-200`, `items=0-1` and `bytes=abc-` give null.

With total unknown: `bytes=500-` gives 500..OPEN_END, and `bytes=10-20` gives 10..20.

A Kestrel minimal API would also work, but match the headers exactly and keep the token, home-only and
`Connection: close` behavior. A raw `TcpListener` port of the ~200-line Kotlin file is simplest.

---

## 5. Chromecast (`player/cast`)

### 5.1 What Android does via the Cast SDK
- **Receiver:** the Default Media Receiver, app id **`CC1AD845`**
  (`CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID`). There is no custom receiver.
  `stopReceiverApplicationWhenEndingSession = true`, so disconnect stops the app on the TV.
- Never on TV devices. Android needs Play services; Windows has no such requirement.
- Device picker: Cast routes plus Veltoret TVs (§2.1). A Chromecast route whose name equals a Veltoret
  TV's name (case-insensitive) is hidden behind "Use Chromecast instead". Labels:
  - Veltoret TVs: `Veltoret · all audio tracks and subtitles` when paired, `Veltoret · pair once with a
    code` when not.
  - Chromecasts: `Chromecast`.
- **Load:**
  1. Pause the local player.
  2. Wait up to 8 s for tracks and the saved track choice.
  3. If MKV has 2+ audio tracks and no choice has been made yet, ask "Which audio on the TV?".
  4. Start CastServer facing `castDevice.inetAddress`.
  5. Compute audio patches (§5.3).
  6. Register the video as `v<hash(fileId)>a<audioTrack or 0>`. Each audio choice gets its **own URL** so
     the receiver doesn't reuse a cached stream.
  7. Register each subtitle as `s<i>-<hash(sub.id)>` with its VTT text.
- **Load request** (Cast SDK `MediaLoadRequestData`), as JSON on the media channel:
```json
{
  "type": "LOAD", "requestId": 1, "sessionId": "<app sessionId>",
  "autoplay": true,
  "currentTime": 754.0,                       // startMs / 1000.0 (seconds, double)
  "activeTrackIds": [2],                      // only if a subtitle is active: index+1
  "media": {
    "contentId": "http://192.168.1.5:51234/<token>/v123a2",
    "contentUrl": "http://…same…",            // optional; newer receivers prefer it
    "streamType": "BUFFERED",
    "contentType": "video/x-matroska",
    "metadata": {
      "metadataType": 1,                      // 1 = MOVIE, 2 = TV_SHOW (episodes)
      "title": "<title>", "subtitle": "<subtitle, e.g. S01E02 · Name>",
      "images": [ {"url": "<poster w500>"}, {"url": "<backdrop or episode still w780>"} ]
    },
    "tracks": [
      { "trackId": 1, "type": "TEXT", "subtype": "SUBTITLES", "name": "<label>",
        "trackContentId": "http://…/<token>/s0-456", "trackContentType": "text/vtt", "language": "en" }
    ],
    "textTrackStyle": { "backgroundColor": "#00000099", "foregroundColor": "#FFFFFFFF",
                        "edgeType": "DROP_SHADOW", "fontScale": 1.0 }
  }
}
```
  Notes: Android colors are ARGB ints (`0x99000000`), and Cast JSON uses CSS `#RRGGBBAA`. Track ids are
  `1..n` in subtitle-list order. `language` is omitted when unknown.
- MIME type by **file name** extension (`file.name`, else title):
  - `mp4`, `m4v`, `mov`: `video/mp4`
  - `webm`: `video/webm`
  - `ts`, `m2ts`: `video/mp2t`
  - `avi`: `video/x-msvideo`
  - anything else: `video/x-matroska`
- **Controls:**
  - `PLAY` / `PAUSE` / `SEEK {currentTime: s}` with `mediaSessionId`.
  - Subtitle on or off: `EDIT_TRACKS_INFO {activeTrackIds: [i+1] | []}`.
  - Switching audio reloads the media at the current position with the new URL.
- **Status:**
  - `MEDIA_STATUS` sets `playing = PLAYING` and `buffering = BUFFERING or LOADING`.
  - `IDLE` with `idleReason FINISHED` means finished: save progress as the full duration.
  - `IDLE` with `ERROR` shows
    `The TV couldn't play this video. Its format may not be supported by Chromecast.`
  - Progress: about 1 s ticks (poll `GET_STATUS`, or extrapolate from `currentTime` and `playbackRate`).
  - Save progress every 10 s while playing, when playback goes from playing to paused, and on session end.
  - A failed load shows `The TV couldn't play this video (<code>)`.
- **Disconnect:** stop CastServer and the wake locks. The local player seeks to the TV's position,
  paused. The local player doesn't save progress while casting; the cast controller saves it instead.
- **Audio codec warning:** if the selected audio track is DTS (any variant) or TrueHD, or, before tracks
  are known, the uppercase file name matches `\bTRUEHD\b` or `\bDTS`, show
  `This video's audio is <DTS|Dolby TrueHD>, which most Chromecasts can't play, so there may be no sound. Another version of it may work.`
- Keep the PC awake while serving (`SetThreadExecutionState`); Android uses a Wi-Fi lock and a partial
  wake lock for up to 6 h.

### 5.2 Subtitles to WebVTT (`CastSubtitles`)
Only sidecar or added subtitle files are sent (all parsed formats are converted). **Embedded MKV
subtitles are not sent.** Each cue's text is its lines joined with `\n`. The offset is the player's
subtitle sync: `offsetUs = subtitleOffsetMs * 1000`.
```
out = "WEBVTT\n\n"
for each line (startUs, endUs, text):
    start = startUs + offsetUs ; end = endUs + offsetUs
    t = text.Trim().Replace("-->", "->")
    if end <= 0 or t == "": skip
    out += time(max(0,start)) + " --> " + time(end) + "\n"
    out += join("\n", t.split on \r\n|\n|\r, drop blank (whitespace-only) lines) + "\n\n"
time(us): ms = us/1000 (integer division) ; $"{ms/3600000:00}:{ms/60000%60:00}:{ms/1000%60:00}.{ms%1000:000}"  (InvariantCulture)
```
Test vectors (`CastTest`):
- `[(1s,2.5s,"Hello"), (3723.045s,3725s,"Two\n\nlines --> here")]` gives
  `"WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n\n01:02:03.045 --> 01:02:05.000\nTwo\nlines -> here\n\n"`.
- Offset −1.5 s on `[(1,2,"Early"),(5,6,"Later")]` gives
  `"WEBVTT\n\n00:00:00.000 --> 00:00:00.500\nEarly\n\n00:00:03.500 --> 00:00:04.500\nLater\n\n"`.
- `(0,1s,"Gone")` with −2 s gives `"WEBVTT\n\n"`.

Served as `text/vtt; charset=utf-8`.

### 5.3 MKV audio-track hiding (`CastAudio`, exact)
The Default Media Receiver reports no audio tracks and always plays the default one. To pick the
language, the **streamed bytes** of every *other* audio track's TrackType are rewritten to **0x20**
(Matroska "control" type). The length is unchanged, so offsets and seeking still work, and the file
itself is never modified. This applies only to MKV with 2 or more audio tracks; each audio option's track
number is the MKV `TrackNumber`.

**EBML reader.** The cursor reads in **64 KiB windows** (`Reader.read(position, 65536)`), at most **16
window reads**, else it fails. Reading past EOF (an empty window) fails. Any failure means an empty
result.
- `element(p)`:
  - `first = byte(p)`, `idLen = nlz32(first) - 23`, which must be 1..4. The id is the big-endian
    `idLen` bytes, **including** the length-marker bits (for example `0x1A45DFA3`).
  - `sizeFirst = byte(p+idLen)`, `sizeLen = nlz32(sizeFirst) - 23`, which must be 1..8.
  - `size = sizeFirst & (0xFF >> sizeLen)`, then for each further byte `size = size<<8 | b`.
  - **Unknown size** when all value bits are 1. The first byte's masked value must equal
    `0xFF >> sizeLen`, and every further byte must be `0xFF`.
  - `data = p + idLen + sizeLen`, `end = data + (size ?? 0)`.
  - `nlz32(x)` for x in 0..255 is `BitOperations.LeadingZeroCount((uint)x)`.
- `uint(pos, len)`: big-endian unsigned.
- `children(start, end, fn)`: walk elements from start while `p < end`. Stop on a null element or one of
  unknown size, else `p = e.end`.

**Finding the tracks** (`parse`):
1. `ebml = element(0)`. The id must be `0x1A45DFA3` and its size known, else empty.
2. `segment = element(ebml.end)`. The id must be `0x18538067`.
   `segmentEnd = segment.data + size`, or unbounded when the size is unknown.
3. `p = segment.data`, `tracksAt = null`. Repeat at most **64** times:
   - `p >= segmentEnd` gives empty. `e = element(p)`; null gives empty.
   - `e.id == 0x1654AE6B` (Tracks): **return** `tracks(e)`.
   - `e.id == 0x114D9B74` (SeekHead): if `tracksAt` is null, set
     `tracksAt = segment.data + seekTarget(e, 0x1654AE6B)` (when found).
   - `e.id == 0x1F43B675` (Cluster): if `tracksAt` is null, or `tracksAt <= p`, return empty. Otherwise
     set `p = tracksAt` and **continue the loop** (skipping the advance below).
   - Otherwise: if `e.size` is unknown, return empty; else `p = e.end`.
4. Return empty.

`seekTarget(head, wanted)`: for each child `Seek (0x4DBB)` of known size, while nothing has been found
yet, read its children:
- `SeekID (0x53AB)` becomes `id = uint(data, len)`.
- `SeekPosition (0x53AC)` becomes `position = uint(...)`.

If `id == wanted`, then `found = position`. The position is relative to the start of segment data.

`tracks(tracksEl)`: requires a known size. For each child `TrackEntry (0xAE)` of known size, read its
children (skipping any of unknown size):
- `TrackNumber (0xD7)` gives `number = uint(data, len)`.
- `TrackType (0x83)` gives `type = uint(data, len)`, `typeAt = field.data`, `typeLength = len`.

If `type == 2` (audio), `number` is set, and `typeLength` is 1..8, add
`Track(number, typeOffset = typeAt, typeLength)`.

**Patches** (`hideAllBut(tracks, keep)`):
- If there are fewer than 2 tracks, or none has `number == keep`, return no patches.
- Otherwise, for every track with `number != keep`, for `i` in `0..typeLength-1`, set
  `patch[typeOffset + i] = (i == typeLength-1) ? 0x20 : 0x00`. This writes a big-endian value of 0x20
  over the same width.

**Apply while streaming** (`apply(patches, position, buf, count)`): for each `(offset, value)` with
`position <= offset < position + count`, set `buf[offset - position] = value`. Do this for every chunk,
so patches that span chunk boundaries work.

Test vectors (`CastAudioTest`) build EBML with an 8-byte size marker (`0x01` followed by 7 bytes):
- Tracks before the first Cluster: tracks (1:video, 2:audio, 3:audio, 4:0x11) give `[2, 3]`, and the byte
  at each `typeOffset` equals 2.
- SeekHead pointing at Tracks stored after a Cluster gives `[2, 3]`.
- Non-MKV bytes (4096 × 0x07) give empty. A single audio track gives no patches.
- Tracks `1v, 2a, 3a, 4a` with keep=3 give 2 patched bytes. Streaming in 7-byte chunks and re-parsing
  yields only `[3]`, and the size is unchanged.

Windows needs the MKV TrackNumber of each audio track for the options list. Either take it from the video
engine's track metadata (Media3 exposes it as the format id; LibVLC's `i_id` and FFmpeg's stream `id` are
the Matroska TrackNumber for MKV) or use `CastAudio.audioTracks` directly. Pair those numbers with
language and codec labels from the engine.

### 5.4 Cast v2 from C#
**Discovery:** mDNS `_googlecast._tcp.local`. The SRV record gives host and port, normally **8009**. TXT
keys:
- `id` (UUID hex), `fn` (friendly name), `md` (model name), `ca` (capabilities bitmask)
- `ic` (icon path), `ve` (version), `rs` (running app status), `st`, `bs`, `nf`, `rm`, `cd`

Show `fn`. Group devices (`md = "Google Cast Group"`) can be listed.

**Transport:**
- TLS over TCP to `ip:8009`. The device certificate is self-signed, so accept it
  (`RemoteCertificateValidationCallback = (_,_,_,_) => true`; device authentication is optional for
  senders). Use `SslStream`.
- Framing: each message is a **4-byte big-endian length** followed by a protobuf `CastMessage`:
```proto
syntax = "proto2"; package extensions.api.cast_channel;
message CastMessage {
  enum ProtocolVersion { CASTV2_1_0 = 0; }
  required ProtocolVersion protocol_version = 1;
  required string source_id = 2;        // "sender-0" (or a random "sender-xxxx")
  required string destination_id = 3;   // "receiver-0" or the app's transportId
  required string namespace = 4;
  enum PayloadType { STRING = 0; BINARY = 1; }
  required PayloadType payload_type = 5;
  optional string payload_utf8 = 6;     // JSON
  optional bytes payload_binary = 7;
}
```
  Encode with Google.Protobuf (BSD-3), or by hand since it is only 6 fields.

**Namespaces and sequence:**
1. `urn:x-cast:com.google.cast.tp.connection`: send `{"type":"CONNECT"}` to `receiver-0` (and
   `{"type":"CLOSE"}` when done).
2. `urn:x-cast:com.google.cast.tp.heartbeat`: send `{"type":"PING"}` every **5 s** and answer `PING`
   with `{"type":"PONG"}`. Drop the connection after about 3 missed beats.
3. `urn:x-cast:com.google.cast.receiver`:
   - `{"type":"LAUNCH","appId":"CC1AD845","requestId":n}`, then wait for `RECEIVER_STATUS` and take
     `status.applications[appId=CC1AD845].transportId` and `.sessionId`.
   - `GET_STATUS`.
   - `{"type":"STOP","sessionId":…}` on disconnect.
   - `SET_VOLUME {volume:{level|muted}}` if wanted.
4. Send `CONNECT` on the connection namespace to **`transportId`**.
5. `urn:x-cast:com.google.cast.media` (destination `transportId`):
   - `LOAD` (§5.1), then `MEDIA_STATUS` gives `status[0].mediaSessionId`, `playerState`, `idleReason`,
     `currentTime`, `media.duration`.
   - `PLAY` / `PAUSE` / `STOP` / `SEEK {currentTime}` / `EDIT_TRACKS_INFO {activeTrackIds}` /
     `GET_STATUS`, each with `mediaSessionId` and an incrementing `requestId`.
   - Errors: `LOAD_FAILED`, `LOAD_CANCELLED`, `INVALID_REQUEST`.

Rejoining: on reconnect, `GET_STATUS` on the receiver namespace. If `CC1AD845` is already running,
connect to its transportId instead of launching again.

**Libraries:**
- **SharpCaster** (NuGet `SharpCaster`, MIT): mDNS plus a Cast channel with media controller.
- **GoogleCast** (kakone, NuGet `GoogleCast`): Cast v2 sender with Default Media Receiver support.
  Verify the license before use; it was MIT when last checked.
- Or hand-roll (about 400 lines): `SslStream` + Google.Protobuf + `System.Text.Json` + the mDNS options
  of §1.2.

Hand-rolling is recommended for full control of the LOAD JSON (tracks, textTrackStyle, `currentTime`) and
for testability. All of these libraries are GPL-3.0-compatible (MIT, BSD, LGPL).

---

## 6. Other Windows platform notes
- **Local Network permission:** Windows has no equivalent to Android 17's `ACCESS_LOCAL_NETWORK`. The
  Windows equivalent is the **firewall**: inbound rules for CastServer (and any listener) on Private
  profiles. Outbound mDNS, NetBIOS and TCP need no rule. On a network marked **Public**, discovery and
  inbound connections may be blocked; tell the user to mark the network Private.
- **Timeouts summary:**

| Operation | Timeout |
|---|---|
| SMB port probe | 400 ms |
| NetBIOS reply | 700 ms |
| mDNS SMB window / resolve | 5 s / 3 s |
| TvLink connect | 4 s |
| TvLink hello / pair-start / pair / play / command / status | 3 / 8 / 15 / 15 / 8 / 5 s |
| Send to TV offer / connect / send | 3–5 s / 5 s / 75 s |
| TV-side SMB attempt | 60 s |
| vlink connect / read | 8 / 20 s |
| CastServer per connection | 30 s |
| SMB request (no idle read timeout) | 20 s |

- **Privacy:** never log passwords, pairing secrets, codes or a phone's submissions. Debug logs may
  record request paths and status codes only.
- **Unit tests to port** (xUnit), with every vector above: SmbPathTest, SmbDiscoveryTest (subnet +
  NetBIOS), PairingCryptoTest, TvLinkTest (sign/verify/skew/stream URL), CastTest (ranges, home network,
  VTT), CastAudioTest (EBML builder with 8-byte sizes).
