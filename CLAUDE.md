# Peanut Manager (Mac) — notes for coding agents

Native SwiftUI + SwiftData macOS app (macOS 26+, Swift 6, XcodeGen) that makes youth baseball lineups with AI. Read `README.md` for build/run, and `docs/v2-plan.md` (especially **Build status**) for what's done, what's next, and why.

## Product rules (from the owner; don't drift)

- **AI decides, code guarantees.** The AI assesses players and decides the batting order and positions. Code supplies facts, validates, sends violations back for the AI to revise, and only as a disclosed last resort repairs. Never add a deterministic lineup generator.
- **AI assessments (player/team insights) are the second core pillar** (plan §5). First slice built (`Scout`, Insights page, Scouting Report); claims cite fact IDs, and the UI shows values from the fact sheet, never numbers the AI wrote.
- **Port the AI, don't reinvent it.** v1's prompts (in `Prompts.swift`) are the proven baseline. Change prompts only when evals show a change beats v1.
- **Local-first and free.** No accounts, no server, BYOK OpenRouter key in the keychain.
- **Design bar: Apple / Cultured Code (Things 3).** Intuitive, minimal, no explanatory paragraphs, color only when it means something, the complicated made to feel simple. The owner reviews screenshots closely; show real screenshots, not descriptions.
- Night-before flow is the hero path: batting order → lock spots → Fill the Rest → print.

## Architecture

- `Packages/LineupKit` (pure, portable, tested; `swift test`):
  - `Validator` (invariants + `RuleCheck`), `Validator.feasibility`
  - `Repair` (minimal-change safety net)
  - `Prompts` (v1 port + fixes), `LineupEngine` (decide → verify → revise)
  - `AIResponses` (tolerant decoding, short IDs ↔ UUIDs, names in prose)
  - `GameChangerImport` (section-aware CSV)
  - `FactSheet` (citable facts with stable IDs), `Scout` + `ScoutPrompts` (player/team assessments; v1 analysis port)
- `Packages/LineupKit/Sources/LineupAI/OpenRouterClient.swift`: chat completions, key check, live model catalog.
- `PeanutManager/Model/Store.swift`: SwiftData models. Structured values are JSON blobs of LineupKit types. `LineupDocument` holds the working lineup, locks, provenance and reasons.
- `PeanutManager/Model/ScoutRunner.swift`: runs the Scout and saves assessments; app-wide so work survives navigation.
- `PeanutManager/Views/Games/GameModel.swift`: the game screen's state and actions (two-step generation, undoable edits, memoized context and findings).

## Pitfalls already hit

- **Exclusivity crash:** inside `GameModel.mutate { doc in … }`, use only `doc`. Reading `document`, `context` or `rows` inside the closure aborts the app. Compute first, then mutate.
- **Default MainActor isolation** is on for the app target. Codable or Sendable value types used off the main actor need `nonisolated` (see `LineupDocument`, `StatRow`, `FieldGeometry`, `FieldLines`).
- Building `GameContext` decodes every player; it's memoized by a hash key in `GameModel`. Don't call `game.context(...)` per grid cell.
- Never test against the owner's library: run debug builds with `-PMStore <Name>` (see README) and delete `~/Library/Application Support/Peanut Manager/<Name>.store*` afterward.
- The sample CSV and test fixture are anonymized; never commit real kids' names (the repo is public).

## Verify UI changes

Build, launch a scratch instance with debug flags, and screenshot the window (`CGWindowListCopyWindowInfo` to find the window ID, then `screencapture -l<id>`). There's no accessibility permission for synthetic clicks, so add a debug flag when a state is hard to reach.

## Commits

Commit at each meaningful step with a descriptive message. Push to `origin main` (https://github.com/martyvasquez/peanut-manager-mac-app) only when the owner asks. Once Sparkle is set up, pushing app changes to `main` ships them to every installed copy.
