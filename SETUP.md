# 🎬 Veltoret Setup Guide

Welcome! This guide takes you from a fresh clone to Veltoret playing videos from your own
Google Drive. **It takes about 15 minutes** and you only do it once.

> [!TIP]
> **Only want to play videos stored on your device?** Skip Steps 2–6. Build the app (Step 1), get a
> TMDB key (Step 7), and in onboarding tap **Use files on this device**. Google Cloud is only needed
> for Google Drive.

> [!NOTE]
> Veltoret is open source, so it ships **without any keys**. Each person who builds the app
> connects it to their own (free) Google Cloud project and TMDB account. Nothing in this guide costs money.

---

## 🗺️ Overview

| Step | What you'll do | Time |
| :--: | --- | :--: |
| **1** | [Build and run the app](#step-1--build-and-run-the-app) | 3 min |
| **2** | [Find your app's SHA-1 fingerprint](#step-2--find-your-sha-1-fingerprint) | 1 min |
| **3** | [Create a Google Cloud project](#step-3--create-a-google-cloud-project) | 1 min |
| **4** | [Turn on the Google Drive API](#step-4--turn-on-the-google-drive-api) | 1 min |
| **5** | [Set up the Google sign-in screen](#step-5--set-up-the-google-sign-in-screen) | 4 min |
| **6** | [Register the app with Google](#step-6--register-the-app-with-google) | 2 min |
| **7** | [Get a TMDB key for posters](#step-7--get-a-tmdb-key-for-posters) | 3 min |
| **8** | [Connect and enjoy](#step-8--connect-and-enjoy) | 1 min |

**You'll need:**

- ✅ [Android Studio](https://developer.android.com/studio) (latest stable)
- ✅ A Google account (the one whose Drive holds your videos)
- ✅ An Android phone, tablet, or emulator **with Google Play services**

---

## Step 1 · Build and run the app

1. Clone the repository and open the folder in **Android Studio**.
2. Wait for **Gradle sync** to finish (progress bar at the bottom).
3. Pick your device in the toolbar and press **Run ▶**.

You should see the Veltoret welcome screen. Signing in won't work yet — that's what the next
steps fix.

---

## Step 2 · Find your SHA-1 fingerprint

Google identifies your copy of the app by two things: its **package name** and the **SHA-1
fingerprint** of the key that signs it. Android Studio created a debug key for you
automatically, so all you need to do is read its fingerprint.

1. Open the **Gradle** panel — click the 🐘 elephant icon on the **right edge** of Android Studio.
2. Click the **Execute Gradle Task** icon (it looks like a terminal `>_`) at the top of the panel.
3. Type the following and press **Enter**:

   ```
   signingReport
   ```

4. The **Run** window opens at the bottom. Find the block that starts with **`Variant: debug`**
   and copy the value next to **`SHA1:`**. It looks like this:

   ```
   Variant: debug
   Config: debug
   Store: C:\Users\you\.android\debug.keystore
   Alias: AndroidDebugKey
   MD5: ...
   SHA1: A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:A1:B2:C3:D4   👈 copy yours
   SHA-256: ...
   ```

📋 Keep it handy — you'll paste it in **Step 6**.

> [!TIP]
> **Shortcut:** if you already tried to connect in the app and it failed, the error card has a
> **"Setup details for this build"** section showing your exact package name and SHA-1, with
> copy buttons.

<details>
<summary><b>Other ways to get the SHA-1</b> (terminal, keytool)</summary>

**From the Android Studio terminal** (*View → Tool Windows → Terminal*):

```bash
./gradlew signingReport          # macOS / Linux
.\gradlew signingReport          # Windows
```

**With keytool directly:**

```powershell
# Windows (PowerShell)
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -list -v `
  -keystore "$env:USERPROFILE\.android\debug.keystore" `
  -alias androiddebugkey -storepass android -keypass android
```

```bash
# macOS / Linux
keytool -list -v -keystore ~/.android/debug.keystore \
  -alias androiddebugkey -storepass android -keypass android
```

</details>

> [!IMPORTANT]
> The debug key is **different on every computer**. If you build on a second machine, or create
> a signed release build, you'll get a different SHA-1 — just add another client for it in Step 6.

---

## Step 3 · Create a Google Cloud project

1. Go to **[console.cloud.google.com](https://console.cloud.google.com)** and sign in.
2. Click the **project picker** at the top-left (next to the Google Cloud logo).
3. Click **New Project**.
4. **Project name:** `Veltoret` → click **Create**.
5. When it's ready, make sure **Veltoret** is shown in the project picker at the top.

> [!NOTE]
> You may see a banner offering a free trial or asking for billing. **You can ignore it** —
> the Drive API is free for personal use and needs no billing account.

---

## Step 4 · Turn on the Google Drive API

1. Open the **☰ menu** → **APIs & Services** → **Library**.
2. Search for **Google Drive API** and open it.
3. Click **Enable**.

---

## Step 5 · Set up the Google sign-in screen

This is the screen Google shows when you sign in to Veltoret. In the console it's called
**Google Auth Platform** (older consoles call it *OAuth consent screen*).

### 5a. Create it

1. Open the **☰ menu** → **APIs & Services** → **OAuth consent screen**.
   If it says *"Google Auth Platform not configured yet"*, click **Get started**.
2. Fill in the form:

   | Field | What to enter |
   | --- | --- |
   | **App name** | `Veltoret` |
   | **User support email** | your email |
   | **Audience** | **External** |
   | **Contact information** | your email |

3. Tick **I agree to the Google API Services: User Data Policy** → **Create**.

### 5b. Add yourself as a test user ⚠️ *don't skip this*

While your app is in *Testing* mode, Google only lets listed accounts sign in.

1. In the left sidebar, click **Audience**.
2. Under **Test users**, click **+ Add users**.
3. Enter **every Google account you'll use** in Veltoret → **Save**.

### 5c. Allow Drive access

1. In the left sidebar, click **Data Access**.
2. Click **Add or remove scopes**.
3. In the filter box, type `auth/drive`.
4. Tick the row **`.../auth/drive`** — *"See, edit, create, and delete all of your Google Drive files"*.
5. Click **Update**, then **Save** at the bottom of the page.

> [!NOTE]
> **Why full Drive access?** Veltoret's Files tab can browse, rename, move, delete and upload
> anywhere in your Drive, and your library folders can live anywhere. That needs the full
> `drive` scope.

---

## Step 6 · Register the app with Google

1. In the left sidebar, click **Clients** → **+ Create client**.
2. Fill in the form:

   | Field | What to enter |
   | --- | --- |
   | **Application type** | **Android** |
   | **Name** | `Veltoret debug` (any name — only you see it) |
   | **Package name** | `com.pntapps.veltoret` |
   | **SHA-1 certificate fingerprint** | the SHA-1 you copied in **Step 2** |

3. Skip **Verify app ownership (optional)**.
4. Click **Create**.

🎉 That's all for Google. **There's no file to download and no client ID to paste into the
code** — Google recognises the app from its package name and SHA-1.

> [!TIP]
> Forked the project and changed `applicationId` in `app/build.gradle.kts`? Use **your**
> package name here instead.

> [!IMPORTANT]
> Google can take **5–10 minutes** to apply a new client. If sign-in fails right away, wait a
> few minutes and try again.

---

## Step 7 · Get a TMDB key for posters

Posters, descriptions, cast and episode guides come from **[The Movie Database (TMDB)](https://www.themoviedb.org)**.

1. Create a free account at **[themoviedb.org/signup](https://www.themoviedb.org/signup)** and verify your email.
2. Go to **[Settings → API](https://www.themoviedb.org/settings/api)** and request a key.
   Choose **Personal** use and fill in the short form.
3. Copy either the **API Key** (short) or the **API Read Access Token** (long). Both work.

You'll paste it into the app during setup. It can be changed later in **Settings → TMDB**.

<details>
<summary><b>Optional: pre-fill the key for development</b></summary>

Add this line to `local.properties` in the project root (this file is git-ignored, so your key
is never committed):

```properties
tmdb.apiKey=YOUR_TMDB_KEY
```

The key is only built into **debug** builds and pre-fills the onboarding screen. Release builds
never contain a key.

</details>

---

## Step 8 · Connect and enjoy

1. Open Veltoret and tap **Get started**.
2. Tap **Connect Google account** and pick your account. For videos on your phone, SD card or
   USB drive, tap **Use files on this device** (you can use both).
3. Google shows **"Google hasn't verified this app"** — this is normal for your own project in
   testing mode. Tap **Continue**, then **Allow**.
4. **Choose your folders** — pick the folders that hold your movies and your TV shows. Device
   folders open Android's folder picker: browse to the folder, tap **Use this folder**, then
   choose **Movies** or **TV Shows**.
5. **Verify your TMDB key**, then tap **Build my library**.

Veltoret scans your folders, matches every title, and fills your library with posters. 🍿

<details>
<summary><b>📁 How to organise your Drive for the best results</b></summary>

Veltoret understands messy file names, but this layout matches almost perfectly every time:

```
📁 Movies
 ├── 📁 Inception (2010)
 │    └── 🎞️ Inception.2010.1080p.mkv
 └── 🎞️ The.Matrix.1999.2160p.mkv

📁 TV Shows
 └── 📁 Breaking Bad
      ├── 📁 Season 1
      │    ├── 🎞️ Breaking.Bad.S01E01.mkv
      │    └── 📄 Breaking.Bad.S01E01.en.srt   ← loads automatically
      └── 📁 Season 2
```

- **Movies:** include the year — `Title (Year)` or `Title.Year`.
- **TV shows:** one folder per show; episodes named with `S01E01` (or `1x01`).
- **Subtitles:** put `.srt` / `.vtt` / `.ass` files next to the video with the same name.
- Anything that doesn't match can be fixed in-app with **Fix match**.

</details>

---

## 🛠️ Troubleshooting

| What you see | What it means | How to fix it |
| --- | --- | --- |
| **"Google didn't grant access"** and the Google screen closes instantly | Google doesn't recognise this build | Check the **package name** and **SHA-1** in Step 6 match the app (see the app's *Setup details* card). Wait 10 minutes after creating the client. |
| **"Access blocked: Veltoret has not completed the Google verification process"** | Your account isn't a test user | Add it in **Step 5b**. |
| **Error 403: access_denied** | Same as above | Add the account as a test user (**Step 5b**). |
| **"Google sign-in isn't set up for this build"** | No Android client for this SHA-1 | Repeat **Step 6** with the SHA-1 from the error card. |
| Worked on one PC, fails on another | Each computer has its own debug key | Add a second Android client with that PC's SHA-1. |
| **"TMDB didn't accept this key"** | Typo or wrong value | Copy the key again from [TMDB → Settings → API](https://www.themoviedb.org/settings/api). |
| Videos found but no posters | TMDB key missing or invalid | Update it in **Settings → TMDB**, then **Scan library now**. |
| **"Google Drive refused the stream (403)"** while playing | Drive's download limit for that file was reached | Wait a while and try again. |
| **"Can't use this folder"** in the device folder picker | Android doesn't let apps take the whole of internal storage or the Download folder itself | Pick a folder inside it, e.g. `Download/Movies`. |
| Device videos disappeared | The SD card or USB drive was removed | Reconnect it and tap **Scan library now**. |
| Sign-in doesn't open on the emulator | Emulator image has no Google Play | Use an emulator image marked **Google Play**, or a real device. |

---

## ❓ FAQ

<details>
<summary><b>Is my data sent anywhere?</b></summary>

No. Veltoret talks directly to Google Drive and TMDB from your device. There's no Veltoret
server, no analytics and no tracking.

</details>

<details>
<summary><b>Can I add more than one Google account?</b></summary>

Yes. Add each account as a **test user** (Step 5b), then connect it from onboarding or
**Settings → Add Google account**. Libraries from all accounts are merged into one.

</details>

<details>
<summary><b>Do I need to publish or verify the app with Google?</b></summary>

Not for personal use. In *Testing* mode you can have up to **100 test users**, which is plenty
for yourself, family and friends. Publishing to the public requires Google's verification
process for the Drive scope.

</details>

<details>
<summary><b>I'm making a release build. What changes?</b></summary>

Release builds are signed with your release key, which has a different SHA-1. Get it with
`signingReport` (look under `Variant: release`) or, for Play Store builds, from
**Play Console → Protected with Play → Play Store protection → Manage Play app signing**.
Add a new **Android** client for that SHA-1 in Step 6. You can have as many clients as you like.

</details>

---

<p align="center">
  <b>Stuck?</b> Open an issue with a screenshot of the error card and we'll help.<br/>
  <sub>This product uses the TMDB API but is not endorsed or certified by TMDB.</sub>
</p>
