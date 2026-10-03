# Peanut Manager v2 — Improvement Plan & Mac Port Direction

**Status:** Draft 8 · October 2, 2026 · First build shipped to `main` (see *Build status*)
**Audience:** Marty, other developers, coding agents
**Source app:** `~/Development/baseball-lineups` (Next.js + Supabase, v1.7.6, Feb 2026)
**Target app:** this repo (`~/Development/peanut-manager-mac`), a native macOS app

---

## Build status (Oct 3, 2026)

Repo: https://github.com/martyvasquez/peanut-manager-mac-app (public). Bundle ID `com.martyvasquez.PeanutManager`, macOS 26+. Marty is using it with a real team (SMV Trojans, LL Majors).

### Done

- **Core (`LineupKit`, 42 tests):**
  - Validator: all built-in invariants (§4.3) plus 8 checkable rule types.
  - Feasibility check: reports each problem once.
  - Minimal-change safety net: property-tested over 300 random broken lineups.
  - v1 prompts ported, with the audited fixes (Appendix B #13, #15, #16, #18).
  - Decide → verify → revise engine.
  - Batting-order feedback.
  - Short player IDs; the model's prose is converted back to names.
  - GameChanger import: section-aware; batting, fielding, pitching and catcher innings; exact matching.
- **The night-before path (M2):**
  - Two-step lineup: (1) batting order list with drag reorder and "Remake…"; (2) empty grid → lock spots → **Fill the Rest**.
  - Click-to-pick position picker: open / taken (swap) / current / can't / best.
  - Real swaps and persisted edits.
  - Undo; versions (snapshot before every remake); Clear Positions / Clear Lineup.
  - Keyboard (1–9 scorebook, 0 sit, Space lock, ⌥↑↓), drag reorder in the grid.
  - Summary: "Follows your rules," checked vs. AI-judged rules, notes, plan.
- **Roster:**
  - Field-diagram positions (doesn't play / plays / best).
  - Notes; grouped star ratings (pitching and catching only when relevant); stat tiles.
  - GameChanger history turns on P/C automatically, without overriding coach edits.
- **Rules:** rule sets, plain text, attach a code check per rule.
- **Games:**
  - Chips: attendance with late/early, rules, innings, priority, trust, model.
  - Notes for the AI, and an opponent **scouting report** that is sent to both prompts and carries over to the next game against the same opponent.
  - Settings carry over from the last game.
  - Feasibility alert offers "Use GameChanger History" / "Open Roster."
- **Stats:** full-width sortable table; import sheet with match review.
- **Settings:** OpenRouter key in keychain + test; Models tab with OpenRouter's live catalog (search, prices, pin); default `anthropic/claude-sonnet-5.5`; Muse Spark 1.3 Contributor included.
- **App:** icon and accent color; local SwiftData store in its own folder; debug launch flags (README).

### Still to do (priority order)

1. **Sparkle auto-update + release workflow** (M0 remainder). Follows `baseball-situational-simulator/docs/mac-auto-update-playbook.md`.
   - Done: Sparkle 2.10.0 (pinned in `project.yml`), `AppUpdater` (off in Debug), "Check for Updates…", Info.plist keys, feed URL `https://github.com/martyvasquez/peanut-manager-mac-app/releases/latest/download/appcast.xml`.
   - Done: EdDSA key in Marty's login keychain (`--account com.martyvasquez.PeanutManager`). Losing it means installed copies can never update.
   - Done: local 127.0.0.1 update test (build 5 → 6 in ~2 s) and tamper test (rejected, stayed on 6).
   - Done: `.github/workflows/release-mac.yml` (zip asset `PeanutManager.zip`, tags `build-N`, N = run number + 100; CI must `brew install xcodegen` since the project isn't committed).
   - Done: `SPARKLE_PRIVATE_KEY` repo secret.
   - Done: first real releases. Build 101 (downloaded like a user) updated itself to 102 in ~4 s.
   - **Pushing app changes to `main` now ships them to every installed copy.**
   - The bundle ID, feed URL, public key, asset name and tag format are now fixed forever.
2. **Sign in with ChatGPT (replaces the OpenRouter key as the default).** Planned; next to build. Marty: "a huge, huge win."
   - What: OpenAI's [Sign in with ChatGPT](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt). The coach signs in with their ChatGPT account and AI calls run on their Plus/Pro plan: no key, no credits, no bill to us. Eligible: "open-source projects, personal projects that run locally" (we're both). Free ChatGPT accounts can't use it.
   - **Decided (Oct 3):** ChatGPT is the default provider for new installs right away; installs that already have an OpenRouter key keep OpenRouter. The OpenRouter key stays as "Use an API key instead" (free ChatGPT users; Claude, Gemini, Muse). Marty tests on a **Plus** account.
   - Spec: the full protocol is in `https://developers.openai.com/siwc/llms-full.txt` (section "Registration and sign-in" onward). Don't copy the DevKit (Node/React, noncommercial license); write it in Swift from the docs.
   - Protocol summary:
     - Install ID: generate `urn:uuid:<UUIDv4>` once per install and keep it forever (`ext_agent_host_id`; opaque, not a credential).
     - Authorize: system browser → `https://auth.openai.com/api/accounts/authorize` with `client_id=dynamic_agent_client` (first time) or the saved issued `oaiapp_…` ID, `agent_name_hint=Peanut Manager` (first time only), `ext_agent_host_id`, `response_type=code`, `redirect_uri=http://127.0.0.1:<port>/auth/callback` (1455 first; only the port may vary; never `localhost`), `scope=openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, `resource=https://api.openai.com/v1`, fresh `state`/`nonce`, PKCE S256. Returning sign-in adds `id_token_hint` / `login_hint`.
     - Callback returns `code`, `state`, issued `client_id` (new registration). Exchange at `https://auth.openai.com/api/accounts/oauth/token` (form-encoded, no secret, same `redirect_uri` and `resource`).
     - Validate the ID token (JWKS signature, issuer, audience = issued client ID, expiry, nonce). Plan use is on only if granted scopes include `chatgpt.tokens.use.direct`.
     - Tokens: access 1 h; refresh 30 days, rotating on each refresh. Refresh with `grant_type=refresh_token`, the issued client ID, `resource`; serialize refreshes. Sign out: revoke the refresh token (`revocation_endpoint` from `/.well-known/openid-configuration`), clear tokens, keep client ID + install ID.
     - Inference: `POST https://api.openai.com/v1/responses`, `stream: true`, `store: false`, system prompt as `instructions`, history in `input`. Not allowed: `max_output_tokens`, `temperature`, `top_p`, `previous_response_id`, `metadata`, `user`, system-role items. Success only on `response.completed`; handle `response.failed` / `response.incomplete` / dropped streams.
     - Models: `GET https://api.openai.com/v1/models` → `models[]` with `slug`, `display_name`, `visibility` (show `"list"` only, server order).
     - Errors: `subscription_sharing_usage_limit_exceeded` (429: stop, show Manage usage), `…_user_not_eligible` (403: explain, don't retry), `…_usage_unavailable` / `…_user_unavailable` / direct-admission 503 (retry with backoff), `…_unsupported_capability` (400: fix the body), 401 (sign in again). Admission errors may be `{"detail": "..."}` instead of `error`.
   - Required UI (OpenAI's guidelines): **Continue with ChatGPT** button with approved branding; one-time "You're using your ChatGPT plan" · Got it; **Using ChatGPT plan · Manage usage** near the model picker; usage-limit message with Manage usage (https://chatgpt.com/settings/usage) as the primary action.
   - Plus has a 5-hour usage cap shared across all apps; a full team assessment with a reasoning model may hit it mid-run. Runs already resume per player; surface the limit clearly.
   - Steps:
     1. **Test: done (Oct 3), everything worked on Marty's Plus account.** A throwaway Swift CLI (not committed) signed in through the system browser with the loopback callback, got an issued `oaiapp_…` client ID and all six scopes including `chatgpt.tokens.use.direct`, listed models, refreshed an expired token (refresh token rotated), and ran the real `LineupEngine` end to end.
        - Models on Plus (`visibility: "list"`, server order): `gpt-6-astra` (frontier, default effort low), `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` (fast), `gpt-5.5`. All 272K context; efforts low…max/ultra. The docs' example slug `gpt-6.1-sol` isn't offered, so never hard-code a slug: pick from the live list. The catalog's `available_in_plans` lists `free` too, so eligibility may be wider than "Plus and Pro"; check with a free account.
        - Sample 12-player, 6-inning game, v1 prompts unchanged: GPT-6-Astra and GPT-5.6-Terra were both **valid on the first try** (0 revisions, 0 findings, no safety-net cells). Astra: 28 s batting + 72 s defense. Terra: 16 s + 65 s. Hello-world on Luna: 2.7 s.
        - The Responses stream had no `x-request-id` header; look for the request ID in the response body when building error reports. The ID token carries `email`, `name`, `sub`, `auth_time` (use email as the account label in Settings).
     2. **`LineupAI`:** `ChatGPTAuth` (PKCE, loopback listener via Network.framework, code exchange, JWKS check, refresh actor, revoke) and `ChatGPTClient: LLMClient` (Responses SSE via `URLSession.bytes`), with error mapping. Tests with stubbed `URLProtocol`.
     3. **App:** credential record in the keychain; `AIProvider` setting; one client factory replacing the three `OpenRouterClient(apiKey:)` sites (`GameModel`, `ScoutRunner`, `SettingsView`); model choice stored per provider; Settings card (account, Sign Out, Manage usage), OpenRouter key under "Use an API key instead"; onboarding leads with Continue with ChatGPT.
     4. **Polish:** welcome message, "Using ChatGPT plan" label, usage-limit alert, hide cost for plan usage.
     5. **Check quality:** same games on Marty's team, Sonnet vs. the best ChatGPT model; feeds the evals work (item 4).
   - Risks: new program; terms and access can change. Re-read OpenAI's terms before shipping it via Sparkle.
   - Supersedes the earlier "drive the `codex` CLI" idea. Using a Claude subscription through the `claude` CLI is still only an idea (item 8).
3. **AI player & team assessments (§5, M3).** First slice built.
   - Done: `FactSheet` (stats, ratings, positions, notes as citable fact IDs; team rates from counts), `Scout` (v1's analysis prompts ported, with ratings/notes/positions as inputs and fact-ID citations; one retry when a citation doesn't exist, then it's dropped), cached `PlayerAssessment` / `TeamAssessment` on `Player` / `Team`, stale when the player's facts change.
   - Done: player page tabs (Stats · Scouting Report · Coach's Evaluation; the last tab is remembered); Stats & Insights section replacing Stats and Insights (Team Summary · Players · Stats); Insights content (team summary, strengths/work on with evidence chips, leadoff / middle / defensive core, practice plan, every player in a line). "Assess Team" re-assesses only changed players, three at a time, then the team.
   - Resilient runs: each player is saved the moment it's done, so a quit or failure resumes where it stopped; timeouts, rate limits and server errors retry up to 3 times (10 s, 30 s); a bad key or no credits stops the run at once. Each player shows Waiting / Assessing · m:ss / Trying again / failed with reason. The team summary is written only after every player is done, and shows "Out of date" when it doesn't cover the current assessments.
   - Run once on Marty's real team with Muse Spark (a reasoning model, 2–3 min per player); that exposed the 3-minute timeout, now 10 minutes.
   - Left: feed assessments into the Strategist prompt (a prompt change, so gate it on evals, item 4); coach pushback ("Disagree"); re-assess on import; history and trends; season ledger facts (needs item 9); printable practice sheet; Jev claim checks; a separate Scout model setting (uses the lineup model today).
4. **Evals (§10).** Not started. Needs:
   - A golden set: fixture teams as JSON, Marty's real rules/rosters, expected rule templates, assessment fixtures.
   - Harness: `swift test --filter Evals`, or a small CLI hitting OpenRouter.
   - Metrics: valid-first-try, revisions, safety-net use, cost, latency, Marty-graded quality.
   - Use the results to compare models (Sonnet vs. Muse, etc.) and gate prompt changes against v1.
5. **Printing & sharing (§6.6).**
   - A lineup card prints via `NSPrintOperation` but has **never been tested on paper**.
   - Needs a real print check, layout polish (jersey numbers, position key, big type), PDF export, "Copy as text" for team chats, and an optional per-inning dugout card.
6. **Rules intelligence (§4.3, §8.4, M5).**
   - AI Rule Interpreter that fills "Understood as…" checks automatically (today the coach attaches checks by hand).
   - Jev (Decisions API) cascade.
   - Learn-from-edits suggestions (§6.9).
7. **Rules UI/UX redesign.** Marty doesn't like how rules are presented, created or edited today. Direction **not yet decided**; revisit with him before building.
   - Problems seen so far:
     - Rules live far from where they're used: a separate sidebar section, plus a "rule sets" middle column.
     - A rule's code check is hidden and separate from its words. The text can say 3 while the check says 2.
     - Adding a rule starts from an empty line with no suggestions.
     - Enforced rules and AI-judgment rules look almost the same.
   - Options discussed, none chosen:
     - **Structure:** rulebooks as tabs on one full-width page; *or* one team rulebook plus per-game tweaks; *or* rules living inside each game.
     - **Checks:** recognize common rules from plain English locally (number becomes an editable token in the sentence); *or* pick from a library; *or* AI interprets every rule.
     - **Adding:** type with suggestions; *or* a starter-library sheet; *or* a bare text line.
   - **Decided: Jev is the rule engine** (Decisions API, same OpenRouter key; see §8.4):
     - **Interpreter:** every rule's text → Jev *Choice* over the `RuleCheck` catalog (plus "judgment only"). The number comes from candidates found in the sentence ("select, don't generate"). Above a confidence threshold, the check is attached automatically and the number becomes an editable token; below it, the app shows "AI judgment" or asks the coach (Q8).
     - **Evaluator for judgment rules:** after positions are filled, one Jev *Noul* per judgment-only rule against a compact text rendering of the lineup. It is shown as a probability ("Jev: 92% likely followed") and labeled as a second opinion, not a guarantee.
     - **Not for countable rules:** Jev doesn't count reliably (TypeSafe's own docs); the `Validator` stays the source of truth for anything with a number.
     - Needs: a Decisions API client in `LineupAI` (alpha endpoint, behind a protocol); an eval set of real rules with expected interpretations; threshold tuning.
8. **Use a Claude subscription instead of an API key.** Idea only.
   - A `ClaudeCodeClient` implementing `LLMClient` by running the user's installed CLI headless (`claude -p … --output-format json`, tools off, one turn). Check flags against the current version first.
   - Possible only because the App Sandbox is off. Dock-launched apps don't get the shell PATH: look in the usual install folders or ask `zsh -lc 'command -v claude'`.
   - Downsides: CLI startup per call, no model catalog, no cost data. **Check Anthropic's terms first**; using a consumer subscription from a third-party app is a gray area.
9. **Season & game day (§6.2–6.5, M4).**
   - Playing-time ledger across games, fed to the AI as facts.
   - Pitching tracker with rest-day presets.
   - Game-day mode with mid-game re-plan.
   - Game status/score entry: `ourScore` / `theirScore` exist in the model with no UI.
10. **Smaller gaps:**
   - Show AI cost: tracked per lineup in `LineupDocument.cost`, not displayed anywhere since the design pass.
   - JSON backup/export of the library (§7.2).
   - Edit a game's date after creation (only the opponent is editable inline).
   - Per-task model picker: only the lineup task exists today; Scout/Interpreter will need their own.
   - Structured outputs (`response_format: json_schema`) and prompt caching (§8.3).
   - Softball / 10-fielder formats (Q4).
   - No app-target UI tests; only `LineupKit` is tested.
11. **Unverified by the builder (needs Marty's hands):**
   - Drag-to-reorder in the grid and list (code path exercised programmatically after the crash fix).
   - A real model filling around locks.
   - Printing.
   - In some Debug launches two identical windows appeared; investigate window restoration.

---

## The problem

Setting a youth lineup can take **an hour the evening before every game**. The coach juggles:
- league rules;
- how competitive to be this week;
- each kid's ability and growth;
- who sat last time;
- who can pitch;
- who's missing.

It's a chess game every week, and it's exhausting.

**v1 proved the idea works.** Marty used it heavily through a season and grades it a **B**:
- **The insights were good.**
- **The lineups were good.**
- **The UI/UX held it back.** It should be smoother, faster and more refined.

So v2 is **not** an AI rethink. It is primarily a UX upgrade: a native Mac app built on v1's proven AI core, plus targeted reliability fixes from the audit. The audit's AI findings (unchecked rules, dropped inputs, broken stats fields) are what keep a B from being an A. They're refinements, not a redesign.

**Peanut Manager's job: have AI do it, based on data.** The coach opens the game, confirms who's coming, clicks once, and gets a lineup they trust: rule-compliant, competitive at the level they asked for, fair across the season, and explained. Then they tweak a cell or two and go to bed.

Everything in this plan is judged against that evening:

| Measure | Target |
|---|---|
| Time from opening the game to a printed lineup card | **< 5 minutes** (vs. ~60 today) |
| Coach edits after generation | Few. Each edit is a signal (§6.9). |
| Lineups that violate a hard rule | **0** |
| Coach re-does the lineup by hand because they don't trust it | Never. Reasons and verified compliance are visible. |

## 0. TL;DR

v1 asked an LLM to read the roster, stats and plain-language rules, then build the lineup and report its own compliance. In real use it produced good insights and good lineups (grade: B). What held it back was a web UI that wasn't smooth, fast or refined, plus some gaps: nothing checked the AI's work, some inputs never reached it, and coach edits were never saved.

v2 keeps what made v1 good (plain-language rules, coach control, GameChanger data, two-phase batting → defense) and changes three things:

1. **AI assesses and decides; code guarantees.** The AI is the coach's brain, and it has two equally important jobs:
   - **Assessments.** It reads the GameChanger stats, the coach's ratings and notes, and the season history, then tells the coach who each player really is and what the team needs to work on.
   - **Lineups.** Using those assessments, it decides the batting order and every defensive assignment, with reasons.

   That's the product, as pitched on peanutmgr.com.

   What changes is everything around it:
   - **Better facts in.** Code computes stats, season playing-time debt and pitching availability, and passes them to the AI. Coach notes are actually included.
   - **A deterministic validator** checks every AI lineup against the hard rules.
   - **A verify → revise loop** sends exact violations back to the AI to fix.
   - **A last-resort minimal repair** that is always disclosed to the coach.

   Compliance is computed by code, never self-reported by the model.
2. **Local-first, no accounts, free.** A native SwiftUI Mac app stores data on disk. There is no Supabase, auth, Stripe or marketing site. Users bring their own **OpenRouter** key and can pick a model per task. Sparkle handles updates from GitHub Releases.
3. **Season-aware, game-day-ready.** Playing-time and pitching history carry across games. Lineups persist with full edit history. Game-day mode handles mid-game changes. Lineup cards print properly.

The web app will be retired. It has no active users, and v1 data is not carried over. The Mac app starts fresh and fully local.

---

## 1. What v1 got right (keep)

| Keep | Why |
|---|---|
| **AI assesses the team and decides the lineup** | The core idea of the app (and the pitch). v2 makes the AI better informed and its output trustworthy. It does not replace it. |
| Player Insights / Team Insights | Half of the value: coaches learn about their kids and what to practice. v2 makes these deeper and grounded. |
| Plain-language team rules, grouped into named sets | Leagues all have different, oddly worded rules. The AI reads them as written. |
| Two-phase flow: batting order → defense | Matches how coaches think. Batting order is mostly stable; defense is the puzzle. |
| Lock cells / lock innings, then "fill the rest" | Coach stays in control; the AI fills the gaps. This is the best interaction in v1. |
| Regenerate with feedback ("Move Jake to outfield") | Natural and fast. |
| Game priority (win ↔ develop) and data weighting (stats ↔ coach eye) | Good knobs for steering the AI. v2 saves them with each lineup and backs them with concrete facts (e.g., season debt), not just adjectives. |
| GameChanger CSV import | Still the only practical data source. GameChanger won't grant API access. |
| Interactive grid: players × innings | The right core view. On a Mac it gets much better (keyboard-driven). |

### 1.1 The pitch (peanutmgr.com) and what v2 must make true

The marketing site is the product spec. It promises:
- "Combine real GameChanger statistics with your coaching insights. AI does the analysis — you get optimized lineups in seconds."
- "Our AI combines your ratings with real game stats to understand each player's true strengths and optimal role."

Each claim, how v1 actually behaved, and what v2 commits to:

| Pitch claim | v1 reality (audit) | v2 commitment |
|---|---|---|
| Import batting, fielding **and pitching** stats; AI analyzes AVG, OBP, SLG, FPCT… | Pitching stats parsed then discarded; stats analysis read missing columns, so team K% and BB% were sent as 0% | All three stat families kept as dated snapshots; every number computed in code (§6.7) |
| Coach ratings on 14 skills capture "things the stats don't" | Ratings removed from the analysis prompts in v1.7.4; unrated was sent as 3 | Ratings, notes **and** stats feed every assessment; disagreements between eye and data are surfaced (§5) |
| "AI combines your ratings with real game stats to understand each player's true strengths and optimal role" | Stats-only analysis, never fed into lineups | Player assessments are first-class, cached, cited, and are the main input to lineups (§5) |
| Optimized batting orders (OBP at leadoff, power in the middle, speed where it matters) | Prompt recipe only | Strategist uses assessed batting roles; each slot's reason cites the assessment (§4) |
| Smart defensive rotations: strengths, fair time, best defenders where they count | Fairness was one prompt line; nothing tracked | Assessed position fit + season ledger + validator (§4, §6.2) |
| "100% compliant — every player, every inning, every game" | Not true; nothing checked it | Made true by the validator → revise → disclosed safety net (§4) |
| You set the strategy: rule groups, Win↔Develop, data weighting, locks; "AI fills around your decisions — never overrides them" | Mostly true, but edits and locks weren't saved and the "swap" was buggy | Kept and made reliable: persisted edits, real swaps, locks honored and verified (§6.1) |
| Player Insights and Team Insights (strengths and weaknesses with stats, recommended batting spot and positions, practice drills) | Generated; the team "lineup insights" were never shown | Richer assessments with evidence, trends, data-confidence and a practice plan (§5) |
| Baseball **and softball** | Baseball-centric prompts | Sport is a team setting; prompts, positions and presets account for it (Q4) |
| Lineups in ~5 seconds | One long call per phase | Cached assessments keep lineup prompts small; progress is shown during revise rounds; latency is tracked in evals (§10) |

## 2. What the audit found (fix)

These come from a code-level audit of v1. CLAUDE.md in that repo is stale and lists files that were never committed.

### 2.1 Correctness gaps
- **No deterministic validation.** The "Rules Compliance" panel just shows the model's own `rules_check`. Nothing verifies all 9 positions are filled, that there are no duplicates per inning, that every player is accounted for, that the inning count is right, or that eligibility holds.
- **The repair logic can create new violations.**
  - The empty-position filler falls back to `batting_order[0]`, which can put one player in two positions.
  - The pitcher re-entry fix swaps in a fielder without checking `can_pitch` or locks.
- **Coach edits are never saved.** Manual cell changes, locks, reorders and the innings selector live only in React state. A reload drops them.
- **"Swap" isn't a swap.** Picking a taken position clears the other player's cell and leaves a stale lock behind.
- **The innings selector is cosmetic.** The server always uses `game.innings`.
- **Stats analysis sends broken data.** It reads columns the season view doesn't have, so team K% and BB% are always sent as 0%.

### 2.2 Inputs that never reach the lineup AI
`players.notes` (coach notes), `pitching_innings_available`, `game_preferences`, per-player stats analysis, team analysis, and GameChanger pitching stats (parsed, then discarded).

Also: v1.7.4 removed coach ratings from the stats and team analysis prompts. That contradicts the site's core promise of combining ratings with stats. v2 reverses it.

### 2.3 Model confusion
- **Two overlapping position systems.** Eligibility flags (P/C/SS/1B) and a ranked "position strengths" list (which includes the non-position "OF") are never reconciled. A player can rank P first while `can_pitch = false`.
- **Unrated is treated as average.** Unrated ratings become **3** in prompts, so an unrated kid looks average.
- **Ratings by season aren't filtered.** When multiple rows exist, the last one wins.

### 2.4 Missing capabilities
- No playing-time tracking, within a game or across a season.
- No pitch counts or rest days.
- Lineup versions pile up but can't be viewed or compared.
- Game status and score can't be set.
- No late-arrival or early-departure handling.
- No real export (only a basic print window).
- No tests.

### 2.5 Things to drop
- Auth, billing (Stripe), profiles, the marketing site, and the multi-user/RLS model.
- Dead tables and columns: `player_metrics`, `game_preferences`, `game_state`, `innings_per_game`, `optimization_mode`, `innings_by_position`, `location`.
- The duplicated roster-import components.
- The 1,500-line `game-detail-client.tsx` god component. It doesn't port well; rewrite it.

---

## 3. Product principles for v2

1. **Port the AI, don't reinvent it.** v1's prompts and two-phase flow are the proven baseline. Port them first, then change them only when the eval set shows a change beats v1 on the same real games.
2. **Give the coach their evening back.** Every feature is judged by whether it shortens or simplifies the night-before routine. Defaults are remembered, the common path is one click, and nothing requires re-entering what the app already knows.
3. **The AI makes the call.** Batting order and positions come from the AI's judgment about these kids, this data, and these rules. Code feeds it, checks it, and protects it. Code never substitutes its own lineup logic for the AI's.
4. **Assessments are grounded and honest.** Every claim about a player points to evidence: a stat, a rating, a note or a trend. Numbers are rendered by code, never typed by the AI. Thin data is called thin ("only 14 PAs"). Where the coach's eye and the stats disagree, the assessment says so rather than averaging the disagreement away.
5. **Never present an invalid lineup as valid.** Every lineup is validated. Violations go back to the AI to fix. If hard rules truly can't all be met, the app says exactly which ones conflict and why.
6. **The coach is the final authority.** Every cell can be edited and locked. AI output is a proposal. The app remembers every change.
7. **Explain, don't lecture.** Each AI decision gets a short reason. Compliance is shown as facts ("Ava: 4 of 6 innings in field ✓"), not AI claims.
8. **Works with partial data.** No ratings, no stats, half a roster rated: all fine. Unrated means unknown, never 3.
9. **Fast and quiet.** Show progress while the AI works. Cache player assessments so each generation only sends what changed.
10. **Mac-native.** It should feel like Apple or Cultured Code built it. Design specifics come later (section 11).

---

## 4. The core architectural change: "AI decides, code guarantees"

### 4.1 Pipeline

```
 ┌─ PREPARE (code) ───────────────────────────────────────────────────────────┐
 │ Roster, position profiles, ratings (nil = unknown), coach notes             │
 │ Stats computed in code (rates, splits) from the latest GameChanger snapshot │
 │ Season ledger: sits, infield/outfield innings, who's owed what              │
 │ Pitching/catching availability today (rest rules, innings caught)           │
 │ Availability windows (late / leaves early), locks, priority, weighting      │
 │ Rules: plain text + their typed interpretation (if any)                     │
 └──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
 ┌─ FEASIBILITY CHECK (code, instant) ───────────────────────────────────────┐
 │ Can these hard rules be met at all with today's players?                    │
 │ No → tell the coach what conflicts *before* spending tokens.                │
 └──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
 ┌─ ASSESS (AI: Scout, cached) ──────────────────────────────────────────────┐
 │ Per-player assessment: hitting profile, best/acceptable positions, notes    │
 │ distilled, development needs. Re-run only when that player's data changes.  │
 └──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
 ┌─ DECIDE (AI: Lineup Strategist) ──────────────────────────────────────────┐
 │ Phase 1: batting order + reasons     Phase 2: full defensive grid + reasons │
 │ Respects locks; reads every rule as written (typed + soft)                  │
 └──────────────────────────────────┬──────────────────────────────────────────┘
                                    ▼
 ┌─ VERIFY (code) ───────────────────────────────────────────────────────────┐
 │ Validator: invariants + typed rules → findings                              │
 └──────────┬───────────────────────────────────────────────┬──────────────────┘
       valid│                                     violations │
            ▼                                                ▼
        PRESENT                     ┌─ REVISE (AI, ≤ 2 rounds) ─────────────────┐
  (validator compliance             │ "Inning 3: Ava is at SS and LF. Leo was     │
   + AI reasoning)                  │  pulled as P in inning 2 and returns in 4." │
                                    │  Fix these, change as little as possible.   │
                                    └──────────────────┬──────────────────────────┘
                                          still invalid│
                                                       ▼
                                    ┌─ SAFETY NET (code) ───────────────────────┐
                                    │ Minimal-change repair of remaining          │
                                    │ violations; cells marked "adjusted by app"; │
                                    │ coach told exactly what changed and why.    │
                                    └─────────────────────────────────────────────┘
```

### 4.2 What changes vs v1, and why
- **The AI is better informed.** v1 dropped coach notes, pitching availability and analysis results, sent unrated players as 3s, and had no idea who sat last game. v2 gives the AI computed facts and a cached scouting assessment for each player, so its judgment improves without bloating every prompt.
- **The AI's work gets checked.** v1 trusted the model's own `rules_check`. v2's validator is the only source of compliance truth. It runs on AI output and on every coach edit.
- **The AI fixes its own mistakes.** v1 used blind repair hacks that could create new violations (duplicate players, ineligible pitchers). In v2, the AI gets exact, cell-level findings and revises its own lineup, keeping its reasoning intact.
- **The fallback is honest.** If the AI still can't produce a valid lineup after two revisions, a small deterministic repair makes the fewest possible cell changes. Those cells are visibly marked. It's a safety net, not the decision-maker, and the eval set should show it rarely fires.
- **Swappable models are safe.** Because every model's output goes through the same validator and revision loop, the BYOK model picker can't ship a broken lineup. A weaker model just costs more revision rounds, and the evals measure that.

### 4.3 Rule interpretation (so code can check what the AI did)

The AI still reads every rule **as written**. In addition, each rule is interpreted once, when it's saved, into a typed **template** when one fits. That lets the validator verify it. The coach sees **"Understood as: …"** with editable parameters, and can correct it or mark the rule "AI judgment only."

**Built-in invariants** (always on, not user rules):
- All 9 positions are filled each inning.
- One position per player per inning.
- Every available player is either in the field or sitting.
- The inning count matches the game.
- Locks are respected.
- No pitcher re-entry once pulled.
- Position eligibility (profile ≠ Can't).
- Availability windows (see §6.3).

**Rule templates** (parameterized, checkable):

| Category | Template examples |
|---|---|
| Playing time | `minFieldInnings(n)`, `maxSitInnings(n)`, `maxConsecutiveSits(n)`, `fairSitRotation` (nobody sits twice before everyone sits once) |
| Position mix | `mustPlayInfieldBy(inning)`, `minInfieldInnings(n)`, `maxInningsAtSamePosition(n)`, `noConsecutiveOutfield(n)` |
| Pitching / catching | `maxPitchInningsPerGame(n)`, `maxCatchInningsPerGame(n)`, `catcherCannotPitchAfter(n innings caught)`, `rotateCatcherEvery(n)`, pitch-count/rest presets (§6.4) |
| Batting | `continuousBattingOrder` (everyone bats), `fixedSlot(player, slot)` |
| Player-specific | `never(player, position)`, `mustPlay(player, position, inning?)`, `minInningsAt(player, position, n)` |
| Season-scoped | `seasonBalance(metric)` e.g. sits, infield innings, leadoff count. Uses history (§6.2). |

Rules that don't fit a template (e.g., "keep the batting order balanced," "give the new kids easy innings") stay **AI judgment only**. The AI honors them, and the compliance panel shows them as "AI-assessed" with the AI's note, distinct from code-verified rules. Optionally, Jev can give an independent probability that each one was honored (§8.4). The template catalog grows by watching which rules end up judgment-only.

### 4.4 Feasibility check and safety net (code, intentionally small)
- **Problem size is tiny:** ≤ 9 innings × 9 positions × roughly 9–15 players. A custom Swift engine is enough, with no OR-Tools or ILP.
- **Feasibility check:** a quick constraint-propagation search answers "is there any valid lineup at all?"
  - If not, it finds a minimal conflicting set of rules and states it in coach language. Example: "Only 2 eligible catchers, but 'rotate catcher every 2 innings' + 'catcher can't pitch' + 6 innings needs 3."
  - This runs before any AI call, so tokens are never spent on an impossible request.
- **Safety-net repair:** starting from the AI's lineup, search for the valid lineup with the **fewest changed cells**. Tie-break toward cells the AI explicitly flagged as low-preference. It has no opinion about who is better. It only preserves the AI's lineup as closely as possible.
- **Not a lineup generator.** There is deliberately no code path that builds a lineup from scratch by its own scoring. Lineup judgment lives in the AI.

### 4.5 The validator
- Pure function: `validate(lineup, rules, context) -> [Finding]`. Each finding has a severity (violation / warning / info), the affected cells, and plain-English text written to be fed straight back to the AI in the revise step.
- It runs on every edit, live. Grid cells show violations inline, e.g. a red corner mark with a tooltip.
- It replaces v1's AI-reported Rules Compliance panel. AI-assessed (judgment-only) rules are shown separately and labelled as such.

---

## 5. AI assessments: the second core pillar

Assessments are a product in their own right (Player Insights, Team Insights) **and** the foundation lineups are built on. In v1 they were a stats-only side feature whose output never reached the lineup AI. In v2, the assessment is how the AI "understands each player's true strengths and optimal role."

### 5.1 Player assessment

Inputs, all assembled by code:
- Season-to-date stats (batting, fielding, pitching) with rates computed in code, plus the change since the last snapshot.
- Coach ratings (14 skills; nil = unknown), coach notes, and the position profile.
- Lineup history from the season ledger: where they've played, how often they've sat, and where they've batted.
- Sample size flags (PA, TC, IP).

Output (structured, cached per player):

| Field | Content |
|---|---|
| **Snapshot** | One or two sentences: who this player is right now |
| **Hitting profile** | Role archetype (table-setter, contact, gap/power, developing…), recommended batting zone (top / middle / bottom) with reason |
| **Defensive fit** | For each position: Strong / Solid / Developing / Not recommended, with reason. Compared against the coach's position profile, with disagreements flagged ("Stats and arm ratings suggest 3B; profile lists outfield only") |
| **Pitching / catching** | If applicable: readiness, workload notes, what the data says |
| **Strengths / weaknesses** | Each with a title, a description and **evidence references** (§5.3) |
| **Eye vs. data** | Where ratings and stats disagree, and how much to trust each given the sample size |
| **Development focus** | 1–3 concrete things to work on, with drill ideas |
| **Trend** | Improving / steady / slipping since the last assessment, when there's enough data |
| **Data confidence** | High / medium / low, with why (e.g., "low: 9 PAs, no ratings") |

### 5.2 Team assessment
- **Summary:** the team's identity in a sentence or two.
- **Strengths and weaknesses** with team-level evidence, aggregated in code (weighted, not averages of averages).
- **Lineup insights:** leadoff candidates, middle-of-order bats, the defensive core (up the middle), depth at P and C, and coverage gaps. v1 generated this and never showed it. In v2 it's shown, and it's also given to the Strategist.
- **Practice plan:** prioritized focus areas with drills, tied to the weaknesses. It prints as a one-page practice sheet.
- **What changed** since the last import.

### 5.3 Grounding: evidence the AI can't fake
- Code builds a **fact sheet** per player with stable IDs, e.g. `obp`, `bb_rate`, `sb_pct`, `rating.arm_strength`, `ledger.sits`, `note.3`.
- The AI cites fact IDs in its evidence references. It never writes the numbers itself.
- The UI renders the real values next to each claim ("Elite plate discipline — BB 12% · K 15%"), so a hallucinated number is impossible.
- **A code check rejects any assessment that cites a missing fact.** One retry, with the error fed back.
- **Optional Jev check** (TypeSafe's citation-check pattern): a Noul per claim asks "does this evidence support this claim?" Low-probability claims are flagged for review or regenerated (§8.4).

### 5.4 How assessments drive lineups
- The Strategist receives each available player's assessment summary, hitting profile and defensive fit, instead of raw stat dumps. Prompts are smaller and decisions better-reasoned.
- **The data-weighting knob** (stats ↔ coach eye) applies when the lineup is made. The assessment keeps both views and the eye-vs-data notes, so the Strategist can lean either way without re-assessing.
- Lineup reasons cite assessments ("Leadoff: table-setter, best OBP on the team"). A player's insight card shows how the AI has been using them, e.g. "Batted 1st–2nd in 5 of 6 games; mostly SS/2B."

### 5.5 Freshness, cost and control
- Re-assess a player only when their inputs change: new import, rating or note edits, or new games in the ledger. The inputs hash is stored with the assessment.
- Imports trigger batch re-assessment in the background with visible progress; the team assessment follows.
- Each assessment shows its age and whether its inputs have changed since ("2 new games since — Refresh").
- **The coach can push back.** "Disagree" on any line adds a coach note that feeds the next assessment, e.g. "He's not a 3B — throws from his ear." The coach stays the authority on the kid.
- **History:** past assessments are kept, so a player's season arc is visible. It's a nice end-of-season artifact for parents.

---

## 6. Feature improvements

### 6.1 Lineups that persist and have history
- Every change is saved: AI generations, coach edits, locks, and reorders.
- Each lineup has an undo stack (⌘Z works across AI runs) and named snapshots ("Pre-game," "After 3rd").
- A version list with a diff view ("4 cells changed").
- Each cell records its **provenance**: AI, coach, or locked. Locks carry over to regenerations.

### 6.2 Season fair-play ledger
- Track per-player season totals across games: innings in field, sits, innings by position, infield/outfield split, batting slots, PAs (from lineups, not GameChanger).
- A "Playing Time" view shows the team as a table with heat coloring and highlights who is owed what.
- Season debt ("Mia has sat 5 times, the team average is 3") is computed in code and handed to the AI as a fact, so its fairness decisions span the season, not just today. Seasonal templates in §4.3 make it a hard, verified rule if the league requires it.

### 6.3 Availability windows
- Each game marks players as available, unavailable, **arriving late (from inning k)**, or **leaving early (after inning k)**.
- Per-game restrictions use structured toggles ("No pitching today," "No catching — sore knee") plus free-text notes. Free text goes to the Rule Interpreter.

### 6.4 Pitching & catching tracker
- Record innings pitched (and optionally pitch count) per game.
- Rest-day rules are configurable as a league preset table (pitch count → required rest days). Ship an editable default modeled on common youth-league guidelines; don't hard-code any one league's numbers.
- Code computes who is eligible to pitch today and how many innings or pitches they have left. The AI receives that as a fact, and the validator enforces it.
- GameChanger pitching stats (already parsed in v1, then thrown away) feed pitcher fit.

### 6.5 Game-day mode
- A focused full-window view with the current inning, who's on the field, and who's on deck.
- Mid-game events (injury, kid leaves, pitcher struggling) apply in one click: lock the past innings, adjust availability, then have the AI re-plan the remaining innings with "change as little as needed." The validator reports exactly how many cells moved.
- Optional quick entry for score, pitches thrown, and game status. This fixes v1's fields with no UI.

### 6.6 Output
- A native print layout for dugout lineup cards: batting order with jersey numbers, a defensive grid, and an optional large-type position card per inning.
- Export to PDF and image, and copy as text so it can be pasted into a team chat.

### 6.7 GameChanger import, done right
- Parse by **header sections**, not hard-coded column indexes. v1 assumed fielding columns were past index 140, which is fragile.
- Keep batting, fielding, **and pitching**.
- Store each import as a dated **snapshot** of season-to-date totals. That gives trend lines over time, and re-imports never lose history.
- Matching works like v1 (jersey number, then name), but ambiguous or unmatched rows get a **manual mapping sheet**. No more "last name contains" false matches.
- Drag a CSV onto the window or the Dock icon to import.

### 6.8 Insights screens
- Player Insights and Team Insights are the UI for §5. They show grounded claims with rendered evidence, trends, data confidence, and the printable practice plan.

### 6.9 Learns from the coach's edits
- Every post-generation edit is recorded with its context: who moved where, in which inning, and under which priority.
- Patterns are distilled into **suggested coach preferences**, e.g. "You've moved Jake to SS in 4 of the last 5 lineups. Make SS his primary?" or "You always bat Mia leadoff in tournament games."
- **The coach approves each suggestion** before it becomes a note, a profile change or a rule. Nothing is learned silently.
- **Fewer edits over time means the AI is getting it right.** Edit counts per lineup are tracked as the app's own quality metric, shown privately in Settings.

### 6.10 The night-before flow (the hero path)
1. **Open the game.** The app has already carried over defaults (last rule set, priority and weighting for this game type) and flagged anything that changed: a new import, someone injured last game, a pitcher on rest.
2. **Confirm attendance.** One list with late/early toggles.
3. **Generate.** Batting order and defense in one pass; the coach can still stop after the batting order. Progress is shown live.
4. **Review.**
   - A short **game plan** summary: "Competitive lineup: strongest defense up the middle in innings 1–3, everyone gets 4+ field innings, Cole and Ava split pitching, Mia's owed infield time and gets 2B in the 4th–5th."
   - Verified compliance.
   - Per-player reasons on hover.
5. **Tweak, lock and regenerate with a sentence** if needed. Then print or share.

---

## 7. Data model (v2)

### 7.1 Simplifications
- **One position profile per player.** It replaces eligibility flags and the strengths list. For each of the 9 positions the player gets one of **Can't · Can · Good · Primary**. Eligibility is "not Can't"; the ranking falls out naturally. "OF" goes away (use LF/CF/RF; a UI shortcut can set all three).
- **Ratings are optional and sparse.**
  - Keep the 14 v1 dimensions, but nil means unknown, and prompts say so.
  - Consider collapsing to fewer, more meaningful dimensions after real use (open question Q6).
- **Coach notes actually get used.** They go to the Scout and Strategist, and optionally to Jev scoring (§8.4).

### 7.2 Entities (SwiftData)

```
Team            id, name, ageGroup, defaultInnings, leaguePresetRef?
Player          id, team, name, jersey, active, positionProfile[Position: Fit],
                ratings{dimension: Int?}, notes
PlayerAssessment player, inputsHash, model, createdAt, snapshot, hittingProfile,
                defensiveFit{position: level+reason}, pitchingCatching?, strengths[Claim],
                weaknesses[Claim], eyeVsData, developmentFocus, trend, dataConfidence,
                coachPushback[]                       (Scout output; cached, history kept)
Claim           title, text, evidence[FactID], jevSupport?
TeamAssessment  team, inputsHash, model, createdAt, summary, strengths[Claim],
                weaknesses[Claim], lineupInsights, practicePlan[], changesSinceLast
RuleSet         id, team, name, notes                     (was "rule group")
Rule            id, ruleSet, order, text, enabled,
                interpretation: Template? | judgmentOnly, interpretedBy(model, at), coachConfirmed
LeaguePreset    pitching rest table, max innings, etc.
Game            id, team, opponent, date, innings, status, ourScore, theirScore,
                ruleSet, priority(-2…+2), dataWeighting(0…1), scoutingNotes
GameAvailability game, player, status(available/out/late k/early k), restrictions, notes
Lineup          id, game, createdAt, label?, battingOrder[PlayerID],
                cells[inning][position] -> PlayerID, sits[inning][PlayerID],
                provenance[cell] (ai / ai-revised / app-adjusted / coach), locks[cell],
                settingsSnapshot, gamePlan, reasoning, findings, revisionRounds,
                coachEdits[] (cell, from, to, at)   → feeds §6.9
PitchingLog     game, player, innings, pitches?
StatsSnapshot   team, importedAt, sourceFile, rows[playerID: BattingLine, FieldingLine, PitchingLine]
AIRun           id, task, model, promptHash, tokensIn/Out, cost, latency, ok/error, rawResponse
```

- `AIRun` is a local log for debugging and cost visibility. It shows "this season: $0.43" in Settings.
- Back up by exporting the whole library as a single JSON document. Use the same format for a future iPad/iPhone import.
- **iCloud sync:** not in v2.0. If it comes later, use SwiftData + CloudKit when the iPad app arrives.

### 7.3 Migration from v1
- **None.** The Mac app is fully local. It never connects to Supabase, and v1 data is not imported. Marty starts with a fresh library: roster by hand or from a GameChanger CSV.
- Supabase, Stripe and Vercel are shut down once the Mac app is fully baked.

---

## 8. AI layer

### 8.1 Bring-your-own-key via OpenRouter
- On first run, onboarding asks for an OpenRouter API key. It's stored in **Keychain** and never written to disk elsewhere. "Test key" calls `GET /api/v1/models`.
- **Without a key** the coach can still manage the roster, import stats, build and edit lineups by hand (with live validation), track playing time, and print. Lineup generation, which is the heart of the app, needs a key, so onboarding treats adding one as step 1.
- One HTTP client for `POST /api/v1/chat/completions`, using `response_format: json_schema` (structured outputs) wherever the chosen model supports it.
  - Fallback: JSON mode plus schema validation plus one repair retry.
  - Every AI response is decoded into Swift `Codable` types and validated before use.

### 8.2 Model picker per task (the "big win")
AI work splits into named **tasks**. Each has a shipped default model and a user override:

| Task | What it does | Default class | Frequency |
|---|---|---|---|
| Lineup Strategist | **The core.** Decides batting order (phase 1) and defense (phase 2) with reasons, and revises from validator findings | Strongest reasoning model | Per generation / regeneration |
| Scout | **Core.** Player and team assessments (§5): grounded claims with fact citations, positional fit, batting role, eye-vs-data, practice plan | Strongest reasoning model | When a player's inputs change; per import |
| Rule Interpreter | Plain-language rule → typed template + params, or judgment-only | Strong model (after the Jev first pass) | Once per rule edit |
| Decisions | Typed judgments: rule → template, feedback → intent, optional soft-rule checks (§8.4) | `~typesafe/jev-latest` | Per rule edit / feedback |

- **Picker UI:** fetch `/api/v1/models`, filter to models whose `supported_parameters` include `structured_outputs` / `response_format`, and show price per million tokens and context size. Include a "Recommended" badge and a "Reset to default."
- **Default slugs** are pinned in a bundled `models.json` and set at implementation time: a current Claude Sonnet-class model for reasoning and a Haiku-class model for fast tasks.
  - That file can update through Sparkle releases, so the code doesn't hard-code slugs.
- **Evals make swapping safe.** A golden test set (§10) runs against any model. The picker can show results for models we've tested, e.g. "valid on first try 17/20, avg 0.3 revisions, $0.04/lineup."

### 8.3 Prompt design changes vs v1
- **The Strategist still produces the whole lineup.** It gets a cleaner, richer brief:
  - The Scout's cached player assessments, instead of raw dumps of every number.
  - Computed facts: season debt, pitching availability, availability windows.
  - Rules as written, plus their typed form.
  - Locks.
  - Priority and weighting as explicit directives.
- **Structured outputs.** The JSON schema for the batting order and grid is enforced by the API where the model supports it.
- **A game plan first.** The Strategist states its plan in 2–3 sentences (priorities, pitching plan, who's owed what) before the assignments. The coach reads that summary first.
- **Reasons per decision.** A short reason per batting slot and per non-obvious assignment, plus a list of "low-preference" cells the safety net may touch first.
- **Keep math out of prompts.** Code computes rates, counts and season debt and passes the results as facts.
- **Send unknowns as unknown.** No more defaulting to 3.
- **IDs are short and local** (P1…P15). They map back in code, and unknown IDs are rejected.
- **Use prompt caching** where supported, for the stable system prompt, roster and assessments, which repeat across phase 1, phase 2 and revisions.

### 8.4 Jev (TypeSafe), and where it actually fits

**How Jev is exposed (verified Oct 2, 2026). One OpenRouter key covers everything; there is no TypeSafe account or second key.**
- **Jev itself** (typed Choice / Score / Noul answers with calibrated probabilities) is served by OpenRouter as `typesafe/jev-1.13`, or the alias `~typesafe/jev-latest`. It's billed to the user's OpenRouter account at about $0.042 per million input tokens, output is free, and the context limit is 32k tokens.
- **Two endpoints:**
  - `POST https://openrouter.ai/api/alpha/decisions` (the "Decisions API"): plain HTTP and OpenRouter SDKs. Responses include `usage.cost`. **Use this one from Swift.**
    - It's an `alpha` path, so keep the client isolated behind a protocol in `AIKit` and expect changes.
  - `POST https://openrouter.ai/api/v1/systemone`: TypeSafe-SDK compatible, which is irrelevant for Swift.
- Jev doesn't appear in `GET /api/v1/models`. The picker needs a separate, bundled "decision model" entry rather than discovering it.
- **`typesafe/jev-router`** is a different thing: an LLM router that uses Jev to pick a model per request. It can simply be one of the generative picker options.
- Errors: `429`/`5xx` and an in-flight-budget `402` (`limit_source: openrouter_in_flight_budget`) are retryable. Any other `402` means the user is out of credits; show that clearly.
- Jev's documented weak spots are numbers, counting, dates, multi-hop indirection, and large irrelevant state. That fits "code does math, model does judgment" perfectly.

**Where Jev fits** (a fifth task, "Decisions," with its own picker entry defaulting to `~typesafe/jev-latest`):

| Use | Primitive | Notes |
|---|---|---|
| Rule → template routing | **Choice** over the template catalog (+ "none / soft") | Calibrated confidence decides whether to auto-accept, ask the coach, or escalate to the LLM Interpreter. Numeric params: extract candidate numbers with regex, then a Choice selects among them ("select, don't generate"). |
| Feedback routing | **Choice** over edit intents (move player, keep player at, avoid, swap, pitching change…) + Choice for player/position | "Move Jake to outfield" becomes a typed, checkable instruction (Jake ∈ {LF, CF, RF}) that the validator can verify the Strategist honored. The intent and constraints go to the Strategist as a precise brief. Low confidence passes the raw text instead. |
| Coach notes → features | **Score** per dimension (e.g., "readiness to catch," "composure under pressure") | Turns free-text notes into compact, comparable signals for the Scout and Strategist. Scores are reusable until the notes change. |
| Judgment-only rule checks | **Noul** per judgment-only rule against a compact text rendering of the lineup | An independent second opinion on the Strategist's self-assessment, e.g. "Does inning 3 keep the twins on opposite sides of the field?" Shows probability, not a verdict. |

**Recommendation:** use Jev as the **first pass** for rule routing and feedback routing in M3, alongside the LLM tasks. It's the same key, it costs fractions of a cent, and the answers are typed.

The flow is a cascade:
1. Jev Choice.
2. If confidence is at or above a threshold tuned on the eval set, use the typed result. Otherwise escalate to the LLM Interpreter, or pass the raw feedback text to the Strategist.

Most rule interpretations then resolve instantly and cheaply. Feedback becomes a checkable instruction for the Strategist, so the validator can confirm the AI actually did what the coach asked. Jev never decides the lineup; it sharpens the instructions and checks the result. Coach-notes Scores and judgment-only rule checks follow in M6 once the eval set shows they help.

---

## 9. Mac app technical direction

| Area | Decision |
|---|---|
| UI | SwiftUI, AppKit where needed (grid keyboard handling, printing) |
| Minimum OS | **macOS 26** (decided). |
| Language | Swift 6, strict concurrency |
| Persistence | SwiftData (local store). JSON backup/export. |
| Secrets | Keychain (one OpenRouter key covers LLMs and Jev) |
| Networking | `URLSession` + `Codable`; no SDK dependencies |
| Project | XcodeGen (`project.yml`), as in the Situations app |
| Updates | Sparkle 2 per `baseball-situational-simulator/docs/mac-auto-update-playbook.md`: ad-hoc signing, EdDSA, GitHub Releases, `release-mac.yml`, public repo (or public releases repo) |
| Distribution | Free GitHub Release zip. No App Store, no paid Apple account for now. |
| Tests | Swift Testing. The validator/feasibility/repair/parser package must be heavily tested. CI runs tests before release (already part of the playbook workflow). |

### 9.1 Module layout (sets up iPad/iPhone later)

```
PeanutManager/            (app target, macOS)
  App/ Views/ Commands/ Printing/ Updater/
Packages/
  LineupKit/              pure Swift, no UI, no network, platform-agnostic
    Model/                Position, Fit, Constraint templates, Lineup
    Validator/            invariants + templates → findings (AI-readable text)
    Feasibility/          "any valid lineup?" + minimal conflict explanation
    Repair/               minimal-change safety net (never generates from scratch)
    Facts/                computed stats, season ledger, pitching availability
    Import/               GameChanger CSV parser + matcher
  AIKit/                  OpenRouter chat client, Jev Decisions client (behind a protocol;
                          alpha endpoint), task definitions, schemas, model catalog
  Store/                  SwiftData models, JSON backup/export
```

`LineupKit` is pure and portable. An iPad/iPhone app reuses it unchanged, and a tiny CLI (`lineupkit validate lineup.json`) helps agents and tests.

---

## 10. Quality: tests and evals

- **Validator / feasibility / repair unit tests:** every template, every invariant, infeasibility explanations, and minimal-change repair. Performance target: < 100 ms for 15 players × 9 innings.
- **Property tests:** random rosters, rules, locks and deliberately broken lineups, then assert the repair output always passes the validator and preserves every valid cell it can.
- **Parser fixtures:** real GameChanger exports (anonymized) in `Tests/Fixtures`, covering odd cases (missing sections, "-" values, duplicate jerseys).
- **AI golden set (the most important eval):**
  - **Baseline comparison.** Fixture games are run through v1's ported prompts and through each candidate improvement. A change ships only if it beats or matches v1.
  - **Lineup scenarios.** Real rosters, rules, locks, availability and season history. The headline question: *would Marty print this lineup as-is?* Measure for the Lineup Strategist with any model:
    - Valid on first try.
    - Revisions needed.
    - Safety-net usage.
    - Cost and latency.
    - A coach-judged quality rubric (Marty grades a sample; a strong model can pre-grade).
  - **Assessments.** Fixture players with known profiles, e.g. "fast, patient, no power," "great arm, poor hands," and "stats/eye conflict, small sample." Measure:
    - Citation validity (automated; must be 100%).
    - Jev support scores.
    - Data-confidence calibration (low-sample players must be flagged).
    - Batting-role and position recommendations vs. expected.
    - A coach-graded usefulness rubric.
  - **Rules.** 30–50 real-world rules (v1's shipped examples plus Marty's league rules) with the expected template and params.
  - **Feedback.** Feedback strings with expected outcomes.
  - Run with `swift test --filter Evals` against a chosen model. Not in CI by default, because it costs money.
  - Results feed the picker's "tested" badges.

---

## 11. Design direction (placeholder)

Goal: feels like Apple or Cultured Code (Things 3) built it. Detailed design is a later pass. Early guardrails:
- Sidebar → content → inspector. The sidebar holds the team switcher and sections (Games, Roster, Rules, Playing Time, Stats). The inspector shows player detail or the selected cell's "why."
- The lineup grid is the hero. It's fully keyboard-driven: arrow keys to move; type `S` `S` or `6` to assign SS; Space toggles a lock; ⌘L locks the inning; ⌘↩ fills the rest.
- Restraint: system fonts, one accent color, generous spacing, few borders, and native controls, menus and shortcuts throughout. Calm empty states; no dashboards full of cards.
- AI is ambient, not a chatbot. It shows up as a "Fill" button, an "Understood as…" chip, and a one-line reason on hover.

---

## 12. Milestones

| # | Milestone | Outcome |
|---|---|---|
| M0 | Scaffold *(done except Sparkle/CI)* | XcodeGen project, `LineupKit` package, CI test + Sparkle release pipeline proven end to end (playbook steps 1–7). |
| M1 | Core + v1 AI port *(done; eval harness not built)* | SwiftData model, validator + fact sheets, OpenRouter BYOK client. **v1's prompts ported as-is** as the baseline, wrapped in the verify → revise loop, and a CLI/eval harness over fixture teams. Success: v1-quality lineups with zero rule violations. |
| M2 | The night-before path *(done; printing untested)* | The UX milestone and **first usable build**. Roster, games, attendance, one-click generate, the keyboard-driven grid (locks, real swaps, undo, history, persisted edits), regenerate with a sentence, game plan + verified compliance, print/share. Polish until it's faster than a spreadsheet. |
| M3 | Insights *(not started; GameChanger import v2 done)* | Player and Team Insights screens; Scout assessment upgrades (ratings back in, grounded citations, eye-vs-data, trends, coach pushback), eval-gated against v1's analysis; GameChanger import v2. |
| M4 | Season & game day *(availability windows done; rest not started)* | Fair-play ledger, pitching tracker and rest presets, availability windows, game-day mode, mid-game AI re-plan. |
| M5 | Smarter rules & learning *(model picker done; rest not started)* | Rule Interpreter + Jev cascade with "Understood as…", learn-from-edits suggestions, per-task model picker with tested badges, Jev claim checks. |
| M6 | Beyond | iPad/iPhone exploration (reusing `LineupKit`); retire the web app and Supabase. |

The first usable build arrives after M2. AI quality starts at v1's B from day one, because M1 ports the proven prompts. M3 and M5 push it toward an A, and every change is gated on beating v1 in the replay evals.

## 13. Open questions

- **Q1. App name.** *Resolved:* Peanut Manager, `com.martyvasquez.PeanutManager`.
- **Q2. Minimum macOS.** *Resolved:* macOS 26.
- **Q3. Repo visibility.** *Resolved:* public (github.com/martyvasquez/peanut-manager-mac-app), so Sparkle can use its releases directly.
- **Q4. Field formats.** The pitch says baseball **and** softball, so sport becomes a team setting. Do you also need 10-fielder formats (4 outfielders, common in younger softball and coach-pitch)? Supporting a configurable field early is cheap; adding it later is not.
- **Q5. League presets.** *Partly answered:* LL Majors (11–12). Still need the real league rules as written to seed rule checks and evals.
- **Q6. Ratings.** Keep all 14, or collapse to about 6 after we see which ones actually move the AI's decisions (measurable with evals)?
- **Q7. Multi-team.** *Resolved:* kept; team menu has New / Edit / Delete.
- **Q8. Jev cascade threshold UX.** When Jev is unsure, should the app silently escalate to the LLM (costs a few cents), or ask the coach to pick among Jev's top 2–3 interpretations (free, one click)? Proposed: ask the coach for rule interpretation, escalate silently for feedback.
- **Q9. Eval fixtures.** *Resolved direction:* no v1 import; hand-built fixtures plus Marty's real Trojans data (export once backup exists).

---

## Appendix A. v1 → v2 mapping

| v1 | v2 |
|---|---|
| Supabase tables + RLS | SwiftData local store |
| Auth / billing / marketing | Removed |
| Rule groups + plain-text rules | Rule sets + interpreted typed constraints + soft guidance |
| `generate-lineup` (LLM builds grid, trusted blindly) | LLM still builds the grid, now with better facts, cached Scout assessments, code validation and a self-revision loop |
| AI `rules_check` | Validator findings (code) for checkable rules; AI-assessed label for judgment-only rules |
| Post-processing repair hacks | AI revises from findings; disclosed minimal-change safety net as last resort |
| Eligibility flags + position strengths | Position profile (Can't/Can/Good/Primary) |
| Ratings null → 3 | Ratings nil → unknown |
| Stats season view (cumulative rows dated Jan 1) | Dated StatsSnapshots incl. pitching |
| Stats-only analysis, never used for lineups | Grounded Scout assessments (stats + ratings + notes + history) that drive lineups |
| Lineup versions (never shown) | Persistent lineups with undo, snapshots, diff, provenance |
| Print window | Native print + PDF/image/text export |
| Claude-only, server key | OpenRouter BYOK (LLMs + Jev on one key), per-task model picker |

## Appendix B. v1 blind spots: where bad output could slip through

Verified against v1 code on Oct 2, 2026. Each item is a way v1 could produce a wrong lineup or a wrong insight **without the coach being told**. Each is a required test case in v2.

### B.1 Rules can be ignored silently

| # | Blind spot | Where (v1) | Bad outcome | v2 fix |
|---|---|---|---|---|
| 1 | Compliance is self-reported. The "Rules Compliance" panel renders the AI's own `rules_check` | `generate-lineup/route.ts` saves `response.rules_check` as-is; `rule-compliance.tsx` displays it | AI breaks a rule and marks it ✅ anyway. The coach sees green. | Validator computes compliance (§4.5); the AI's self-check is never shown as fact |
| 2 | Locks are only a prompt instruction | `locked_positions` goes only into the prompt; nothing checks them in the response | AI moves a locked player and the coach's decision is silently overwritten | Validator invariant + revise loop; locked cells copied back from source |
| 3 | No check that the grid matches the roster | Defense post-processing only fills empty slots | Unavailable/inactive players, unknown IDs, or a player missing from both field and bench go unnoticed | Invariants: available players only, each exactly once per inning |
| 4 | Duplicate player in one inning isn't detected | Same | One kid at two positions, another kid never plays | Invariant: one position per player per inning |
| 5 | Wrong number of innings isn't detected | No check on `defense.length` | Missing innings render blank, extra ones silently appear | Invariant: inning count matches game |
| 6 | Batting order isn't checked for completeness | Batting post-processing only dedupes and renumbers | A player left out of the order, violating "everyone bats" with no warning | Invariant: every available player bats exactly once (when continuous batting) |
| 7 | Eligibility isn't enforced | Only a prompt instruction | Non-pitcher at P, non-catcher at C | Invariant: position profile ≠ Can't |
| 8 | Playing-time rules are prompt-only | Nothing counts innings or sits | "Everyone plays 3+ innings" quietly broken | Typed templates checked by validator (§4.3) |
| 9 | Rule group "none" sends *all* rules | Rules aren't filtered when `rule_group_id` is null | Tournament and practice rules mixed together and contradicting each other | Explicit rule set per game, always |

### B.2 The "fixes" create new errors

| # | Blind spot | Where (v1) | Bad outcome | v2 fix |
|---|---|---|---|---|
| 10 | The empty-position filler falls back to `batting_order[0]` | Defense post-processing | The leadoff hitter is placed in two positions at once | Removed; AI revises from findings; safety net is validated |
| 11 | The pitcher re-entry swap ignores eligibility and locks | Pitcher post-processing swaps with the first non-pulled fielder | Ineligible kid pitches, or a locked cell is overwritten, and the coach isn't told | Same as #10; every change after the AI is disclosed |
| 12 | Repairs aren't re-validated or disclosed | — | Coach can't tell which cells the AI chose and which code changed | Cell provenance: ai / ai-revised / app-adjusted / coach |

### B.3 The AI decides on bad or missing data

| # | Blind spot | Where (v1) | Bad outcome | v2 fix |
|---|---|---|---|---|
| 13 | Unrated = 3 | `prompt-builder.ts` uses `?? 3` everywhere | An unknown kid looks average and may be put at SS or leadoff on no evidence | nil = unknown, stated in the prompt with data confidence |
| 14 | Team analysis reads columns the view doesn't have | `stats/analyze` reads `bb`, `so`, `hr`, `gp`, `ops`; the view lacks them | Team K% and BB% reported as **0%**, so the insights are confidently wrong | Stats computed in code from snapshots; fact-cited claims (§5.3) |
| 15 | Coach notes never reach the lineup AI | `players.notes` not in either prompt | "Afraid of fly balls" kid put in CF | Notes go to Scout + Strategist |
| 16 | Pitching stats discarded; pitching availability always 0 | Parser drops them; `pitching_innings_available` has no UI | Pitching decisions made without data | Pitching snapshots + availability facts |
| 17 | Ratings season not filtered | Last row wins | A previous season's ratings can be used | Single current rating set per player |
| 18 | Eligibility flags vs. strengths not reconciled | Two sources of truth | Mixed signals to the AI ("P is his #1" but `can_pitch = false`) | One position profile |
| 19 | Fuzzy GameChanger name matching | `matchPlayers`: last-name-contains | One kid's stats attached to another kid, and every downstream insight and lineup inherits it | Exact match or manual mapping sheet |
| 20 | Fragile CSV column indexes | Column > 140 assumed to be fielding | A GameChanger export format change silently shifts stats into wrong fields | Parse by header sections; fail loudly |

### B.4 Coach decisions get lost

| # | Blind spot | Where (v1) | Bad outcome | v2 fix |
|---|---|---|---|---|
| 21 | Edits, locks and reorders are never saved | No client write to `lineups` other than delete | Coach fixes the lineup at night, reloads at the field, and gets the AI version back | Persist every change; undo/history |
| 22 | "Swap" clears the other player and leaves a stale lock | `handleCellChange` | A player falls off the field; the AI is told two players are locked to one spot | Real swap; locks move with it |
| 23 | Innings selector is display-only | Server uses `game.innings` | Coach sets 4 innings; AI plans 6; fairness math is wrong for the real game | Innings is part of the game record and the prompt |
| 24 | Cancel doesn't cancel | Only the client fetch aborts | A "cancelled" generation still overwrites the lineup | Local app: cancellation owned by the task; nothing written until validated |
| 25 | Unparsed AI JSON / no schema validation | `parseJsonResponse` = `JSON.parse` | Malformed or partial output gets saved or crashes the flow | Structured outputs + `Codable` decoding + revise |
