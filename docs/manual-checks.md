# Manual checks (run after script/run.sh, any other lid-sleep utility quit)

**Log:** `~/Library/Application Support/KoffeeLid/diagnostics.log` — follow it with: `tail -f "$HOME/Library/Application Support/KoffeeLid/diagnostics.log"`

## Kernel & power
- [ ] Quit any other utility that disables lid-close sleep first — they drive the same kernel flag, and `AppleClamshellCausesSleep` reads `No` while any of them is armed.
- [ ] Arm via right-click → `ioreg -r -d1 -c IOPMrootDomain | grep AppleClamshellCausesSleep` → `No`
- [ ] `pmset -g assertions | grep KoffeeLid` shows PreventUserIdleSystemSleep and PreventSystemSleep
- [ ] Disarm → `AppleClamshellCausesSleep = Yes`, assertions gone
- [ ] Armed + close lid 2 min → Mac stays awake (ssh/ping from phone or `pmset -g log | tail` shows no sleep)
- [ ] Log shows `re-applied lid-sleep flag after power-source change` roughly once a minute while closed
- [ ] Only when a flag clear ever fails (`lid-sleep flag clear FAILED`, `flagClearPending`): the mug turns orange in both light and dark menu bars (the image must stay a template: AppKit tints template images only)

## Display & lock
- [ ] Lid close while armed → `built-in display brightness set to zero`, recovery JSON written
- [ ] Lid open → brightness back to previous, recovery JSON removed, Lock Screen shown, `lid-open lock confirmed`
- [ ] Kill the app (`kill -9`) while dark, relaunch → `built-in display brightness restored (launch recovery)` shown in log
- [ ] Relaunch after a `kill -9` shows `launch: unclean previous exit detected; kernel lid-sleep flag cleared (recovery)` in the log

## Gesture
- [ ] Hold Fn (Globe), start closing from your usual working angle (not only from fully open) → `gesture: started @…deg (fn via …)`, arms after ~4°, sound plays (`gesture: armed via tilt`)
- [ ] Release Fn a fraction of a second before the activation travel is reached → still arms (1 s grace)
- [ ] Press and release Fn, wait > 1 s, then close → `gesture: cancelled (optionLost)`, normal sleep
- [ ] Arm with Fn + close, then reopen by ≥ 4° before the lid shuts → `gesture: lid reopened … cancelling`, disarmed, plane snaps back flat in ~0.3 s
- [ ] Arm with Fn + close and hold the lid still part-way → after the "Return to flat" delay: `gesture: lid still … cancelling`, disarmed, plane retracts
- [ ] Close without Fn → normal sleep
- [ ] **The detector never latches**: arm with ⌃⌥⌘L, Fn + close a few degrees (`gesture: modifier + close while armed (shortcut) …; effect follows the lid`), release Fn, reopen, disarm with ⌃⌥⌘L → Fn + close arms again (`gesture: started`, `gesture: armed via tilt`). Repeat with the menu and `koffeelid arm` as the arming source
- [ ] Armed from the menu, hold Fn through a whole close (`modifier + close while armed`), lid shuts, reopen (`lid opened; arm stands`), Fn + close again → `gesture: started` (detector reset on reopen)
- [ ] Armed from the menu with the lid already below the start-below angle and folding, press Fn while closing → `…; effect already folding; fold kept`, no snap to flat
- [ ] Click KoffeeLid's Settings window (app active), press and release Fn, then close the lid without Fn → nothing arms (no cached modifier state); Fn + close afterwards still works
- [ ] Arm with Fn + close, stop half-way and keep Fn held for several seconds → no `lid still … cancelling`, the plane stays folded; release Fn → after the "Return to flat" delay the plane eases flat and `disarmed (stalled)`
- [ ] Armed from the menu, lid folding, hold Fn and stop the lid → the plane does not return to flat while Fn is held; release → it does after the delay
- [ ] Releasing Fn after the gesture does not trigger the Globe key action (System Settings › Keyboard › "Press 🌐 key to" = Do Nothing if it does)
- [ ] **Arrow keys are not Fn**: Off, lid open, hold ↓ (or tap it and touch nothing else) and tilt the lid 5° → no `gesture: started` line, nothing arms. Armed from the menu, same thing → no `gesture: modifier + close while armed`, no fold above the start-below angle. Armed from the menu, lid folded below the start-below angle, hold ↓ with the lid still → the plane still returns to flat after the delay
- [ ] **Function and navigation keys are not Fn**: Off, lid open, hold F5 with "Use F1, F2… as standard function keys" on (or Home on an external keyboard) and tilt the lid 5° → no `gesture: started`; hold the built-in Fn key instead → `gesture: started` as before
- [ ] **Only the built-in Fn key** (Input Monitoring): with the grant absent the log says `built-in Fn reader: Input Monitoring not granted`, and the Magic Keyboard's Globe key + tilt arms (any keyboard counts). Settings › Permissions › Input Monitoring › Allow… → system prompt → Allow → the log says `built-in Fn reader: reading Apple Internal Keyboard / Trackpad` (note whether it needed a relaunch: `open FAILED`); now Globe on the external keyboard + tilt → no `gesture: started`; the built-in Fn + tilt → `gesture: started … (fn via hardware, built-in keyboard)`; hold the built-in Fn with the lid still → the plane stays; release → it settles. Advanced › Reset → `input monitoring reset` in the `reset:` line, the row reads Not granted and the log falls back to `not granted`
- [ ] Advanced › Hold while closing = Option → the same checks pass with Option; labels update after reopening Settings

## Effect
- [ ] While the plane folds, the menu bar is hidden under the black backdrop (no mug icon, no clock); note whether macOS's purple screen-recording pill is still visible — it is drawn by the system and may not be coverable
- [ ] Grant Screen Recording, relaunch; arm with lid open; log shows no `effect: capture started` while the lid rests
- [ ] Open the lid wider (e.g. 80° → 100°): nothing happens
- [ ] Armed from the menu: tilt the lid 100° → 80° → 100°: nothing happens; close below 75° ("Start below (except the lid gesture)") → the fold starts there, moves faster than the lid for ~20°, then follows it 1:1 (at 50° it shows 40°)
- [ ] Armed with Fn + close from above the gesture's start angle (Advanced › Lid effect › "Start below (with the lid gesture)", default 95°): `effect: capture started` 4° past the start angle but the plane stays invisible until the lid passes that angle, then follows it 1:1; from below it, it starts at once and catches up. Set the gesture start to 110°: the plane now appears as soon as the lid passes 110°
- [ ] Advanced › Lid effect: dragging "Start below (except the lid gesture)" above the gesture start pushes the gesture slider up with it; dragging the gesture start below the other one stops there
- [ ] Armed from the menu, then Fn + close: `gesture: modifier + close while armed`, the fold starts immediately; the arm stays a menu arm (survives reopen); reopen it → `effect: gesture fold ended; waiting below 75° again`, then 100° → 80° without Fn does nothing
- [ ] Lid resting where the sensor flickers between two degrees (e.g. 89/90) still returns to flat after the delay
- [ ] Close 4° (the gesture's activation value) past the rest angle: `effect: capture started`, the desktop stays upright behind the display: anchored at the hinge, growing from it, narrowing toward the top (black void beside it), cropped above, blur strongest at the top; its two sides and its top row melt softly into the black, crisp at the hinge and widest at the top corners, and the picture darkens toward the top as the fold grows (no hard outline anywhere once the lid is past ~20° of fold); Edge softness 0 % brings the crisp keystone back, Shading 0 % the full brightness; reopen to the start point: plays backward to flat, then `effect: capture stopped`; opening further does nothing
- [ ] Leave the lid part-way closed: the plane eases back flat after the "Return to flat" delay
- [ ] Advanced › Lid effect › Defaults › Reset puts every effect slider back (gesture start 95°, start below 75°, 0.5 s, zoom 80 %, perspective 40 %, blur 0.15×, edge softness 100 %, shading 100 %, responsiveness 70 %) and the page redraws
- [ ] Advanced › Responsiveness 0 % → visibly smoother but ~150 ms behind the hand; 100 % → ~80 ms behind, a sudden mid-close stop overshoots a degree or two and comes back; slow closes show slight jitter
- [ ] Motion is smooth (no 30 Hz stepping); a *slow* close (~15°/s, one degree every other sample) moves continuously, no stop-and-go; the plane does not overshoot when the lid stops; Settings › Advanced settings… effect sliders change the look live (Inner screen zoom 0 % = no growth, 100 % = exact geometry, up to 200 %; Perspective 0 % = straight sides, 100 % = the keystone, up to 200 %; Blur strength 0 = off); "Simulate a fold" works armed or not (starts the effect temporarily when idle)
- [ ] Deny permission → arming works, log says `screen recording not granted`
- [ ] Fn + close, then reverse by 4° within the first half second, before `effect: capture started` appears: after `effect: stopped` the menu bar's screen-recording indicator goes away within a few seconds (a stream must never start into a capture its session no longer owns)

## Sound / volume
- [ ] Mute Mac, enable Force volume 60 %, Preview → audible; afterwards muted again and previous volume restored
- [ ] Switch output device to one without software volume (HDMI TV, if available) → plays at current level, log notes it

## Safety rails
- [ ] Plug an external display while Off → arming still allowed; the log says `armed (…); standing by: external display connected`, menu header and tooltip show "Standing by", the flag reads `No`
- [ ] Plug an external display while Armed with the lid open → `external display connected while armed; standing by`, effect retracts, no lock when the lid is then opened/closed at the desk; unplug → `external display disconnected; lid behaviours active again`, effect starts, next close darkens and next reopen locks
- [ ] Armed, lid closed and dark, then plug a display → `display appeared while the lid is closed; locking` and the lock screen shows on the monitor
- [ ] **Charger-fed monitor, armed, lid closed, unplug the charger** → open the lid: the log shows either `external display disconnected; lid behaviours active again` **before** `lid-open native Lock Screen requested` (live read caught it), or `lid opened on an external display; no lock` followed within 2 s by `the external display was already gone when the lid opened; locking after all` — either way the screen is locked when you look at it
- [ ] Same setup but unplug **only the monitor** while the lid is open and the Mac has been at the desk a while → no lock (the grace window is long past); reopening later at the desk with the monitor still attached → still no lock
- [ ] Armed + screen on with an external display → the display assertion is still held (`pmset -g assertions`) while the rest stands by
- [ ] Fn + close with an external display connected does nothing (gesture detector off; `gesture:` lines absent)

## One-close hold (Fn + close ends at login)
- [ ] Fn + close, lid shut, then open the lid → the screen locks and the log says `one-close session held on lid open; waiting for the screen to lock` then `one-close arm held; it ends when you log back in`; `koffeelid status` still says `mode: armed`
- [ ] With the arm held, close the lid again *without logging in* → the lid sound plays, `ioreg` still reads `AppleClamshellCausesSleep = No`, and the Mac is still running when you open it again
- [ ] With the arm held, close and reopen the lid twice → each reopen logs `one-close session held on lid open` and the screen is locked again; **no** lid effect plays on those closes
- [ ] Log back in → `one-close session ended on unlock` then `disarmed (unlock)` (or `manual off (unlock); the auto-arm holds the session` if Claude Code is working); the flag goes back to `Yes`
- [ ] Unlock while an activity auto-arm is running → the session continues and the effect comes back on the next close
- [ ] A rail during the hold (drop below the low-battery threshold on battery) → `disarmed (low battery)`, the hold is dropped, and the Mac sleeps on the next close
- [ ] In-place switch during the hold (⌃⌥⌘K) → it becomes a manual caffeinate arm, the hold is cleared, and logging in no longer ends it
- [ ] Low-battery threshold 50 %, on battery below 50 % → disarms with notification; every arming path (menu, right-click, ⌃⌥⌘L/K, Fn + close, CLI) is refused with `arm blocked (…): batteryLow`
- [ ] Same level on AC power → arming allowed in every mode; unplug → instant disarm with the battery notification
- [ ] `pmset sleepnow` while armed → `armed session interrupted by external software sleep (Software Sleep)` + notification
- [ ] Armed + screen on, lid closed, **no sudoers rule** (`koffeelid status` says `sleep lock: off`) → plug the charger → log `macOS started a lid sleep behind the arm (powerd rewrote the lid-sleep bit); holding the session in dark wake` then `re-applied lid-sleep flag after lid-sleep override`; `pmset -g log` shows `Entering DarkWake state due to 'Clamshell Sleep'` and **no** `Entering Sleep state`; open the lid → `koffeelid status` still says the armed mode, the "KoffeeLid held your Mac awake" notification is waiting
- [ ] Settings › Permissions › Sleep lock shows `⚠︎ Not granted` + `Set up…`; clicking it shows the macOS administrator-password dialog; Cancel → `sleep lock setup cancelled by the user`, nothing changes; password → `sleep lock sudoers rule installed from Settings/onboarding`, the row says `Granted`, `/etc/sudoers.d/koffeelid` exists (mode 0440, `ls -la /etc/sudoers.d` shows no `.koffeelid.*` leftover), and if the app was armed the log adds `sleep lock engaged (pmset disablesleep 1)` at once. The onboarding Permissions page has the same button
- [ ] Same with the sudoers rule installed → arm logs `sleep lock engaged (pmset disablesleep 1)`, `pmset -g | grep SleepDisabled` reads 1, `koffeelid status` says `sleep lock: on`; plug and unplug the charger with the lid closed → nothing in the log, no `Clamshell Sleep` in `pmset -g log`; disarm → `sleep lock released (pmset disablesleep 0)`, `SleepDisabled 0`
- [ ] With the rule installed, `kill -9` the armed app (pid from `koffeelid.pid`) → the watchdog relaunches it and the log says `launch recovery: stale sleep-lock marker found; sleep re-enabled (pmset disablesleep 0)`; `SleepDisabled 0`
- [ ] Delete only KoffeeLid's rule by hand (`sudo rm /etc/sudoers.d/koffeelid`) while leaving another passwordless sudo rule in place → Settings › Permissions › Sleep lock reads `Not granted` (the availability check requires the rule file, not just a yes from `sudo -n -l`), and arming logs `sleep lock unavailable`

## Arming paths
- [ ] Left-click the mug icon → header "KoffeeLid — <mode>", then Off / Armed / Armed + screen on, each followed by its cup in grey (empty / sleepy eyes / round eyes, matching the menu bar glyph), with a checkmark on the current one; clicking a mode switches; the tooltip names the mode
- [ ] Auto-armed (Claude Code working, "While Claude Code…" on): the icon shows the coffee + closed-eyes cup, the tooltip says "Auto-armed" and the greyed "Auto-armed while…" line ends with that same cup, while the menu still checks Off; `koffeelid arm` or ⌃⌥⌘L switches the glyph to the manual one at once
- [ ] Right-click cycles Off → Armed → Armed + screen on → Off when the clicks are within 3 s; wait > 3 s in Armed or Armed + screen on, right-click → Off directly (log `disarmed (rightClick)`)
- [ ] ⌃⌥⌘L: Off → Armed → Off; from Armed + screen on → Armed (`mode caffeinate → armed (shortcut)`)
- [ ] ⌃⌥⌘K: Off → Armed + screen on → Off; from Armed → Armed + screen on (`mode armed → caffeinate (shortcut)`, `display kept on (caffeinate)`)
- [ ] Settings › Arm with › turn off "Armed + screen on shortcut" → ⌃⌥⌘K does nothing, ⌃⌥⌘L still works; turn it back on → ⌃⌥⌘K works again without relaunch
- [ ] Fn + close arms one close only: after the lid reopens the Mac is disarmed and the screen locks; while Armed or Armed + screen on, Fn + close plays the effect and the mode is unchanged after reopening
- [ ] Armed + screen on: `pmset -g assertions | grep KoffeeLid` shows PreventUserIdleDisplaySleep and a `UserIsActive "KoffeeLid: caffeinate"`; wait past the display-sleep and screen-saver timeouts → display stays on, no screen saver; lock the screen (⌃⌘Q) → the login page stays lit
- [ ] Armed + screen on + close lid → same as Armed (dark, awake, sound); reopen → locked, login page stays on indefinitely; `UserIsActive` disappears while closed and returns when open
- [ ] Switching Armed ↔ Armed + screen on keeps `AppleClamshellCausesSleep = No` throughout (no flag clear/set in the log)
- [ ] CLI: `koffeelid status` (works with the app not running: `mode: off (KoffeeLid is not running)`), `koffeelid arm` launches the app if needed and prints `mode: armed · lid: open`, `koffeelid caffeinate`, `koffeelid toggle-caffeinate`, `koffeelid toggle-armed`, `koffeelid off`, `koffeelid settings`; a blocked arm prints `did not arm: …` and exits 1; `koffeelid bogus` prints the usage and exits 2
- [ ] `open 'koffeelid://caffeinate'` and `open 'koffeelid://toggle'` work
- [ ] Shortcuts app shows Arm / Arm + screen on / Turn Off / Toggle / Toggle screen on / Status actions and they work; Status returns the mode name (the bundle must contain `Contents/Resources/Metadata.appintents`; a Debug build whose log printed `Metadata extraction skipped` has none until rebuilt)

## Onboarding
- [ ] First launch (or Advanced › Show onboarding again): page 1 headline "Vos agents continuent de travailler. Écran rabattu." with "agents" in brown, three capsules inside the margins, clicking the headline changes nothing; the window stays above other windows
- [ ] Page 2 "Autorisations": Verrou de veille ⚠︎, Éléments d’ouverture ⚠︎, Enregistrement de l’écran, Surveillance de l'entrée, Notifications, separators between rows; each button runs its grant (password dialog / System Settings / system prompts) and the window comes back to front with the row now "Accordée"; bottom right says "Ignorer" until both ⚠︎ rows are granted, then "Continuer"
- [ ] Page 3 "Arm while you work": the two hooks, one "Set up…" button each (details under Auto-arm on activity)
- [ ] Page 4 "Tout est prêt" mentions the mug; Finish sets `onboardingCompleted`
- [ ] Notifications are not requested at launch before onboarding: the system prompt appears only from the Notifications row

## Settings UI
- [ ] Launch with `--open-settings`: `"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" --open-settings &` (or `open -a "KoffeeLid" --args --open-settings`) → App group first, grouped rows, opaque title bar with no gap above the first header, fits the visible screen (scrolls if not, never under the Dock); "Réglages avancés…" opens the Advanced window
- [ ] Settings › Permissions shows the five grants with `Accordée` / `Non accordée` and a button only while missing; coming back from System Settings refreshes the rows
- [ ] Advanced › App › Journal de diagnostic off → the log stops after `diagnostics log disabled from Advanced settings`; on → `diagnostics log enabled from Advanced settings`
- [ ] Advanced › Réinitialiser… → confirmation, then (password dialog if the rule exists) the log gets one `reset:` line listing what was undone, `pmset -g | grep SleepDisabled` is 0, `/etc/sudoers.d/koffeelid` is gone, preferences are back to defaults and the onboarding opens on page 1
- [ ] Advanced › Réinitialiser… while **auto-armed** (Claude Code working, the menu shows Off): the log gets `disarmed (reset)` before the `reset:` line, `koffeelid status` says `mode: off`, `pmset -g | grep SleepDisabled` is 0 and only then is `/etc/sudoers.d/koffeelid` gone (the reset calls `disarm` directly: Off from the menu keeps an auto-armed session)
- [ ] Settings › App › "Afficher dans la barre des menus" off → the cup disappears at once; `koffeelid status` still answers, ⌃⌥⌘L still arms (the status line says `mode: armed`), Fn + close still arms, auto-arm still arms; on → the cup comes back in its current state
- [ ] With the cup hidden: `open -b dev.rubens.koffeelid` (or opening KoffeeLid in Finder / Spotlight) brings up Settings; with a window already open it just comes to the front
- [ ] Quit and relaunch with the cup hidden → still hidden, still armable from the shortcut; at login the app starts with no Settings window
- [ ] Settings › "Quitter KoffeeLid" at the bottom → the app exits like the menu's Quit: the log gets `disarmed` then `clean termination`, `pmset -g | grep SleepDisabled` is 0 and the cup is gone
- [ ] Both windows follow light and dark mode
- [ ] App › Enregistrement de l'écran shows Accordée, or Non accordé with an Autoriser… button
- [ ] Advanced sliders update their value labels live and sit inside the group padding
- [ ] Changing the sound popup plays a preview that honours Force volume
- [ ] Settings › Updates: press "Check for updates…" → "Up to date." and the log line `update check: up to date`; with Wi-Fi off → "Could not check: …" and `update check FAILED`

## Watchdog
- [ ] Login Items approved; `kill -9` app → relaunched within 2 s; 4th kill in 10 min → `crash loop detected`
- [ ] Quit from menu → `app exited cleanly; standing down`, no relaunch

## Auto-arm on activity
- [ ] `koffeelid install-hooks` → `Installed 15 Claude Code hooks -> /Applications/KoffeeLid.app/Contents/MacOS/KoffeeLidHook hook`; `koffeelid status` ends with `activity: 0 sessions working, 0 commands`
- [ ] Add the zsh line to `~/.zshrc`, open a new terminal, run `sleep 120` → after 5 s the mug arms, log `activity: running (0 sessions working, 1 command)` then `auto-armed (activity)`; `koffeelid status` shows `auto-armed (activity)`
- [ ] While auto-armed the menu bar shows the closed-eyes cup and "Off" checked; the greyed header reads "KoffeeLid — Off" with "Auto-armed while a command runs" on the line under it; `koffeelid status` says `mode: off · auto-armed (activity)`
- [ ] Manual Off never ends an auto-arm: arm from the menu while a command runs, then Off → log `manual off (menu); the auto-arm holds the session`, the cup goes back to closed eyes, the Mac stays armed; the command ends → hold-off → `disarmed (activity ended)`
- [ ] With this Claude Code session working all day (the level never drops): Off from the menu, then `sleep 120` in a terminal → the Mac is still armed throughout (the auto level and the manual mode are independent)
- [ ] Close the lid during the sleep → Mac stays awake; open it → lock screen; command ends → `activity: idle`, `auto-disarm scheduled in 60s`, then `disarmed (activity ended)` and normal lid sleep is back (`AppleClamshellCausesSleep = Yes`)
- [ ] `sleep 2` alone never arms (arm-after 5 s); `vim` never arms (skip list)
- [ ] Start a Claude Code turn → arms within a second of the prompt (`activity: running (1 session working, 0 commands)`); a question from Claude (AskUserQuestion) → `activity: idle` and `auto-disarm scheduled in 1800s` (the line under the header says "Auto-armed, off in 30 min"); answering it → running again, disarm cancelled
- [ ] Ctrl-C a Claude turn → `activity: quiet turn … — registry idle, turn over` within ~35 s, then the 30 min hold-off, then `disarmed (activity ended)`; a `sleep 120` that ends during that wait does not shorten it
- [ ] Advanced › "Auto-disarm after Claude Code finishes" to 1 min → the next turn's wait is `auto-disarm scheduled in 60s`; dragging it during a countdown moves the deadline
- [ ] Let a Claude turn end (`auto-disarm scheduled in 1800s`), then move the mouse → within 2 s `auto-arm ended: local input during the hold-off` and `disarmed (activity ended)`; the same from an ssh session (no local input) keeps the wait
- [ ] Two Claude sessions, finish one → still armed; finish the other → hold-off then disarm
- [ ] In a Claude turn, start a long background shell (e.g. `sleep 120 &` via the Bash tool's background mode), let the turn Stop → `koffeelid status` keeps `1 session working` until the shell ends
- [ ] Arm from the menu, then start and finish a command → never disarms (`auto-arm ended; the manual arm (armed) stands`); `koffeelid off` (CLI) while auto-armed with a command running → `manual off (cli); the auto-arm holds the session`, still armed
- [ ] Auto-armed, choose Armed + screen on from the menu → the round-eyes cup, `koffeelid status` says `mode: caffeinate · auto-armed (activity)`; the command ends → stays armed (manual); Off → disarms only if the level has dropped, otherwise back to the auto cup
- [ ] Switch the feature off in Settings while auto-armed and manually Off → `auto-arm disabled` then `disarmed (activity ended)`; while manually armed → the arm stands
- [ ] Low battery rail while auto-armed → `disarmed (low battery)`, and no re-arm until the running work stops and something starts again
- [ ] Low battery below the threshold on battery while running → auto-arm blocked once (`auto-arm blocked; waiting for the next activity`, one notification), no repeat every 15 s
- [ ] `kill -9` the app while auto-armed with a command running; watchdog relaunch → `activity: replayed N events …`, `auto-armed (activity)` again
- [ ] `koffeelid uninstall-hooks` → `Removed KoffeeLid hooks.`; `~/.claude/settings.json.backup-koffeelid` exists
- [ ] Advanced › Show onboarding again → page 3 "Arm while you work" lists Claude Code and Terminal (zsh), one "Set up…" button each; Claude Code's writes the 15 hooks and flips the Settings switch on; Terminal's appends the "# ---------- KoffeeLid ----------" block once (a second click says already present), nothing clipped in en or fr
- [ ] With SidePulse's `eval "$(sidepulse shell-init zsh)"` in ~/.zshrc and no KoffeeLid block, the Terminal row says "Not set up"; after Set up… then Remove, SidePulse's lines are untouched
- [ ] Settings › Hooks shows "Set up" with a Remove button once done; Remove puts the row back to "Not set up" (uninstalls the 15 hooks / strips the block from ~/.zshrc); Advanced › Reset also removes both
- [ ] Menu bar: no hook set up → no "Disarm once finished" item; either hook set up → the item is there, unchecked
- [ ] Armed from the menu, click "Disarm once finished" while a Claude turn runs → checked, status `disarm once finished: pending`; the turn ends → `auto-disarm scheduled in 60s` → `disarm once finished: manual mode (armed) released` then `disarmed (activity ended)`; the item is unchecked afterwards
- [ ] Same with nothing running → stays checked; the next command that starts and ends disarms a minute later; clicking it again first → cancelled, the arm stays
- [ ] Auto-armed by a Claude turn, click it after the turn ended → the 30 min wait becomes 1 min from the end of the turn (already past → disarms at once); click it again during the minute → back to the 30 min wait
- [ ] A Claude turn that resumes inside the minute cancels the countdown but keeps the request; a rail (low battery) clears it

## Localization
- [ ] `defaults write dev.rubens.koffeelid AppleLanguages -array fr` → French UI; reset afterwards
