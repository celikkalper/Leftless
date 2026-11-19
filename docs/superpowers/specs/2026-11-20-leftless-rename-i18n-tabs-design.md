# Leftless — Rename, Localization, History Tab: Design (short)

Date: 2026-11-20 · Status: approved by user in chat · Builds on `2026-11-19-kalintisiz-uninstaller-design.md`

## Intent
The app ships to an international audience: it needs an English name, a full multi-language UI,
and a History screen that is easy to find.

## Decisions (user)
- **Name:** **Leftless** (free on the App Store per the user's check).
- **Languages:** English (source/default), Turkish, German, French, Spanish, Japanese, Portuguese.
- **History access:** a two-segment control centred in the window toolbar — `Apps | History (N)` — with
  ⌘1 / ⌘2. The "Geçmiş" row at the bottom of the sidebar is removed.

## Decisions (mine — user may correct)
- Bundle ID `com.leftless.app`; product/module names `Leftless`, `LeftlessCore`, tests `LeftlessCoreTests`.
- Portuguese = **pt-BR**.
- Language follows the macOS system language; per-app override is macOS's own
  System Settings › General › Language & Region › Applications. No in-app language menu.
- Strings live in String Catalogs (`Localizable.xcstrings`) in both the app and the core module, with
  **English source keys**. Translations by Claude; native-speaker review recommended before release.
- Core never persists human text: failure reasons in history records become stable codes
  (`FailureReason`), localized only at display time. Old records carrying Turkish text still display as-is.
- History migration: on launch, if `~/Library/Application Support/Kalintisiz/History` exists and the new
  `Leftless/History` does not, move the folder (no copy/delete). Old bundle ID `com.kalintisiz.app` stays
  excluded from the app list alongside the new one.
- `N` in `History (N)` = number of records whose status is restorable or partially restorable; hidden when 0.
- In the History tab the window shows the history list full-width (no apps sidebar).
- Full Disk Access is tied to the bundle ID, so it must be granted again after the rename (README note).

## Approaches considered (localization)
| | Approach | Trade-off |
|---|---|---|
| **A** | **String Catalogs (.xcstrings), English keys** — chosen | Xcode-native, plurals, one file per module; needs Xcode toolchain (now installed) |
| B | Legacy `.strings` per language folder | Works anywhere, but 7 files per module, no plural support |
| C | Hand-rolled dictionary in code | No tooling; translators can't use standard tools |

## Non-goals
In-app language picker, right-to-left languages, renaming the git branch or repo folder.

## Left to the builder
Exact key naming, translation wording, how the toolbar picker is laid out within macOS conventions.
