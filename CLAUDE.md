# CLAUDE.md — Veltoret

Three native apps with one design and one set of rules:

- `android/` — Kotlin / Compose / Media3 (open this folder in Android Studio). Read `android/CLAUDE.md`.
- `windows/` — C# / .NET 10 / WPF / LibVLC. Read `windows/CLAUDE.md`.
- `mac/` — Swift / SwiftUI + AppKit / VLCKit. Read `mac/CLAUDE.md`.
- `docs/spec/` — the shared behaviour specs (screens, strings, rules) for all three.

## Working across apps

- The user keeps the three apps' UI, wording and behaviour in sync. A feature or fix in one app usually belongs in
  all three: update `docs/spec/` first, then each app, and port the unit tests (e.g. a new filename-parser corpus
  line goes into every platform's corpus test). Say plainly which platforms you changed and which you couldn't
  build or test here.
- Each app's "Don't break these" rules apply to its port too (strict TMDB matching, parser corpus, MANUAL/IGNORED
  survive rescans, device copies win, migrations never drop data, no gradients, Fraunces + Inter).

## License and credit (keep these intact)

- GPL-3.0 (`LICENSE`) with additional terms in `NOTICE` (section 7): forks must keep "Developed by PNT Apps —
  https://www.pntapps.com" in their README and "Developed by PNT Apps" (linking pntapps.com) in the app's About /
  Settings, mustn't present themselves as the original, and mustn't use "PNT Apps"/"Veltoret" names or icons as theirs.
- Every app's About / Settings must keep showing "Developed by PNT Apps" with the pntapps.com link, the GPL licence
  and TMDB's attribution. Never remove them.
- Never commit secrets (TMDB keys, OAuth client JSON, keystores, tokens) or large binaries (`mac/Vendor/VLCKit.xcframework`).
- Releases are tagged per platform: `android-vX.Y.Z`, `windows-vX.Y.Z`, `mac-vX.Y.Z`.
