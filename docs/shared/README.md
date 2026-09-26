# The shared documents

What every macOS app of this family shares, written once. **The canonical copy lives in
`~/Projects/macos-app-template/docs/shared/`; the copy in an app's `docs/shared/` is synced from it and is
never edited there.**

| File | Holds |
|---|---|
| `workflow.md` | The change workflow every `CLAUDE.md` follows, who decides what, the rules that hold in every app, the documents every app keeps. |
| `conventions.md` | How every app is built: layout, targets, build, scripts, the app shell, the Settings window, updates, uninstall, code style, commits, and the exceptions the older apps keep. |
| `macOS.md` | The platform facts every app leans on. |
| `pitfalls.md` | The traps every app has already fallen into, with the measurements. |
| `manual-test-checklist.md` | The walks every app repeats: the wizard, the Settings window, updates, the uninstall, language. |
| `activity-detection.md` | The contract koffeelid and my-sidepulse both implement to decide whether an agent or a terminal command is working, its constants, and the rule that keeps the two in sync. |

## The rule

A change to any of these is made in the template and replicated to every app:

```sh
sh ~/Projects/macos-app-template/scripts/sync-shared-docs.sh          # copy to every app in family.txt
sh ~/Projects/macos-app-template/scripts/sync-shared-docs.sh --check  # say which app has drifted
```

What goes here rather than in an app's own document: a convention, a platform fact, a trap or a walk that
applies to more than one app, or that a new app would want on day one. What stays in the app: what is
that app's own. When in doubt, it is shared: the cost of a trap written in one app is that it ships in the
others (the onboarding footer bug did, three times).
