<p align="center">
  <img src="docs/assets/icon.png" width="256" height="256" alt="KoffeeLid icon">
</p>

<h1 align="center">KoffeeLid</h1>

<p align="center">
  <strong>Close the lid. The work goes on.</strong><br>
  A menu-bar app that keeps your MacBook awake with the lid shut, on its own while Claude Code, Codex,
  Copilot, OpenCode or a terminal command is running. It folds the desktop away like the iPhone Duo closing,
  with a sound to match.
</p>

<p align="center">
  <a href="https://github.com/bambidotexe/koffeelid/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/bambidotexe/koffeelid?color=2ea44f"></a>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-MacBook-333333?logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6%20toolchain-F05138?logo=swift&logoColor=white">
  <img alt="AppKit + Metal" src="https://img.shields.io/badge/AppKit-%2B%20Metal-1f6feb">
  <img alt="Unit tests" src="https://img.shields.io/badge/tests-423%20passing-2ea44f">
</p>

## The problem

You start a long turn in Claude Code, Codex, Copilot or OpenCode, a build, a deploy, a download. Then you close the lid to go make a coffee,
catch a train, or move to the couch with your phone. macOS puts the Mac to sleep, the session dies, and the
prompt you send from your phone twenty minutes later lands on a machine that is no longer listening.

KoffeeLid keeps the Mac awake with the lid closed. The point is that it knows *when* to do it.

## It arms itself while you work

This is the headline feature. Set it up once, from onboarding or Settings › Auto-Arm, and KoffeeLid watches five
things:

- **Claude Code.** Hooks in `~/.claude/settings.json` report every session event: a prompt sent, a tool
  running, a turn finished. While a session is working, the Mac is armed. When the turn ends, KoffeeLid waits **30 minutes**
  before letting go, so a follow-up prompt sent from your phone still finds the Mac awake.
- **Codex.** The same, through hooks in `~/.codex/hooks.json`, which KoffeeLid also marks as trusted in
  `~/.codex/config.toml` so that Codex runs them without a visit to its `/hooks` screen. Esc ends the turn for
  KoffeeLid the moment it ends it for Codex.
- **Copilot.** The same, through a hook file KoffeeLid owns whole, `~/.copilot/hooks/koffeelid.json` — no
  trust step needed. Ctrl+C ends a turn Copilot's own hooks cannot report; KoffeeLid catches it from Copilot's
  own session log instead.
- **OpenCode.** OpenCode takes no hooks, so KoffeeLid installs a small plugin instead,
  `~/.config/opencode/plugins/koffeelid.js`, that a running server picks up by itself within a second.
- **The terminal.** A zsh snippet reports every command that runs longer than a few seconds, as it starts and ends. A `make`, a `docker
  compose up`, a `rsync`: closing the lid while one runs no longer kills it. When the command finishes,
  KoffeeLid waits a minute, then stands down.

You never touch the menu bar. The cup up there just changes its face while the app is holding the Mac awake
for you, and goes back to empty when there is nothing left to wait for. Come back and touch the keyboard
or trackpad during the wait, and the wait ends on the spot. The hold-off exists for the remote you, not the
one sitting at the desk.

Two things make this trustworthy:

- **A manual choice is never overruled.** Pick Off, Armed, or Armed + screen on by hand and the auto-arm runs
  alongside it, never instead of it. The Mac is armed while *either* says so.
- **"Disarm once finished."** One menu item for the evening. The current work finishes, a minute passes, and
  everything ends: the auto-arm skips its long wait, the manual mode releases too.

## The close deserves a show

<p align="center">
  <img src="docs/assets/lid-effect.gif" width="640" alt="Closing a MacBook with KoffeeLid armed: the desktop stays upright behind the glass and folds away like a foldable phone, then the screen locks on reopen">
</p>

The iPhone Duo pulls what is on its screen into the new shape as you fold it shut. KoffeeLid does the same with your
desktop, iPhone Duo style. As the lid comes down, the desktop behaves like an **inner screen standing still behind the glass**:
anchored at the hinge, it grows as the display tilts over it, narrows toward the top as it recedes, slips out of
view above and blurs where the glass is furthest from it. The edges never end on a hard line: they melt into the
dark and the picture shades off toward the top, so the illusion holds from any angle you look at it.

It plays only while closing, runs backward if you change your mind before the lid shuts, and captures nothing
until the lid actually moves. It is drawn live from the lid's own angle sensor, smoothed on every frame.

And it has a **sound**. Six short clips to choose from (a blip, a bloop, a chime, a tick…), played at the moment
the lid shuts. Optionally at a fixed volume, so the close sounds the same whether the Mac was muted or blaring.
It plays again when you unplug the charger or a display from a closed, armed Mac, so a Mac leaving the desk
for a bag tells you it is still awake.

**🌐 Fn + close** arms for a single close without changing anything else: hold 🌐 Fn, tilt the lid, and the
fold appears as it passes the inner screen's angle. Change your mind before the lid shuts (reopen it a little,
or just stop) and the arm is cancelled. Once shut, the arm lasts until you log back in, so nobody can stop your
work by lifting the lid and closing it again. Ideal when you did not set up auto-arm, or when you want the show
on a Mac that is otherwise Off.

## Three modes

<p align="center">
  <img src="docs/assets/menubar.png" width="720" alt="Menu bar cups: Off (empty), Auto-armed (closed eyes wearing the icon of the app at work), Armed (closed eyes), Armed + screen on (round eyes)">
</p>

| | Off | Armed | Armed + screen on |
|---|---|---|---|
| Lid closed | Mac sleeps (macOS default) | Mac keeps working, screen dark | same |
| Lid open | nothing | normal | display never sleeps, no screen saver, no auto-lock |
| Reopen | nothing | screen locks | screen locks, login page stays lit |

*Armed + screen on* replaces the keep-awake utility you were running next to your lid tool: one app, one cup.

Switch however you like:

- **Menu bar**: left-click picks a mode, right-click cycles Off → Armed → Armed + screen on → Off (a
  right-click on a mode older than three seconds goes straight to Off).
- **Shortcuts**: `⌃⌥⌘L` toggles Armed, `⌃⌥⌘K` toggles Armed + screen on. Each has its own switch.
- **Command line**: `koffeelid arm | off | caffeinate | toggle-armed | toggle-caffeinate | status | settings |
  install-hooks [claude|codex|copilot|opencode] | uninstall-hooks [claude|codex|copilot|opencode] | shell-init
  zsh`. `status` reports the mode, the lid, the sleep lock and what is currently keeping the Mac awake
  (`auto-armed (activity) · activity: 1 session working, 1 command`).
- **URLs and Shortcuts.app**: `koffeelid://caffeinate`, and App Intents for every verb.

## It gets out of the way when it should

- **External display.** Arming is allowed, but the darkening, the sound, the fold and the lock on reopen stand
  by while a monitor is connected (macOS runs its own closed-lid mode). A display appearing on a closed lid
  locks the screen immediately.
- **Low battery.** Below your threshold on battery power nothing arms and an armed session ends. On AC power
  everything is allowed; unplugging below the threshold disarms at once.
- **Charger and display changes.** Plugging in the charger, or a display coming and going, can make macOS put
  a closed Mac to sleep on the spot. KoffeeLid holds the session through it and, once the sleep lock is set up
  (one administrator password, from onboarding or Settings › System), that sleep never even starts.
- **Overheating, a sleep started by something else, a crash.** All end the session and give lid sleep back to
  macOS. After a crash the app is reopened for you, and lid sleep is given back again at that launch.

Everything that returns the app to Off also gives lid sleep back to macOS. That rule has no exceptions in the
code.

## Install

Download `KoffeeLid-<version>.dmg` from the [latest release](https://github.com/bambidotexe/koffeelid/releases/latest),
open it, drag `KoffeeLid.app` to Applications and launch it. A four-page onboarding asks for what it needs: the
sleep lock (administrator password, once), Login Items (crash recovery), Screen Recording (the fold),
Input Monitoring (optional: only the built-in keyboard's 🌐 Fn key then arms the gesture), notifications (optional),
and offers to set up the Claude Code hooks, the Codex hooks and the zsh snippet. Settings › Health then shows at a glance whether
everything KoffeeLid relies on is in place and working, in green, orange or red, and says where to put right
whatever is not, with a few readings beside it: what KoffeeLid is doing, the lid's angle, when each hook last
reported.

After that KoffeeLid keeps itself up to date. It looks for a newer release when it starts and once a week, and
tells you with a notification. Click Update, there or in Settings › General, and a small window fetches the
release and checks it while the app runs; Install and Relaunch then swaps the app, reopens it and says how it
went. Nothing is fetched or installed without a click. An update never leaves a closed Mac armed behind a dead
app: the install is refused while quitting would put the Mac to sleep, and the new version goes back to the
mode that was on.

Settings › General › Uninstall takes KoffeeLid off the Mac again: the sleep lock, what starts it at login, what
it added to Claude Code, to Codex, to Copilot, to OpenCode and to the shell, its settings and its logs, and
then the app itself.

Releases are signed with the Wooflab team's Developer ID and notarized, so they open on any Mac without a
Gatekeeper warning.

## Requirements

- Apple silicon MacBook, macOS 15 or later. The lid gesture and the fold need the built-in lid-angle sensor
  (Mac16,x and later); arming from the menu, the shortcuts, the command line and the hooks works on any MacBook.
- Screen Recording permission for the fold, Login Items approval for crash recovery, and the sleep lock (one
  administrator password): all from the onboarding or Settings › System.
- For auto-arm: Claude Code (the hooks go into `~/.claude/settings.json`, backed up first), Codex (the hooks go
  into `~/.codex/hooks.json` and their trust into `~/.codex/config.toml`, both backed up first), Copilot (a
  hooks file KoffeeLid owns whole, `~/.copilot/hooks/koffeelid.json`), OpenCode (a plugin KoffeeLid owns
  whole, `~/.config/opencode/plugins/koffeelid.js`) and zsh (the snippet goes into `~/.zshrc`, between two
  `# ---------- KoffeeLid ----------` lines it owns). Every one of them is removable with `koffeelid
  uninstall-hooks <agent>`, from Reset or Uninstall, or — for Claude Code, Codex and zsh today — a Settings
  button.

## Build from source

```sh
script/bootstrap.sh     # installs xcodegen if needed and generates KoffeeLid.xcodeproj
swift test              # KoffeeLidCore + LidPlaneKit unit tests
script/install.sh       # Release build → /Applications/KoffeeLid.app (+ /usr/local/bin/koffeelid wrapper)
open -a KoffeeLid
```

`install.sh` refuses only while quitting would sleep the Mac at once (armed, lid shut, no external display);
no override. If `/usr/local/bin` is not writable it prints the one `sudo` line that creates the `koffeelid`
wrapper.

## How it works

While armed, KoffeeLid sets the IOPMrootDomain lid-sleep flag (`kPMSetClamshellSleepState`, external method
12), holds `PreventUserIdleSystemSleep` and `PreventSystemSleep` assertions, darkens the built-in panel through
DisplayServices when the lid closes, and locks through loginwindow on reopen. Armed + screen on adds a
`PreventUserIdleDisplaySleep` assertion and a periodic user-activity declaration while the lid is open. The
auto-arm is a tiny helper binary invoked by the hooks and the shell snippet; it appends one line to an activity
journal and never launches anything. The fold is a Metal plane fed by ScreenCaptureKit, driven by the lid-angle
sensor at 30 Hz and interpolated per frame. See `docs/architecture.md` and `docs/macOS.md`.

## Documentation

- `CLAUDE.md`: the operating manual for an agent, with what the app is, the workflow for a change, where a change lands, rules and traps (start here)
- `docs/README.md`: the index, with which document answers which question and how to start a session
- `docs/functional.md`: what the app does, every mode, setting and default
- `docs/architecture.md`: targets, arming state machine, kernel-flag ownership, the effect, the activity pipeline, threading
- `docs/macOS.md`: the macOS mechanisms it relies on and how they behave
- `docs/pitfalls.md`: the traps already hit, and what the code does instead
- `docs/development.md`: build/install/debug loop, adding preferences, strings and controls
- `docs/manual-test-checklist.md`: hardware verification checklist

## Support

KoffeeLid is free and carries no ads. If it saves you trouble, you can leave a tip on
[Ko-fi](https://ko-fi.com/bambidotexe).

## Notes

- Personal build: English and French, no licensing.
- Any other app that keeps a closed Mac awake fights over the same macOS setting. Do not arm two at once.
- Sound effects are free to use (`App/Resources/Sounds/SoundEffects-LICENSE.txt`).
