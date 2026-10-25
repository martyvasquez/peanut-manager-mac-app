# Peanut Manager (Mac) — notes for coding agents

Native SwiftUI + SwiftData macOS app (macOS 26+, Swift 6, XcodeGen) that makes youth baseball lineups with AI. Read `README.md` for build/run, and `docs/v2-plan.md` (especially **Build status**) for what's done, what's next, and why.

## Product rules (from the owner; don't drift)

- **AI decides, code guarantees.** The AI assesses players and decides the batting order and positions. Code supplies facts, validates, sends violations back for the AI to revise, and only as a disclosed last resort repairs. Never add a deterministic lineup generator.
- **AI assessments (player/team insights) are the second core pillar** (plan §5). First slice built (`Scout`, Insights page, Scouting Report); claims cite fact IDs, and the UI shows values from the fact sheet, never numbers the AI wrote. Assessments need season stats (owner, Oct 23): no stats, no scouting report; ratings and notes add to stats but can't stand alone (`Player.isAssessable`).
- **Port the AI, don't reinvent it.** v1's prompts (in `Prompts.swift`) are the proven baseline. Change prompts only when evals show a change beats v1.
- **Local-first and free.** No server and no accounts of our own. The AI runs on the coach's ChatGPT plan via Sign in with ChatGPT, or on Claude with the coach's own Anthropic API key (added Oct 20 after Sonnet 5.5 led the rule-following models in the blind evals; Max and Team plans include API credits). Both live in the keychain. OpenRouter was removed on Oct 3; don't bring it back.
- **Every rule is met.** The coach's confidence that all rules are fulfilled is the core promise. Rule adherence gates model and prompt choices before lineup quality.
- **Design bar: Apple / Cultured Code (Things 3).** Intuitive, minimal, no explanatory paragraphs, color only when it means something, the complicated made to feel simple. The owner reviews screenshots closely; show real screenshots, not descriptions.
- Night-before flow is the hero path: batting order → lock spots → Fill the Rest → print.
- **The app works fully without AI** (App Store direction, Oct 22). The coach drags players into the batting order, then picks positions; a taken position swaps, so two kids can't share one. Coaches can copy a previous game's lineup as a starting point. AI is an extra button on the same screens, never a gate, and code never fills spots on its own.
- **Locks are the coach's decisions; the AI fills the rest.** This is the core feature. Code puts every lock back on every AI answer (`LineupEngine.keepingLocks`), a lock that breaks a rule goes to the coach (Fill Anyway), never to the AI, and nothing on screen may describe a lock being moved.

## Architecture

- `Packages/LineupKit` (pure, portable, tested; `swift test`):
  - `Validator` (invariants + `RuleCheck`), `Validator.feasibility`
  - `Repair` (minimal-change safety net)
  - `Prompts` (v1 port + fixes), `LineupEngine` (decide → verify → revise)
  - `AIResponses` (tolerant decoding, short IDs ↔ UUIDs, names in prose)
  - `GameChangerImport` (section-aware CSV)
  - `FactSheet` (citable facts with stable IDs), `Scout` + `ScoutPrompts` (player/team assessments; v1 analysis port)
- `Packages/LineupKit/Sources/LineupAI/ChatGPT`: Sign in with ChatGPT and the ChatGPT plan client. `LineupAI/Anthropic`: the Claude client (Messages API with the coach's key). `PeanutManager/Model/AIService.swift` owns the sign-in, the Claude key, and the model choice (a saved key makes Claude Sonnet the default).
- `PeanutManager/Model/Store.swift`: SwiftData models. Structured values are JSON blobs of LineupKit types. `LineupDocument` holds the working lineup, locks, provenance and reasons.
- `PeanutManager/Model/ScoutRunner.swift`: runs the Scout and saves assessments; app-wide so work survives navigation.
- `PeanutManager/Views/Games/GameModel.swift`: the game screen's state and actions (two-step generation, undoable edits, memoized context and findings).
- `PeanutPhone/`: the iPhone app (plan item 3). It compiles the Mac's model files above directly. **The Mac app is frozen at tag `mac-1.0`** (in App Review): in shared files, only `#if os(macOS)` guards or pure moves, and build both schemes after any change.

## Pitfalls already hit

- **Exclusivity crash:** inside `GameModel.mutate { doc in … }`, use only `doc`. Reading `document`, `context` or `rows` inside the closure aborts the app. Compute first, then mutate.
- **Default MainActor isolation** is on for the app target. Codable or Sendable value types used off the main actor need `nonisolated` (see `LineupDocument`, `StatRow`, `FieldGeometry`, `FieldLines`).
- Building `GameContext` decodes every player; it's memoized by a hash key in `GameModel`. Don't call `game.context(...)` per grid cell.
- Launch flags that name a stored setting (`-teamTab`, `-playerTab`, `-settingsTab`) override `@AppStorage` for the whole run, so the control can't change it. Use them only for screenshots; launch builds for Marty without them.
- Never test against the owner's library: run debug builds with `-PMStore <Name>` (see README) and delete `~/Library/Containers/com.martyvasquez.PeanutManager/Data/Library/Application Support/Peanut Manager/<Name>.store*` afterward. The app is sandboxed, so its files live in that container; the first sandboxed launch moved the library there (`container-migration.plist`), and debug flags can't write outside it (`-PMPrintTo` needs a path inside the container).
- **iCloud sync:** release builds (TestFlight, App Store) sync the coach's library in CloudKit production. Debug builds use the development environment and never sync the real library; test sync with two test libraries and `-PMSync YES` (one seeds and uploads, an empty one downloads). After any model change: run `-PMInitCloudKitSchema YES`, then deploy the schema to production in the CloudKit Console. Production only accepts additions.
- `-PMStore` separates the library, not the settings: test runs share UserDefaults with the owner's app. A debug path that would save a setting (consent, model choice, selected team) must keep it in memory instead (see `-PMAutoAllow`).
- The sample CSV and test fixture are anonymized; never commit real kids' names (the repo is public).

## Verify UI changes

Build, launch a scratch instance with debug flags, and screenshot the window (`CGWindowListCopyWindowInfo` to find the window ID, then `screencapture -l<id>`). There's no accessibility permission for synthetic clicks, so add a debug flag when a state is hard to reach.

## Commits

Commit at each meaningful step with a descriptive message. Push to `origin main` (https://github.com/martyvasquez/peanut-manager-mac-app) only when the owner asks. Pushing ships nothing: Sparkle was removed (Oct 23); the App Store and TestFlight are the only way out.
