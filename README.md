# Peanut Manager (Mac)

AI lineups for youth baseball and softball. The AI assesses your players and decides the batting order and every inning's defense; the app checks every lineup against your rules before you see it.

Plan and rationale: [`docs/v2-plan.md`](docs/v2-plan.md).

## Layout

| Path | What |
|---|---|
| `Packages/LineupKit` | Pure Swift core: models, validator, safety-net repair, v1 prompts, lineup engine, GameChanger import. `swift test` runs in seconds. |
| `Packages/LineupKit/Sources/LineupAI` | OpenRouter client (bring your own key). |
| `PeanutManager/` | SwiftUI + SwiftData Mac app. The library is stored in `~/Library/Application Support/Peanut Manager/`. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and not committed. |

## Build & run

```sh
cd Packages/LineupKit && swift test && cd ../..
xcodegen generate
xcodebuild -project PeanutManager.xcodeproj -scheme PeanutManager -derivedDataPath build build
open "build/Build/Products/Debug/Peanut Manager.app"
```

Add your OpenRouter key under **Peanut Manager → Settings** (⌘,). It's stored in the keychain.

### Debug launch flags (Debug builds only)

```sh
open "build/Build/Products/Debug/Peanut Manager.app" --args \
  -PMSeedSample YES -PMFakeAI YES -PMAutoGenerate YES -PMScrollToChecks YES
```

- `-PMSeedSample`: create the sample team (anonymized real GameChanger stats) if the library is empty
- `-PMFakeAI`: scripted local "AI" (no key, no cost). Its first defense is deliberately invalid so the check → revise path runs.
- `-PMAutoGenerate`: generate as soon as the game opens
- `-PMScrollToChecks`: scroll to the game plan and checks

## How generation works

1. **Feasibility** (code): enough players, someone eligible at every position. Otherwise the app stops before calling the AI.
2. **Decide** (AI): batting order, then defense, using v1's prompts.
3. **Verify** (code): `Validator` checks the invariants and every rule that has a code check.
4. **Revise** (AI, up to 2 rounds): the exact violations are sent back for the AI to fix.
5. **Safety net** (code, last resort): `Repair` makes the fewest changes it can. Those cells are outlined in orange and disclosed.

Compliance shown in the app always comes from the validator, never from the AI's self-report.
