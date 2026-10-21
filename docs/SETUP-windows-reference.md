# Veltoret for Windows · Setup

Veltoret is open source and ships **without any keys**. To browse Google Drive you connect it to your own (free)
Google Cloud project, and posters and details need your own (free) TMDB key. Nothing here costs money.

> [!TIP]
> **Only want to play videos on this PC or a network share?** Skip "Google Drive" and just get a TMDB key.

---

## Google Drive

Veltoret signs in with Google's **installed-app flow**: your browser opens Google's sign-in page, and Google sends
you back to Veltoret on this PC (`http://127.0.0.1`, a random port). For that you create an OAuth client of type
**Desktop app** in your own Google Cloud project and import its JSON file into Veltoret. About 10 minutes, once.

### 1 · Create a Google Cloud project

1. Go to **[console.cloud.google.com](https://console.cloud.google.com)** and sign in.
2. Click the **project picker** at the top-left → **New Project**.
3. **Project name:** `Veltoret` → **Create**, and make sure **Veltoret** is selected in the picker.

> [!NOTE]
> You can ignore free-trial or billing banners: the Drive API is free for personal use and needs no billing account.

### 2 · Turn on the Google Drive API

1. **☰ menu** → **APIs & Services** → **Library**.
2. Search for **Google Drive API**, open it, and click **Enable**.

### 3 · Set up the sign-in screen (Google Auth Platform)

This is the screen Google shows when you sign in. Older consoles call it *OAuth consent screen*.

1. **☰ menu** → **APIs & Services** → **OAuth consent screen**. If it says *"Google Auth Platform not configured
   yet"*, click **Get started**.
2. Fill in **App name** `Veltoret`, your **User support email**, **Audience: External**, your **Contact
   information**, tick the User Data Policy box, and click **Create**.
3. **Audience → Test users → + Add users**: add **every Google account** you'll use in Veltoret → **Save**.
4. **Data Access → Add or remove scopes**: filter for `auth/drive`, tick **`.../auth/drive`** (*"See, edit, create,
   and delete all of your Google Drive files"*), click **Update**, then **Save**.

> [!NOTE]
> **Why full Drive access?** The Files screen can browse, rename, move, delete and upload anywhere in your Drive,
> extract ZIPs into it, and your library folders can live anywhere. That needs the `drive` scope. It's the only
> scope Veltoret asks for.

> [!IMPORTANT]
> **Testing mode signs you out every 7 days.** While the app's publishing status is *Testing*, Google expires the
> sign-in after 7 days and Veltoret asks you to **Reconnect** the account (Settings shows it). To avoid that for
> personal use, open **Google Auth Platform → Audience** and click **Publish app** (status *In production*). You
> don't have to submit it for verification: everyone still sees the *"Google hasn't verified this app"* warning
> once when signing in, and an unverified app is limited to 100 users. Google changes these rules from time to
> time; check the notes on the Audience page.

### 4 · Create a Desktop app OAuth client

1. **Google Auth Platform → Clients → + Create client**.
2. **Application type:** **Desktop app**. **Name:** `Veltoret for Windows` (only you see it).
3. Click **Create**, then **Download JSON** in the dialog. The file is named
   `client_secret_….apps.googleusercontent.com.json`. You can download it again later from the client's page.

> [!NOTE]
> There's no redirect URI to enter: Desktop clients accept `http://127.0.0.1` on any port automatically.

> [!IMPORTANT]
> Google can take **5–10 minutes** to apply a new client. If sign-in fails right away, wait and try again.

### 5 · Import it in Veltoret and connect

1. In Veltoret, open **Settings → Sources → Google sign-in** and click **Import client file** (onboarding offers
   the same when you choose **Connect Google account**). Pick the JSON file you downloaded.
2. Click **Add Google account**. Your browser opens Google's sign-in page.
3. Pick your account. On *"Google hasn't verified this app"* click **Continue**, make sure **See, edit, create, and
   delete all of your Google Drive files** is ticked, and click **Continue**.
4. The browser says **Veltoret is connected**. Close the tab and go back to Veltoret.

The same client file works on every PC: there's no per-machine fingerprint as on Android. Veltoret keeps the
client and each account's sign-in encrypted for your Windows user (DPAPI) under `%LOCALAPPDATA%\Veltoret\secrets`.
Removing an account in Settings forgets its sign-in on this PC; it doesn't delete anything from Drive.

> [!CAUTION]
> Keep the JSON file private and never commit it to a repository. Anyone with it can show *your* app name on
> Google's sign-in screen (they still can't open anyone's Drive without that person signing in).

### Troubleshooting

| What you see | What it means | How to fix it |
| --- | --- | --- |
| **"Google sign-in isn't set up for this build"** | No client imported, or it isn't a Desktop client | Import the JSON of a **Desktop app** client (step 4). |
| **"This is a Web application client"** when importing | The JSON is from a Web client | Create a **Desktop app** client instead. |
| `Error 400: redirect_uri_mismatch` in the browser | The client is a Web application client | Create a **Desktop app** client instead. |
| **"Access blocked … has not completed the Google verification process"** or `Error 403: access_denied` | The account isn't a test user | Add it under **Audience → Test users** (step 3). |
| **"Google didn't grant access"** | The Google page was closed, Drive access was unticked, or nothing came back within 5 minutes | Try again and leave the Drive permission ticked. |
| An account says it **needs reconnecting** every week | The app is in *Testing* (7-day sign-ins) | Click **Reconnect**, or publish the app (note in step 3). |
| The browser didn't open, or the page says *"unable to connect"* | A firewall or security tool blocks `127.0.0.1` | Allow Veltoret on the loopback address and try again. |
| **"Google Drive refused the download"** while playing | Drive's daily download limit for that file was reached | Wait a while and try again. |
| **"Google Drive is full"** while extracting a ZIP, or **Extract** is disabled | Extracting needs free space about the size of the ZIP (it stays until the end) | Free up space (Gmail and Google Photos share it) and empty Drive's trash, then extract again: it continues where it stopped. |

---

## TMDB key

Posters, descriptions, cast and episode guides come from **[The Movie Database (TMDB)](https://www.themoviedb.org)**.

1. Create a free account at **[themoviedb.org/signup](https://www.themoviedb.org/signup)** and verify your email.
2. Open **[Settings → API](https://www.themoviedb.org/settings/api)** and request a key: choose **Personal** use and
   fill in the short form.
3. Copy either the **API Key** (short) or the **API Read Access Token** (long). Both work.
4. Paste it in Veltoret during first-run setup, or later in **Settings → TMDB**. Veltoret checks it right away and
   rescans your library with it.

> [!NOTE]
> **Developers:** instead of typing it, set the `VELTORET_TMDB_KEY` environment variable before starting Veltoret
> (for example `setx VELTORET_TMDB_KEY your-key`, then open a new terminal). Never commit a key to the repository.

| What you see | What it means | How to fix it |
| --- | --- | --- |
| **"TMDB didn't accept this key"** | Typo or wrong value | Copy the key again from [TMDB → Settings → API](https://www.themoviedb.org/settings/api). |
| Videos found but no posters | TMDB key missing or invalid | Update it in **Settings → TMDB**, then **Scan library now**. |

<p align="center"><sub>This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.</sub></p>
