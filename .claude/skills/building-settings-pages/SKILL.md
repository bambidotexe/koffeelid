---
name: building-settings-pages
description: Use when adding, removing, renaming, moving or rewording anything in KoffeeLid's Settings window (App/Sources/UI/Settings*.swift, its words in App/Resources/Localizable.xcstrings) - a setting, a switch, a choice, a status, a group, a page, a hint, a warning, a button, any sentence the window shows - when a new feature needs a user-facing setting, or when building a settings or preferences window for a new macOS app that must look and read like SnappySnap's.
---

# Building settings pages

Origin: `/Users/Rubens/Projects/snappy-snap/.claude/skills/building-settings-pages`. A rule the owner
changes there is changed here too.

## Overview

The Settings window has one shape, and every change keeps it. **A page is a column of groups. A group
is a title, a card of rows, and under the card, outside it, a hint, then warnings, then notes. A row is
a control and its label and nothing else.** Everything below is that contract, its numbers, and how the
words are written. The owner fitted every rule here by eye, round after round. Do not improve on them:
reproduce them.

**Two situations:**

| You are in | Do this |
|---|---|
| **KoffeeLid** | The kit exists. Build from `App/Sources/UI/SettingsKit.swift`. Never write a `Form`, a `Section`, a `GroupBox` or a hand-made row. Go to *Evolving the window*. |
| **A new app** | Copy `reference/SettingsKit.swift` and `reference/SettingsWindow.swift` beside this file as they are (both type-check alone, Swift 6, macOS 26), edit the three places marked `EDIT`, then build pages from the kit. |

## The window

- A real `NSWindow` with an `NSToolbar`, `toolbarStyle = .preference`, `displayMode = .iconAndLabel`,
  no customization, one selectable item per page: **the SF Symbol above, the title below**. Never a
  SwiftUI `Settings` scene, never a `TabView`, never a sidebar.
- The window's title is the shown page's title. Style: titled, closable, miniaturizable, **not resizable**.
- One `NSHostingController`, `sizingOptions = []`. Content width **640**. **Height follows the shown
  page**: the page reports its natural height, the window resizes around its **top-left** corner,
  animated, on a page switch and whenever a page gains or loses a line. Cap: the screen's
  `visibleFrame.height - 140`; beyond it the page scrolls.
- First show: sized, then centred, never the other way round. No visible jump.

## Pages and groups

- **A page is a subject the user thinks in** (in SnappySnap: Snapping, Snap Bar, Handles), never a kind of control and
  never a layer of the code. Title Case, one or two words, one outline SF Symbol that pictures the subject.
- Order: **General** first, then the features in the order a user meets them, then **System** last.
- **General** is, in this order: the app icon alone (`SettingsAppIcon`, 144 pt, centred); **Startup**
  (Launch at login, Show in menu bar, no hint, and one **note** naming the way back to this window when
  the icon is hidden); **Updates** (its contract is below); **Quit** (one destructive `ButtonRow`, no
  hint, no note).
- **System** is what the app needs from the OS: permissions, conflicts with the OS's own features,
  compatibility.
- **A setting lives with the one feature it affects**, whatever its type suggests. SnappySnap's
  Animation sits under Snap Assist because that is the only thing it paces.
- **A group is what the user thinks of together**: usually 2 to 4 rows under one explanation. A
  dependent switch sits directly under its parent, in the same card, disabled with it. A group of one
  row is right only when that row needs an explanation of its own. One group per switch by reflex is wrong.
- Group title: a short noun phrase, sentence case ("Edges and corners", "Smallest window sizes").

## What goes where

| You have | It is | Where, and how |
|---|---|---|
| An on/off choice | `ToggleRow` | In the card. The label says what happens. |
| 2 to 4 options named by one short word | `SegmentedRow` | In the card, control at the trailing edge. The hint says what the words mean. |
| 2 to 4 options the user can **see** | `TileRow` | Picture tiles. The group's hint describes **the selected option only**: the pictures already show them all. |
| Any other multiple choice (five options or more, long names) | **No control has been chosen for it yet: stop and ask the owner.** | That is the answer, not a gap. Never a radio group, and never a pop-up menu on your own. |
| A fact about the system or a result | `StatusRow` | In the card. See *Statuses*. |
| An action | `ButtonRow` | In the card, button at the trailing edge, on a row of its own. Never beside a status. |
| What the group does, what a switch costs | **hint** | Under the card, grey. One to three short sentences, or none. |
| Something the user must fix | **warning** | Under the hint, orange triangle. **Only while it is wrong.** Says exactly what to flip and where. |
| The one thing the user must not miss | **note** | Under the warnings, blue info mark. A hidden gesture, the way back from a switch that hides something, a dependency, a limit, a reassurance. One per group, rarely two. |
| A detail only a bug report needs (an identifier, a symbol name) | tooltip | `.help(...)` on the row. Never on the row itself. |
| Something tall (an editor, a list, an example) | inside a card | Height 240, its own background hidden so the card shows through. |

**Nothing explanatory is ever inside a card.** An orange sentence between two rows is a warning in the
wrong place.

In SnappySnap:

```swift
SettingsGroup(title: "Gap",
              hint: "Snapped windows keep \(Unit.points(Fixed.gap)) from the screen edges and from each other. Off, they touch.",
              warnings: marginsOff ? ["Also turn on “Tiled windows have margins” in Desktop & Dock. macOS then leaves the same gap when it places a window itself, like a double click on a title bar."] : []) {
    ToggleRow("Leave a gap around snapped windows", isOn: $store.settings.gapEnabled)
    ToggleRow("Keep every window inside the gap", isOn: $store.settings.correctOversizedWindows,
              enabled: store.settings.gapEnabled)
    if store.settings.gapEnabled {
        StatusRow("macOS margins for tiled windows", mark: marginsOff ? .warning("Disabled") : .good("Enabled"))
        if marginsOff { ButtonRow { Button("Open Desktop & Dock Settings") { open() } } }
    }
}
```

## Statuses

**A state is always one row: what is reported on the left in ordinary text, and at the trailing edge a
symbol and ONE word, both in the state's colour, at the same size as everything else.**

| Mark | Symbol | Colour | Means |
|---|---|---|---|
| `.good` | `checkmark.circle.fill` | green | as it should be |
| `.info` | `info.circle.fill` | blue | worth knowing, nothing to fix |
| `.warning` | `exclamationmark.triangle.fill` | orange | to be fixed, or did not work |
| `.failure` | `xmark.circle.fill` | red | refused, or wrong |
| `.busy` | a small spinner | secondary | still happening |

- The left text **names the thing** ("Accessibility permission", "macOS edge tiling"). Never "Status".
- The word is a participle or an adjective, from this vocabulary: **Granted / Denied** (a permission),
  **Enabled / Disabled** (any switch of the OS or of another app, never On / Off, never Yes / No, never
  "Not granted"), **Available / Missing**, **Valid / Invalid**, **Failed**. No ellipsis
  on a busy word: "Checking". A sentence is allowed only when the state **is** a message: an update's
  answer ("Version 1.2.0 is available"), an error's reason. It wraps, trailing aligned.
- **Red or orange:** `.failure` is a refusal or an input that is wrong and blocks (a permission denied,
  text that does not parse). Something that only did not work this time (a check that could not reach
  the network, a download that failed) is `.warning`.
- **Nothing to report yet is no mark at all** (`mark: nil`), never a placeholder like "Not checked".
- **The colour follows whether the state is what it should be, not whether it is on.** "Disabled" is
  green when disabled is right. A state that must match another setting is green whenever they agree.
- **A state the user can fix** is three things: the row; while it is orange, a `ButtonRow` to the place
  it is fixed and a **warning** naming the exact switch; once green, button and warning go and **the
  row stays**, so the link stays visible.
- **When a state changes what the user should do, the button is replaced, not joined**: "Update"
  replaces "Check for Updates". Only that one action is `.borderedProminent` with `.tint(.blue)`.
  Quit is `role: .destructive`. Every other button is plain.
- A state read from the system follows it while the window is open (SnappySnap: `SystemStatus`, every
  2 s, started and stopped by the window, never by a view's `onAppear`).

### The Updates group

Two rows and nothing under them: `StatusRow("AppName 1.0.0", mark:)`, then **one** `ButtonRow`. No hint. The
app also checks on its own, shortly after launch and then once a week: what such a check finds shows here
exactly as the answer to a press would, without a spinner, and what it could not find out stays silent. Update
opens the update window, which is a window of its own: the fetch, its progress and "Install and Relaunch" are
there, never in this group.

| The moment | The version row's mark | The button |
|---|---|---|
| before the first answer | none | Check for Updates |
| asking, because the button was pressed | `.busy("Checking")` | disabled |
| nothing newer | `.good("Up to date")` | Check for Updates |
| a newer release | `.info("Version 1.2.0 is available")` | **Update**, `.borderedProminent`, `.tint(.blue)` |
| no release published | `.warning("No release published yet")` | Check for Updates |
| a press could not ask | `.warning("Could not check: <reason>")` | Check for Updates |
| the last install did not end with the new version running | `.warning("Update failed: <reason>")` | Check for Updates, and Update again once a check has found the release |

### The update window

The same in every app. A window of its own, titled "Software Update", never a sheet and never a page: the app
icon, then "AppName 1.2.0" in `.headline`, one status line in secondary, a linear bar, an orange warning line
(the triangle, then the sentence) only while an install is refused, and two buttons at the trailing edge, the
second being the window's one main action: `.borderedProminent`, `.tint(.blue)`, pressed by Return. It is as
tall as what it says and keeps its top-left corner when that changes. Closing it is Cancel.

| Phase | The status line | The bar | The buttons |
|---|---|---|---|
| fetching | "Downloading: 1.2 MB of 2.8 MB", or "Downloading" with no total | follows the bytes | Cancel · Install and Relaunch, disabled |
| making it ready | "Preparing the update" | indeterminate | the same |
| ready | "Ready to install. AppName will quit and reopen." | full | Cancel · **Install and Relaunch** |
| the app cannot replace itself | "AppName cannot replace itself where it is installed. Open the disk image and drag AppName to Applications, then quit and reopen it." | none | Cancel · **Open Disk Image** |
| installing | "Installing" | indeterminate | both disabled, and the window does not close |
| failed | "Update failed: <reason>" | none | Close · **Try Again** |

The words follow the ten rules below. Its numbers (460 wide, the icon at 64, 16 from icon to text, 10 between
lines, 8 between buttons, 20 around) were chosen by the agent that built it, not fitted by the owner: they are
the owner's to refit, in one app first and then in the other two.

## The words

1. **Default size, always.** The only fonts: `.body`, `.headline` (group titles), and
   `.system(.body, design: .monospaced)` for what is code. Never `.caption`, `.callout`, `.footnote`,
   `.subheadline`, never a smaller `controlSize` on text.
2. **No long dash, anywhere the user reads**: none of `— – ‒ ― ‐ ‑ −`. Write two sentences, or use a
   comma or a colon. ASCII `-`, `×`, `…` and curly quotes are fine.
3. **A key is its symbol, then its name, at every mention**, titles included: ⌥ Option, ⌘ Command,
   ⌃ Control, ⇧ Shift.
4. **Short, human, no jargon.** Write for the person using the app, not the one who wrote it. "App",
   never "application". No API, interface, symbol, identifier, process, feed, daemon. A word ordinary
   people know stays ("haptic feedback").
5. **A label says what happens, gesture first**, sentence case, no full stop: "Drag to the left or
   right edge for a half", "Hold ⌥ Option to snap to halves from anywhere", "Show handles between windows".
6. **A hint earns its place or is deleted.** It stays only if it says what the label cannot: what
   happens, or what it costs. "Launch at login", Updates and Quit have none. The owner deleted "only
   checks when you ask" and "closing this window does not quit" as useless.
7. **State the trade where there is one**, as "On, … Off, …", with the cost in plain words. The risk
   itself is the note.
8. The OS's own switches are quoted in curly quotes, exactly as the OS names them, with the pane:
   In Desktop & Dock, turn off “Drag windows to screen edges to tile”.
9. A number in a sentence is interpolated from the constant that owns it, never retyped.
10. Buttons are Title Case verbs ("Check for Updates", "Open Accessibility Settings"). `…` only when
    more input follows ("Add…").

| Before | After |
|---|---|
| hint: "Tidies instantly by calling a Finder interface Apple hasn't documented — a macOS update could change it without notice…" | hint: "On, tidying is instant. Off, it takes about a second and always works." note: "This relies on a part of macOS that Apple does not document, so a macOS update can break it." |
| hint: "Keep Option held until you release the file — everything else is still tidied." | hint: "Keep ⌥ Option held until you let go of the file. Only that file stays where you dropped it." |
| row: `Full Disk Access` / `Not granted` under it, a dot, a button beside | `StatusRow("Full Disk Access", mark: .failure("Denied"))`, then a `ButtonRow` |

## The numbers

All in `SettingsMetrics`. Change one only on the owner's word, and then in the kit, in this table and in
`reference/SettingsKit.swift` in the same commit.

| | pt | | pt |
|---|---|---|---|
| content width | 640 | row: horizontal inset | 10 |
| page margin, left and right | 16 | row: padding above and below | 5 |
| page top / bottom | 10 / 14 | row: minimum height | 30 |
| between groups | 12 | row: between its parts | 8 |
| title to card, card to hint | 5 | divider: leading inset | 10 |
| hint to first callout (no hint: 5) | 4 | status: symbol to word | 4 |
| between callouts | 3 | status: widest mark before it wraps | 400 |
| callout: symbol to text | 5 | tall content inside a card | 240 |
| title, hint, callout inset | 10 | app icon (2 above it) | 144 |
| card radius | 10 | screen height left alone | 140 |

Card: fill `Color.primary.opacity(0.05)`, stroke `Color.primary.opacity(0.08)` at 0.5. Switch:
`.toggleStyle(.switch)`, `.controlSize(.mini)`, label hidden but set. Segmented: `.labelsHidden()`,
`.fixedSize()`. Disabled row: label goes secondary, never only the control; a tile row goes to 0.5 opacity.
Tiles: 8 apart, padding 8, radius 8, picture then 6 then title; unselected fill primary 0.05 and title
secondary; selected fill accent 0.18, 1.5 accent stroke, title primary. Sheet: `.headline` title, a
`Form`, fields shown only when they can be edited, Cancel and the action with their key equivalents,
padding 16, width 420.

## Evolving the window (KoffeeLid)

Files, under `App/Sources/UI`: `SettingsKit.swift` (the kit, `SettingsMetrics`), `SettingsWindow.swift`
(`SettingsPageID`: pages, titles, symbols; the toolbar, the height), `SettingsModel.swift` (what the pages
observe: bindings onto `Preferences.shared`, the states read from the system while the window is open, and
`SettingsFormat`, how a slider's value is written), `Settings…Page.swift` (one per page), `Permissions.swift`
and `Hooks.swift` (`PermissionCatalog` and `HookCatalog`, the single lists of grants and hooks, shared with
the onboarding). The window is built once and re-shown by `AppDelegate.showSettings()`. Two rules live in
`Sources/KoffeeLidCore`, with their tests: `SettingsStatus` (which of the five marks a grant or a hook takes)
and `UpdatePanel` (the Updates table above). A page words a state; it never decides its colour.

This app's kit has two rows SnappySnap's does not, both chosen by the owner: `SliderRow`, a number on a
range (the label, a slider 220 wide, the value in body text with fixed-width digits in a column 64 wide:
`SettingsMetrics.sliderWidth` and `valueWidth`, two numbers the owner fitted like the others), and
`PopUpRow`, used once, for the six lid-close sounds. Neither makes another pop-up menu acceptable: for a new choice the table above still says stop
and ask. The update check here has no "no release published" answer, so that row of the Updates table
never shows.

**Adding a setting:**
1. Pick the page by subject and the group by what it governs. A new group only if no group's
   explanation covers it; a new page only if the subject has two groups and fits nowhere.
2. A UserDefaults-backed property on `Preferences` (`App/Sources/Preferences.swift`) and its registered
   default; the coordinator reacts in `KoffeeLidController.preferenceChanged(_:)`. `Preferences.onChange`
   has exactly one subscriber, the coordinator: a page never sets it. An effect tunable is a field of
   `EffectParameters` in `KoffeeLidCore`, with its clamp and its test (`docs/development.md` § How to add
   things). No test pins the roster of preferences: the table in `docs/functional.md` § Settings and
   defaults is the roster.
3. The row, from the kit. If it depends on a switch, put it under it with `enabled:`.
4. The words, by the ten rules, in both languages. Ask of each hint and note: would the owner call it
   useless? Every string is `L("English key")` with its `fr` entry in
   `App/Resources/Localizable.xcstrings`, edited in place. The French follows the same ten rules. A status
   word has one French form, so the left text of its row is written to agree with it: Granted / Denied
   are "Accordée / Refusée" (the left text is "Autorisation …"), Enabled / Disabled "Activé / Désactivé",
   Available / Missing "Disponible / Manquant", Failed "Échec", Up to date
   "À jour", Checking "Vérification", Downloading "Téléchargement".
5. A grant or a hook is one entry of `PermissionCatalog` or `HookCatalog`, which the onboarding reads too.
6. `docs/functional.md` § User interface (the pages and their groups), § Settings and defaults (the
   table) and the section of the behaviour itself; one line in `docs/manual-checks.md`. A request that
   contradicts a written rule is a question to the owner first (`CLAUDE.md` § Changing behaviour).

**Changing how anything looks or reads** (a number, a colour, a control, the structure, a page split):
only the owner can judge it, in the running app. Build it as a POC round with the `bare` skill and hand
it over. Do not judge the look yourself and do not commit before the owner says it is done.

## Verify

```sh
xcodebuild -project KoffeeLid.xcodeproj -scheme KoffeeLid -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E 'error|warning:|BUILD'
rg -n '"[^"]*[—–‒―‐‑−][^"]*"' App/Sources/UI/Settings*.swift App/Sources/UI/Permissions.swift App/Sources/UI/Hooks.swift   # nothing
rg -n '[—–‒―‐‑−]' App/Sources/UI/Settings*.swift                                     # nothing
rg -n '\.font\(\.(caption|callout|footnote|subheadline|title)' App/Sources/UI/Settings*.swift  # nothing
rg -n 'radioGroup|Form \{|Section|GroupBox|TabView' App/Sources/UI/Settings*Page.swift  # nothing
rg -n '"[^"]*\b(Option|Command|Control|Shift)\b[^"]*"' App/Sources/UI/Settings*.swift | rg -v '⌥ Option|⌘ Command|⌃ Control|⇧ Shift'  # nothing
```

Then run it and let the owner look: `script/build.sh Debug` and the bundle's binary with `--open-settings`
while the installed app is not running, or `script/install.sh`, which refuses while KoffeeLid is armed
(`CLAUDE.md` § Rules). The window has no automated test.

## Red flags

| You are about to | Instead |
|---|---|
| write `Form`, `Section { } footer:`, `TabView`, a `Settings` scene | the kit and the toolbar window |
| put a sentence, a coloured label or a caption inside a card | hint, warning or note, under the card |
| build a status from a dot, two lines, "On/Off" text or a button on the same row | `StatusRow` with one of the five marks, the button on its own `ButtonRow` |
| give every switch its own group and its own hint | group what belongs together, delete the hints that say nothing |
| reach for a radio group or a pop-up menu | segmented, tiles, or ask the owner |
| explain how it works ("undocumented interface", "release feed") | say what the user gets and what it can cost |
| make text smaller so it fits | shorten the sentence |
| tune a spacing number because it looks better to you | you cannot see it; the owner fitted it |
