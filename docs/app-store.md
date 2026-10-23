# App Store Connect: what to enter

Drafts for Peanut Manager 1.0 (macOS, Apple ID 6826413372). Character counts are checked against Apple's limits.

## App Information

| Field | Value |
|---|---|
| Name | Peanut Manager |
| Subtitle (30) | Youth baseball lineups, fast *(28)* |
| Category | Sports |
| Privacy Policy URL | https://martyvasquez.github.io/peanut-manager-mac-app/privacy *(after GitHub Pages is on)* |

## Version 1.0

**Promotional Text (170)** *(144)*

> Make the night-before lineup in minutes: drag in the batting order, lock the spots you care about, and let AI fill the rest with every rule met.

**Keywords (100)** *(95; commas, no spaces)*

> baseball,softball,lineup,batting order,little league,coach,youth,positions,rotation,depth chart

**Support URL:** https://martyvasquez.github.io/peanut-manager-mac-app/support

**Marketing URL:** leave empty.

**Copyright:** 2026 Marty Vasquez

**Description (4000)**

> Lineups for youth baseball and softball, made the night before in minutes, with every rule met.
>
> BATTING ORDER
> Drag players into the order, or add everyone at once. With season stats, each player shows where they rank on the team in average, on-base and slugging, so the order makes itself obvious.
>
> POSITIONS
> Pick positions inning by inning. A taken spot swaps, so two players can never share one. Copy an inning, copy a previous game's lineup, or click an inning to see it on the field.
>
> YOUR RULES, CHECKED
> Write your league's rules in plain words, and add a check to the ones that can be counted: pitching limits, innings in the infield, times sitting. Every lineup shows whether it follows them, or exactly what doesn't.
>
> AI, IF YOU WANT IT
> Lock the spots you care about and let AI fill the rest. It weighs stats, your ratings and notes, and the matchup, explains every choice, and never moves a spot you locked. Use your own ChatGPT plan or a Claude API key. Nothing is sent until you allow it.
>
> SCOUTING REPORTS
> Import your season stats from a GameChanger CSV export and get a scouting report for every player and the team: strengths, what to work on, batting roles and best positions, each backed by the numbers.
>
> PRINT
> Print a clean lineup card for the dugout.
>
> PRIVATE BY DESIGN
> No accounts, no ads, no tracking. Your team lives on your devices and in your own iCloud, with everything about your players end-to-end encrypted.
>
> Peanut Manager is free and open source. It isn't affiliated with GameChanger, OpenAI or Anthropic.

**What's New:** not shown for 1.0.

## Screenshots

`docs/screenshots/light` and `docs/screenshots/dark`: five each at 2880 × 1800 (positions, batting order, the field, Insights, Defense), from the sample team with its recorded AI results. Upload one set, in order. Retake with `-PMStore Shots -PMSeedSample YES -PMFakeAI YES -PMFakeClaudeKey YES -PMWindowSize 1440x900 -PMAppearance light|dark` plus `-PMStep batting`, `-PMDiamond 3`, or `-PMSection team -teamTab summary|defense`.

## App Privacy

Answer "Yes, we collect data" (the AI features send team information to the AI company the coach picks), then:

| Question | Answer |
|---|---|
| Data type | **User Content → Other User Content** (players' names, stats, ratings, notes, rules, game notes) |
| Used for | **App Functionality** only |
| Linked to the user's identity? | **Yes**: it's sent under the coach's own ChatGPT or Anthropic account |
| Used for tracking? | **No** |

Every other data type: not collected. No analytics, diagnostics, identifiers, contact info, location, purchases or usage data.

*Judgment call:* the data goes from the device straight to OpenAI or Anthropic and never reaches us, so "Data Not Collected" is arguable. Declaring it is the safer answer, and it matches what the consent screen tells coaches.

## Age Rating

Answer **None / No** to every content question (violence, profanity, mature themes, gambling, contests, and so on). If asked:

- Unrestricted web access: **No** (links open in the browser; there's no in-app web view).
- User-generated content shared with other users: **No**.
- AI-generated content or a chatbot: **Yes, AI suggestions** if the questionnaire asks; it writes lineup explanations and scouting reports for the coach, with no open-ended chat.

Expected rating: **4+**.

## App Review notes

> Peanut Manager works fully without signing in. On first launch, click "Try a Sample" to load a sample team with season stats, rules and a game.
>
> To try lineups: open the game, drag players into the batting order (or "Add All"), click Positions, and click spots on the grid to assign positions.
>
> To see the AI features without an account: the sample team comes with a lineup and scouting reports made earlier by Claude Sonnet 5.5, labeled "Sample · Claude Sonnet 5.5". Open the game for the AI lineup and its plan; Stats & Insights for the team summary and practice plan; Roster → any player → Scouting Report.
>
> Making new AI lineups needs the user's own ChatGPT account (Sign in with ChatGPT) or Anthropic API key, set in Settings. Requests go directly from the device to OpenAI or Anthropic; the app asks permission, naming the company, before the first one. There is no server of our own and no account to create.
