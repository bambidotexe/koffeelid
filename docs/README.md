# KoffeeLid documentation — the index

Every document here describes the present system only; history lives in git. The repository's `README.md` is
the product page; `CLAUDE.md` is the operating manual for an agent and the place to start; this page says which
document answers which question.

## Starting a session

1. Read `CLAUDE.md` whole: what the app is, the workflow for a change, where a change lands, the rules, the
   traps, the state of the tree.
2. Run `"/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" status`. The installed app is the owner's daily
   driver and is usually armed; nothing in the loop may quit, reinstall or disarm it without that check.
3. Run `git status --short`. Another agent may be working in this tree; stage by path.
4. For the area you touch, read the section of `functional.md` (the behaviour), then the matching section of
   `pitfalls.md` (what already went wrong there), then `architecture.md` for where it lives. If `CLAUDE.md`
   names a skill for that area, that skill comes first: it holds rules the documents only summarise.
5. If the request contradicts a rule you just read, ask the owner whether the rule is overruled before writing
   code. When the owner confirms, the rule is replaced in `functional.md` in the same commit as the code.

## Which document answers which question

| Question | Document |
|---|---|
| What does the app do in situation X? What is the default of setting Y? What happens without permission Z? | `functional.md` — the authority on behaviour; every rule of the app, by feature, with the numbers |
| How is it built? Which object owns what? What is the arming state machine? Who watches which system event? | `architecture.md` |
| What does macOS actually do here (kernel flag, powerd, sleep lock, assertions, lid sensor, modifier keys, displays, capture, TCC, Claude Code's hooks and registry, zsh)? | `macOS.md` |
| What looked right and was not? What must the code never do again? | `pitfalls.md` — symptom, cause, what the code does, what not to do |
| How do I build, install, debug, add a preference, a string, a control, a permission row, a verb, an effect tunable, a collaborator? How do I change the menu-bar glyph or the app icon? How is a release made? | `development.md` |
| How is a hardware-only behaviour verified? Which log line proves it? | `manual-test-checklist.md` |
| What was read, verified and decided in the September 2026 audits? | `_audit.md` (the findings and decisions) and `_coverage.md` (the file manifest); records, not rules |
| How is the Settings window built, and how are its words written? | the `macos-building-settings-pages` skill |
| How is the onboarding built? How is a permission named, asked for, and kept from covering what it opens? | the `macos-building-onboarding` skill |
| How does a build reach this Mac, or a release reach GitHub? | the `macos-install-locally` and `macos-publish-release` skills |

## Keeping the documents true

- `functional.md` changes in the same commit as the behaviour it describes. An outdated rule is replaced, never
  annotated.
- `architecture.md` changes when a target, an object, an ownership or a thread changes.
- `macOS.md` changes when a platform fact is learned or measured; a fact written there has been observed on
  this Mac, and the text says when it has not.
- `pitfalls.md` gains an entry when something that looked right was not; it is the only place that records
  approaches that fail.
- `manual-test-checklist.md` gains a line for every behaviour only hardware can show, with the log line to grep for.
- `CLAUDE.md` § Status says what is tagged, released and installed, and what has not been walked on hardware.

## The shared documents

`shared/` is a byte-for-byte copy of `~/Projects/macos-app-template/docs/shared/`: the workflow every app
of the family follows, the conventions, the platform facts, the traps and the walks they all share. **It is
never edited here**; a change goes in the template and `sh ~/Projects/macos-app-template/scripts/sync-shared-docs.sh`
replicates it. What is this app's own stays in the documents above.
