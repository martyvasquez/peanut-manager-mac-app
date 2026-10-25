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

`docs/screenshots/light` and `docs/screenshots/dark`: five each at 2880 × 1800 (positions, batting order, the field, Insights, Defense), from the sample team with its recorded AI results. Upload the **light** set (Marty's pick, Oct 23), in order. Retake with `-PMStore Shots -PMSeedSample YES -PMFakeAI YES -PMFakeClaudeKey YES -PMWindowSize 1440x900 -PMAppearance light|dark` plus `-PMStep batting`, `-PMDiamond 3`, or `-PMSection team -teamTab summary|defense`.

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

Untick "Sign-in required". Attachment: `PeanutManager/Resources/sample-team.csv` (made-up players; never a real team export), zipped if the upload refuses a .csv. Contact: Marty Vasquez, apps@bytelaunch.com. Notes (the review key goes in App Store Connect only, never in this repo; make one per review in its own Anthropic workspace with a spend limit and a 30-day expiry, and delete it after approval):

```
Peanut Manager works fully without signing in. On first launch, click "Try a Sample" to load a sample team with season stats, rules and a game.

To try lineups: open the game, drag players into the batting order (or "Add All"), click Positions, and click spots on the grid to assign positions.

To try importing stats: the attached sample-team.zip (unzip it for sample-team.csv) is a GameChanger season stats export with made-up players. Create a new team (click the team name at the top of the sidebar → New Team…, or "New Team" on first launch), open Roster, click the Import from GameChanger button in the toolbar (or drop the file on the roster), and review the player matches. Players are created from the file. Peanut Manager isn't affiliated with GameChanger; coaches export the CSV from their own GameChanger account.

To see the AI features without an account: the sample team comes with a lineup and scouting reports made earlier by Claude Sonnet 5.5, labeled "Sample · Claude Sonnet 5.5". Open the game for the AI lineup and its plan; Stats & Insights for the team summary and practice plan; Roster → any player → Scouting Report.

To try live AI: open Peanut Manager → Settings (⌘,) → Claude → paste this API key and click Add:
PASTE-YOUR-REVIEW-KEY-HERE
This key is for App Review only and has a spending limit. Then, in the game, click Remake… (or Make Batting Order / Fill Positions on a new game). The first AI action asks permission to share the team with Anthropic; click Allow.

Requests go directly from the device to OpenAI or Anthropic; the app asks permission, naming the company, before the first one. There is no server of our own and no account to create. Data is stored on the device and synced through the user's private iCloud account (CloudKit), with player information end-to-end encrypted.
```

**App Sandbox Information** (optional; explains the entitlements):

| Entitlement | Reason |
|---|---|
| Outgoing Connections (Client) | Sends AI requests to OpenAI or Anthropic when the user chooses to use AI. |
| Incoming Connections (Server) | Sign in with ChatGPT returns to a temporary listener on 127.0.0.1 (OAuth loopback redirect) during sign-in only. No other incoming connections. |
| User Selected File (Read Only) | Imports a season stats CSV file the user picks. |
| Printing | Prints the lineup card. |

**Version Release:** Manually release this version.


---

# iPhone 1.0 (same app record, universal purchase)

The iPhone app is the same App Store product as the Mac app (bundle ID `com.martyvasquez.PeanutManager`), so App Information (name, subtitle, category, privacy policy), App Privacy and the age rating are shared. In App Store Connect: the app → **Add Platform → iOS**, then fill the iOS 1.0 version page below. The iPhone doesn't have Insights or Scouting Reports yet (after 1.0), so its description leaves them out.

## Version 1.0 (iOS)

**Promotional Text (170)** *(144, same as the Mac)*

> Make the night-before lineup in minutes: drag in the batting order, lock the spots you care about, and let AI fill the rest with every rule met.

**Keywords (100)** *(95, same as the Mac)*

> baseball,softball,lineup,batting order,little league,coach,youth,positions,rotation,depth chart

**Support URL:** https://martyvasquez.github.io/peanut-manager-mac-app/support

**Copyright:** 2026 Marty Vasquez

**Description (4000)**

> Lineups for youth baseball and softball, made the night before in minutes, with every rule met.
>
> THE WHOLE GAME ON ONE SCREEN
> Every player and every inning fit on your iPhone at once. Tap a spot to pick a position; tap two spots in an inning to swap them. A taken spot swaps, so two players can never share one. Long games swipe sideways, or pinch to see every inning.
>
> BATTING ORDER
> Tap players in order, drag to reorder, or start from a previous game's lineup.
>
> YOUR RULES, CHECKED
> Write your league's rules in plain words, and add a check to the ones that can be counted: pitching limits, innings in the infield, times sitting. Every lineup shows whether it follows them, or exactly what doesn't.
>
> AI, IF YOU WANT IT
> Place the spots you care about and let AI fill the rest. It weighs stats, your ratings and notes, and the matchup, and never moves a spot you placed. Use your own ChatGPT plan or a Claude API key. Nothing is sent until you allow it.
>
> GAMECHANGER STATS
> Import your season stats from a GameChanger CSV export. Tap any player for their season at the plate and in the field, and where they rank on the team.
>
> PRINT OR SEND
> Print a clean lineup card for the dugout, or send it to your team as a PDF or as text.
>
> PRIVATE BY DESIGN
> No accounts, no ads, no tracking. Your team lives on your devices and in your own iCloud, with everything about your players end-to-end encrypted, and stays in sync with Peanut Manager on your Mac.
>
> Peanut Manager is free and open source. It isn't affiliated with GameChanger, OpenAI or Anthropic.

## Screenshots (iPhone 6.9")

`docs/screenshots/iphone`: five at 1320 × 2868 (iPhone 17 Pro Max), light, from the sample team: 1 the filled grid ("Follows your rules"), 2 picking a position, 3 two placed spots and Fill the Rest, 4 the batting order, 5 a player's card. Upload in order; App Store Connect scales them for smaller iPhones. Retake on the iPhone 17 Pro Max simulator with `-PMStore Shot1 -PMSeedSample YES -PMFakeAI YES -PMFakeClaudeKey YES -PMOpenGame YES` plus `-PMStep positions`, `-PMSelect 3:6`, `-PMClear positions -PMLockDemo YES` (store Shot2), `-PMStep batting`, or `-PMCard Hayden`, after `xcrun simctl status_bar <device> override --time 9:41 --batteryState charged --batteryLevel 100`.

## App Review notes (iOS)

Same attachment (the sample CSV, zipped) and the same rules for the review key (App Store Connect only, never in this repo). Notes:

```
Peanut Manager works fully without signing in. On first launch, tap "Try a Sample" to load a sample team with season stats, rules and a game.

To try lineups: open the game. On Batting, tap players in order (or drag to reorder), then tap Positions. Tap any spot on the grid to pick a position; with a spot picked, tap another spot in the same inning to swap them. Share (top right) prints the lineup card or sends it.

To try importing stats: save the attached sample-team.csv (unzip sample-team.zip) to the Files app. Make a new team (tap the team name at the top of Games → New Team…), open the Roster tab, tap the Import button (arrow into a tray), pick the file, and review the matches. Players are created from the file. Peanut Manager isn't affiliated with GameChanger; coaches export the CSV from their own GameChanger account.

To try live AI: tap the gear on the Games tab → Claude → paste this API key and tap Add:
PASTE-YOUR-REVIEW-KEY-HERE
This key is for App Review only and has a spending limit. Then open the game → Positions → ⋯ → Clear Positions, tap a couple of spots to place players, and tap Fill the Rest. The first AI action asks permission to share the team with Anthropic; tap Allow. While the AI works the screen stays on.

Requests go directly from the device to OpenAI or Anthropic; the app asks permission, naming the company, before the first one. There is no server of our own and no account to create. Data is stored on the device and synced through the user's private iCloud account (CloudKit), with player information end-to-end encrypted.
```

**Version Release:** Manually release this version.
