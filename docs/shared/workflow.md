# The workflow

How a change is made in any app of the family, and the rules that hold in every one of them. Each app's
`CLAUDE.md` points here instead of restating it, and adds only what is that app's own.

## Who decides what

**Functional is the owner's. Technical is the agent's.**

What belongs to the owner, and is asked about, and only this:

- What the app *does*: a behaviour added, retired or changed, a rule of the feature, a default.
- What reaches the user: a sentence, a page, a window, a notification, a prompt.
- Anything with a cost outside the repository: spending money, publishing a release, touching another
  project, anything not undoable.

What belongs to the agent, and is decided, done and not raised:

- Every technical choice: architecture, data structures, algorithms, naming, file layout, tests, refactors.
- Bugs: see one, judge it, act. Fix it if it is worth fixing; leave it and write it under *Open issues* in
  `docs/pitfalls.md` if it is not. A wrong call that is documented beats a question.
- Every constant that is derived rather than felt: timings, thresholds, retries. Calibrate from evidence
  and record the evidence next to the value. A number that is a matter of taste (a colour, a spacing fitted
  by eye) is the owner's.
- Whether a flaky test, a rough edge or an inefficiency is worth the time.

Two things this does not license. Do not quietly narrow the job: if part of a task is dropped, say so and
why. And do not let "technical" swallow a functional change: a fix that alters what the app *means* is the
owner's call even when it arrives dressed as a bug fix.

## Changing behaviour

Every change to what the app does follows these steps, in this order. A change that skips one is not done.

1. **Find the rule.** Read the section of `docs/functional.md` that governs the behaviour, then the matching
   entries of `docs/shared/pitfalls.md` and `docs/pitfalls.md`. What `functional.md` says is what the app is
   supposed to do today.
2. **Check for a conflict.** If the request contradicts a written rule (a number, a trigger, an order, a
   default, a "never", in `CLAUDE.md` or in `functional.md`) **stop and ask the owner whether that rule is
   overruled, quoting it.** Do not guess, do not implement both, do not add an exception beside the old
   rule. This holds even when the request looks obviously intended: the owner may not remember the rule, or
   may want it kept. A request that only adds behaviour no rule covers needs no question, and a purely
   technical change needs none either. If the owner reaffirms the request, that is the answer: replace the
   rule.
3. **Change the code, in the layer that owns it.** `<App>Core` for anything decidable from values alone (it
   imports Foundation and CoreGraphics and never reads a clock); `<App>Platform` for the one call that
   touches the system, a file, a socket or the network; `<App>App` for wiring and windows. A comment states
   the present rule, never the history of the change.
4. **Update `docs/functional.md` in the same commit.** Replace the old rule with the new one. Never keep an
   outdated rule, not as a note, not as "it used to be", not as a crossed-out line. If the change touches
   how the app is built, a platform fact or a trap, update `architecture.md`, `macOS.md` or `pitfalls.md`
   the same way, and `README.md` if it says anything about it. **A fact, a trap or a convention that
   applies to more than this app goes in `~/Projects/macos-app-template/docs/shared/` and is synced**, not
   in the app's own document.
5. **Verify.** `swift build`, then `swift test` and **count the summary lines: one per bundle.** A pure rule
   gets a test in `<App>CoreTests`; an I/O behaviour gets one in `<App>PlatformTests`. Anything only a
   person can see gets a line in `docs/manual-test-checklist.md`.
6. **Commit per task**, conventional commits, files staged by path, with the attribution trailers from the
   session's system reminder. Push, tag and release only when asked.

The sync rule in one sentence: **the code and `docs/functional.md` describe the same app at every commit,
and the newer of a request and a written rule wins only after the owner has said so.**

## Rules that hold in every app

- **A build of this app reaches a Mac in exactly two ways, and there is no third.** `scripts/install.sh`
  (skill `macos-install-locally`) builds the production bundle and puts it in `/Applications`;
  `scripts/publish.sh` (skill `macos-publish-release`) does the same and puts the disk image on GitHub. Both
  build the real thing (Release, Developer ID, Hardened Runtime, notarized, stapled) so what runs on this Mac
  is what a stranger would download. **Neither leaves an `.app` or a `.dmg` anywhere under the
  repository**, on any exit path, including a failed one: a signed bundle in `build/` is a complete
  application that Spotlight indexes and the owner can launch by accident, giving a second instance with the
  same bundle identifier and the same preferences. `scripts/no-leftovers.sh` holds that rule.
- **Installing works on this Mac, and it is the install script and nothing else.** The owner's word,
  binding on every session: the Developer ID certificate and the `wooflab-notary` profile are in the
  keychain, and there is nothing wrong with them, with notarization, or with the pipeline. Run
  `sh scripts/install.sh` (`make install`; koffeelid `script/install.sh`, snappy-snap `Scripts/install.sh`)
  and it will be fine. A run that refuses at the notary check is run again, not diagnosed: never look the
  credential up, never store or replace one, never build another way, never write that notarization is
  broken. Refused twice, say so in one line and stop; the rest is the owner's.
- **A debug or ad-hoc build is never installed, and never made without asking the owner first.** It exists
  only to read something a release build will not show. `scripts/make-app.sh` refuses one without
  `DEBUG_OK=1`; that guard is there to make the decision deliberate, not to be worked around. **An ad-hoc
  signature gives the app a new code identity, so the owner loses every permission grant** and has to give
  it again.
- **The version is not chosen.** `scripts/version.sh` holds the rule; a local install always builds
  exactly the tree's own version, and publishing is the only thing that moves it.
- **A release says what changed, and says it from the commits.** `scripts/publish.sh` refuses without
  `--notes=<file>`; the file is written fresh for every release from every commit since the last tag, in
  the words of someone who installs the app: what is new, what changed, what was fixed. No stock sentence,
  no list of commits, nothing about signing or notarization (skill `macos-publish-release`, *Release
  notes*).
- **`docs/functional.md` is kept in sync with every behaviour change, in the same commit, and never
  carries an outdated rule.** A rule the owner has overruled is replaced, not annotated. "It was like that
  before" is not a sentence that belongs in any document or comment in the repository.
- **Comments and documents state the present.** A comment records a rule, an invariant, a fact the code
  depends on, or the measurement behind a derived number. No dates, versions, attributions, task numbers or
  accounts of what the code replaced. History belongs in git and, for traps only, in `docs/pitfalls.md`.
- **Every permission prompt follows a click of the user's, and the reader is never the asker.** Only a
  row's own button in the onboarding wizard calls a request API; nothing at launch, nothing when a window
  opens, nothing when a feature that needs the grant is switched on. The `macos-building-onboarding` skill
  says why, at length.
- **Any work on the onboarding window, or on any permission row, starts with the `macos-building-onboarding`
  skill.** Any work on the Settings window starts with the `macos-building-settings-pages` skill.
- **No user-facing string is written at its point of use.** It goes in a `Core/Strings*.swift` table
  where one accessor answers for every language, so a string cannot exist in English alone (the older apps
  that use `L("…")` catalogues keep both catalogues in step instead; `conventions.md` says which).
- **An update never installs by itself.** The automatic check only announces; the fetch and the install
  each need a click. Everything that can refuse an update runs while the app is up; the install leaves
  through `NSApp.terminate`, never `exit()` or a kill.
- **Silence is a defect.** Anything that declines to act logs why, once, with the numbers.
- `<App>Core` imports Foundation (and CoreGraphics) only, and never reads a clock: `now` is passed in.
  `PurityTests` fails the build otherwise.
- **Measurement before design** on any platform assumption; where a measurement is not available, say so
  in the same breath as the number chosen instead.
- **Subagents** run with an explicit `model` and a written brief for one slice; the parent reviews the
  diff, re-runs the tests and the warning check itself before committing. Never a fan-out wider than four.
- Commit per task, conventional commits (`feat|fix|build|docs(scope): why`), the attribution trailers from
  the session's system reminder. **Stage by path. Never `git add -A`**: another agent may be working in
  the tree, and `.claude/` and `.superpowers/` are the owner's.

## The documents every app keeps

| File | What it is |
|---|---|
| `README.md` | For a user: a centred icon, the pitch, badges, what it does, Settings, Install, Build, Requirements, Documentation, Support. |
| `CLAUDE.md` | For an agent: what it is, the shared documents, what to read first, where a change lands, Commands, Architecture, Rules, Traps, Status. It does not restate this file. |
| `CHANGELOG.md` | Every released version, newest first, in the words a user would use. |
| `docs/README.md` | The index of the documents, and how to start. |
| `docs/functional.md` | **The authority on behaviour**, kept in sync in the same commit as any change. |
| `docs/architecture.md`, `docs/macOS.md`, `docs/pitfalls.md` | How it is built · the platform boundary · what looks right and is not, with the measurements. `pitfalls.md` is the only place that records what failed, and holds only what is the app's own. |
| `docs/manual-test-checklist.md` | What only a person can see. |
| `docs/shared/` | This folder, synced from the template. |

`CLAUDE.md` § Status says what is tagged, released and installed, and what has not been walked on hardware.
