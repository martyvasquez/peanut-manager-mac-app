# Peanut Manager (Mac)

AI lineups for youth baseball and softball. The AI reads your stats, ratings, notes, rules and scouting report and decides the batting order and every inning's defense; the app checks every lineup against your rules before you see it.

- **Plan and rationale:** [`docs/v2-plan.md`](docs/v2-plan.md). The *Build status* section lists what's done and what's left.
- **For coding agents:** [`CLAUDE.md`](CLAUDE.md).

Free and local-first. The AI runs on your ChatGPT plan: sign in with ChatGPT, no API key. No server.

## What works today

| Area | What's there |
|---|---|
| **Lineups** | Two steps. **1. Batting order:** the AI proposes; you drag to reorder or "Remake…" with feedback. **2. Positions:** lock any spots on an empty grid, then **Fill the Rest**. Validated, revised by the AI if needed, and disclosed when the app adjusts anything. Undo, versions, clear. |
| **Checks** | Code-verified: 9 positions every inning, no duplicates, everyone accounted for, eligibility, locks, pitcher re-entry, everyone bats, plus 8 checkable rule types. Rules without a check are labeled "AI judgment." |
| **Games** | Attendance (late arrival / early departure), rules, innings, Win↔Develop, stats↔ratings trust, model chip, notes for the AI, and an opponent scouting report that carries over to the next game against that team. |
| **Roster** | Each player has three tabs: **Stats**, the AI **Scouting Report**, and the **Coach's Evaluation** (positions on a field diagram, 14 optional star ratings, notes). |
| **Rules** | Plain-language rule sets per team; attach a code check to any rule. |
| **Stats & Insights** | Tabs for the AI team summary, every player's one-line take (opens their report), and the season stats table. AI scouting report per player and for the team. Every claim cites facts the app computed and shows their real values. Re-assesses only players whose inputs changed. |
| **Stats** | GameChanger CSV import (section-aware parsing, exact matching, pitching and catching), sortable season table. |
| **Settings** | Sign in with ChatGPT (keychain), the ChatGPT model and thinking level, Manage Usage. |

## What's next (short version)

1. **Stable code signing**, so updates stop asking for the keychain password.
2. Assessments, part two: feed them into lineups (after evals), coach pushback, history.
3. **Evals**: golden lineup, assessment and rule sets to compare models and prompts.
4. **Printing and sharing** that's actually tested (lineup card, PDF, copy as text).
5. AI rule interpreter (automatic "Understood as…"), Jev, learning from edits.
6. **Rules UI/UX redesign** (how rules are presented, created and edited; direction not decided yet).
7. Season playing-time ledger, pitching tracker, game-day mode.

Full list with details: [`docs/v2-plan.md` → Build status](docs/v2-plan.md#build-status-oct-2-2026).

## Install and updates

Download `PeanutManager.zip` from [the latest release](https://github.com/martyvasquez/peanut-manager-mac-app/releases/latest), unzip, drag to Applications. The first open shows "Apple could not verify…": **System Settings → Privacy & Security → Open Anyway**.

After that the app updates itself on launch. Every push to `main` that changes the app is built, signed and released by `.github/workflows/release-mac.yml` (Sparkle; see `docs/v2-plan.md` item 1).

## Layout

| Path | What |
|---|---|
| `Packages/LineupKit` | Pure Swift core: models, validator, feasibility, safety-net repair, v1 prompts, lineup engine, GameChanger import. `swift test` runs in seconds. |
| `Packages/LineupKit/Sources/LineupAI` | Sign in with ChatGPT and the ChatGPT plan client. |
| `PeanutManager/` | SwiftUI + SwiftData Mac app. Library stored at `~/Library/Application Support/Peanut Manager/Library.store`. |
| `Design/` | App icon source art. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and not committed. |

## Build & run

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Targets macOS 26.

```sh
cd Packages/LineupKit && swift test && cd ../..
xcodegen generate
xcodebuild -project PeanutManager.xcodeproj -scheme PeanutManager -derivedDataPath build build
open "build/Build/Products/Debug/Peanut Manager.app"
```

Sign in with ChatGPT under **Peanut Manager → Settings** (⌘,).

### Debug launch flags (Debug builds only)

Always pass `-PMStore <Name>` so your real library is untouched.

```sh
"build/Build/Products/Debug/Peanut Manager.app/Contents/MacOS/Peanut Manager" \
  -PMStore DesignCheck -PMSeedSample YES -PMFakeAI YES -PMAutoGenerate YES -PMAutoPositions YES
```

| Flag | Effect |
|---|---|
| `-PMStore Name` | Use a separate library file (`Name.store`) |
| `-PMSeedSample YES` | Create the sample team (anonymized real GameChanger stats) if the library is empty |
| `-PMFakeAI YES` | Scripted local "AI" (no key, no cost); its first defense is deliberately invalid so check → revise runs |
| `-PMAutoGenerate YES` | Make the batting order as soon as the first game opens (games you add later start empty) |
| `-PMAutoPositions YES` | Then fill positions |
| `-PMOpenPositions YES` | Go to the Positions step and lock one spot |
| `-PMNoAI YES` | Act as if no AI is set up (no ChatGPT sign-in, no Claude key); the keychain is untouched |
| `-PMAddGame YES` | Add a game after the team's last one, with one player out, and open it |
| `-PMCopyLastGame YES` | Copy the last game's lineup into an empty game when it opens |
| `-PMHoverInning N` | Show inning N's header as if hovered (its menu button) |
| `-PMDiamond N` | Open inning N on the field (the diamond popover) |
| `-PMOpenPicker YES` | Open the position picker |
| `-PMSection roster\|team\|rules` | Open that section |
| `-PMOpenSettings YES` / `-settingsTab models` | Open Settings / a tab |
| `-PMScrollToChecks YES` | Scroll to the summary once filled |
| `-PMScrollTo <id>` | Scroll a Stats & Insights tab to a section |
| `-PMAssessTeam YES` | Assess the team when Stats & Insights opens (use with `-PMSection team`) |
| `-teamTab summary\|offense\|defense\|stats` / `-playerTab stats\|scouting\|evaluation` | Open that tab |
| `-PMFlakyScout YES` | With `-PMFakeAI`: Player03 times out once, Player05 always fails (tests retries and resume) |
| `-PMSignedOut YES` | Act signed out of ChatGPT; your real sign-in stays in the keychain |
| `-PMShowSignIn YES` | Show the Sign in with ChatGPT sheet that follows creating the first team |
| `-PMRunEval YES` | Run the model eval on this library (see **Model eval** below) |

## Model eval

Compares the ChatGPT models (Luna, Sol, Terra, Astra) on one hard game and a few players, as cheaply as possible: each model once, at one thinking level, one call at a time. It runs on the coach's real ChatGPT plan, so it spends real usage (the first run was 22 calls, about 96k tokens).

```sh
# 1. Copy the library (never run it on the real one)
AS=~/Library/Application\ Support/Peanut\ Manager
for f in "$AS"/Library.store*; do cp "$f" "$AS/EvalCopy${f##*/Library}"; done

# 2. Run it
"build/Build/Products/Debug/Peanut Manager.app/Contents/MacOS/Peanut Manager" \
  -PMStore EvalCopy -PMRunEval YES \
  -PMEvalGame "<game>" -PMEvalRules "<rule set>" -PMEvalPlayers "<name>,<name>,<name>"
```

| Flag | Effect |
|---|---|
| `-PMEvalGame <opponent>` | The game to line up, with its locks and availability |
| `-PMEvalRules <rule set>` | Use this rule set instead of the game's (to make it harder) |
| `-PMEvalPlayers "a,b,c"` | Players to assess (first names or full names) |
| `-PMEvalModels "id,id"` | Only these models (default: the newest Luna, Sol, Terra and Astra, plus `claude-haiku-5-5` and `claude-sonnet-5-5` when a key is set) |
| `-PMEvalEffort medium` | Thinking level (default: Medium) |
| `-PMEvalWeighting gc-heavy` | Data weighting instead of the game's (`gc-only`, `gc-heavy`, `equal`, `coach-heavy`, `coach-only`) |

- **Claude:** set `ANTHROPIC_API_KEY=sk-ant-…` in front of the launch command to add Claude models. They run on the Claude API (a Max or Team plan's monthly credits, or paid credits), so unlike ChatGPT they cost money; the log and Reveal Models show each run's cost. Eval only: the app itself is still ChatGPT-only.
- **Output:** `~/Library/Application Support/Peanut Manager/Evals/<Store>/` holds `results.json`, `progress.log` and `grade.html`. The page opens when the run ends.
- **Grading is blind:** each lineup and assessment is labeled A, B, C… Grade them (print as-is?, quality; accurate?, useful), then **Reveal Models** shows which model made what, with time, tokens, revisions, safety-net cells and lock-move attempts. **Copy Grades** puts the grades on the clipboard.
- **Cheap by design:** finished runs are never repeated (relaunch to retry only what failed), a stored assessment from the same model on the same facts is reused, and a usage-limit or sign-in error stops the run at once.
- **Check the setup with `-PMFakeAI YES` first.** That runs the whole pipeline for free.
- **Afterwards,** delete the copy: `rm "$AS"/EvalCopy.store*` (and the `Evals/EvalCopy` folder once graded). Results contain real names; they stay on this Mac and never go in the repo.

Results and decisions so far are in `docs/v2-plan.md` (Build status, item 5).

## How generation works

1. **Feasibility** (code): enough players, and someone eligible at every position. Otherwise the app stops before calling the AI and offers fixes. Locks that break a rule (or can't all be kept) go to the coach first: **Fill Anyway** or Cancel. The AI is never asked to fix them.
2. **Decide** (AI): batting order, then defense around the coach's locks, using v1's prompts. Code puts every lock back on every AI answer; the AI only fills the open spots.
3. **Verify** (code): `Validator` checks the invariants and every rule with a code check.
4. **Revise** (AI, up to 2 rounds): the exact violations go back to the AI.
5. **Safety net** (code, last resort): `Repair` makes the fewest changes it can. Those cells are outlined in orange and disclosed.

Compliance shown in the app always comes from the validator, never from the AI's self-report.
