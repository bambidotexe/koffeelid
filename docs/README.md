# KoffeeLid documentation

Every file here describes the system as it is. The code is the reference; when a doc and the code disagree,
the doc is wrong.

| File | Read it for |
|---|---|
| `functional.md` | What the app does: modes, arming paths, the lid gesture, auto-arm on activity, lid and display behaviour, safety rails, the lid effect and its reset rule, UI, settings and defaults, permissions |
| `architecture.md` | Targets, the coordinator and its state machine, kernel-flag ownership, who watches which signal, who owns the lid effect and its reset, the activity pipeline, persistence, the privilege boundary, threading, build and signing |
| `macOS.md` | The macOS interfaces the app depends on (kernel lid-sleep flag, `pmset disablesleep`, assertions, lid-angle sensor, modifier flags, displays, ScreenCaptureKit, login items, TCC, Claude Code's hooks and registry) and how each behaves |
| `pitfalls.md` | Traps already hit, with symptom, cause, what the code does instead and what not to do. Read the matching section before changing sleep, lid, gesture, effect, watchdog, privilege or hook code |
| `development.md` | Build, install and debug workflow, how to add a preference, a string, a settings control, a permission, a verb or an effect tunable, icons, the release checklist |
| `manual-checks.md` | The hardware checklist: what unit tests cannot cover (IOKit, Metal, CoreAudio, TCC, launchd) |

The repository's `README.md` is the product page; `CLAUDE.md` is the orientation for an agent working in the
repository (commands, invariants, testing constraints).
