# Veltoret

**Your movies and shows, as a private cinema.**

Developed by PNT Apps — https://www.pntapps.com

Veltoret turns the video files in your Google Drive, on your device and on your network shares into a beautiful
Movies and TV Shows library, with posters, cast and episode guides from TMDB, and plays them with a full-featured
player. It's free and open source, with no server: your files stay where they are.

> Veltoret is a player for your own files. It doesn't find, host or download content; please use it only with media
> you own or have the rights to.

## Apps

| Platform | Folder | Built with | Docs |
| --- | --- | --- | --- |
| **Android** (phones, tablets, Android TV) | [`android/`](android) | Kotlin, Jetpack Compose, Media3 | [README](android/README.md) · [Setup](android/SETUP.md) |
| **Windows** 10/11 | [`windows/`](windows) | C#, .NET 10, WPF, LibVLC | [README](windows/README.md) · [Setup](windows/docs/SETUP.md) |
| **Mac** (macOS 14+) | [`mac/`](mac) | Swift, SwiftUI + AppKit, VLCKit | [README](mac/README.md) · [Setup](mac/docs/SETUP.md) |

The three apps share one design (dark, flat, amber accent, Fraunces and Inter), the same features and wording, and the
same library rules: the filename parser, strict TMDB matching, watch progress and the SQLite schema are ported line
by line between them, with the same unit-test corpus.

## Repository layout

```
android/      Android app (Gradle project: open this folder in Android Studio)
windows/      Windows app (Veltoret.sln, installer/)
mac/          Mac app (Swift package; Scripts/build-app.sh builds Veltoret.app)
docs/spec/    Shared behaviour specs: every screen, string and rule, for all three apps
LICENSE       GNU GPL v3.0
NOTICE        Additional terms (credit to PNT Apps) and third-party notices
```

## Keeping the apps in sync

A change to behaviour, wording or design belongs in all three apps. Update `docs/spec/` first, then each app, and
port unit tests alongside (for example a new line in the filename-parser corpus goes into every platform's corpus
test). Each folder's `CLAUDE.md` lists the rules that must not break.

## Credit to PNT Apps — required

If you use, fork, modify or redistribute Veltoret, you must keep the credit to PNT Apps:

- in your README or main documentation: **"Developed by PNT Apps — https://www.pntapps.com"**, and
- inside the app, where users can see it (for example an About or Settings screen): **"Developed by PNT Apps"**
  linking to https://www.pntapps.com.

You may add your own credits next to it. This is an additional term of the license (GPL-3.0, section 7(b)); see
[NOTICE](NOTICE).

A modified version must not be presented as the original Veltoret or as an official PNT Apps release, and the names
"PNT Apps" and "Veltoret" and their logos/icons may not be used as the name or icon of your app.

## License

Copyright © 2026 PNT Apps.

Veltoret is licensed under the [GNU General Public License v3.0](LICENSE) with the additional attribution terms in
[NOTICE](NOTICE).

In short: you may use, study, change and share these apps, but if you distribute them or a modified version, you must
release your source code under the same GPL-3.0 license (including the attribution terms) and keep the credit to
PNT Apps.

Bundled fonts are under the SIL Open Font License 1.1 and libraries under their own licenses (Apache 2.0, LGPL, MIT,
BSD); see [NOTICE](NOTICE) and each app's README.

## Attribution and trademarks

This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB. Movie and
TV metadata and artwork come from [The Movie Database (TMDB)](https://www.themoviedb.org/).

Google Drive, Chromecast and Google TV are trademarks of Google LLC. Windows is a trademark of Microsoft Corporation.
Mac and macOS are trademarks of Apple Inc. Veltoret is an independent project and is not affiliated with, endorsed or
sponsored by Google, Microsoft, Apple or TMDB.
