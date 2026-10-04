#if DEBUG
import Foundation

/// The eval's blind grading page: every lineup and assessment labeled A, B, C… with the model hidden
/// until Reveal. Grades stay in the page (localStorage); Copy Grades puts them on the clipboard.
enum GradePage {
    static func html(_ results: EvalResults) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = (try? encoder.encode(results)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return template.replacingOccurrences(of: "/*DATA*/", with: json.replacingOccurrences(of: "</", with: "<\\/"))
    }

    private static let template = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Model Eval</title>
    <style>
    :root {
      --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea;
      --accent: #0071e3; --good: #1f8a3b; --bad: #c9342b; --lock: #f2f2f7; --adj: #fff4d6;
    }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #000; --card: #1c1c1e; --text: #f5f5f7; --muted: #98989d; --line: #38383a;
              --accent: #0a84ff; --good: #30d158; --bad: #ff453a; --lock: #2c2c2e; --adj: #3a3220; }
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    main { max-width: 1100px; margin: 0 auto; padding: 32px 16px 120px; }
    h1 { font-size: 28px; margin: 0 0 4px; letter-spacing: -0.02em; }
    h2 { font-size: 20px; margin: 40px 0 4px; letter-spacing: -0.01em; }
    .sub { color: var(--muted); margin: 0 0 16px; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(480px, 1fr)); gap: 16px; }
    .card { background: var(--card); border-radius: 14px; padding: 18px; box-shadow: 0 1px 2px rgba(0,0,0,.06); min-width: 0; }
    .label { font-size: 22px; font-weight: 700; display: flex; align-items: baseline; gap: 10px; }
    .model { font-size: 13px; font-weight: 500; color: var(--accent); display: none; }
    .revealed .model, .revealed .metrics { display: block; }
    .metrics { display: none; color: var(--muted); font-size: 12px; margin-top: 4px; }
    table { border-collapse: collapse; width: 100%; font-size: 13px; }
    th, td { padding: 4px 6px; border-bottom: 1px solid var(--line); text-align: center; white-space: nowrap; }
    th:first-child, td:first-child, th:nth-child(2), td:nth-child(2) { text-align: left; }
    td.lock { background: var(--lock); font-weight: 600; }
    td.adj { background: var(--adj); }
    td.sit { color: var(--muted); }
    .scroll { overflow-x: auto; margin: 12px 0; }
    p.why { margin: 8px 0; }
    .muted { color: var(--muted); }
    .error { color: var(--bad); font-weight: 600; }
    .claims { margin: 8px 0; padding: 0; list-style: none; }
    .claims li { margin: 6px 0; }
    .chip { display: inline-block; font-size: 12px; padding: 1px 7px; margin: 0 3px 0 0; border-radius: 6px; background: var(--lock); color: var(--muted); }
    .head { font-weight: 600; margin-top: 12px; }
    .grade { border-top: 1px solid var(--line); margin-top: 14px; padding-top: 12px; display: grid; gap: 8px; }
    .row { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
    .row span { color: var(--muted); min-width: 120px; }
    button.opt { border: 1px solid var(--line); background: transparent; color: var(--text); border-radius: 8px; padding: 4px 11px; font: inherit; cursor: pointer; }
    button.opt.on { background: var(--accent); border-color: var(--accent); color: #fff; }
    textarea { width: 100%; min-height: 44px; border: 1px solid var(--line); border-radius: 8px; padding: 6px 8px; font: inherit; background: transparent; color: var(--text); }
    .bar { position: fixed; left: 0; right: 0; bottom: 0; background: color-mix(in srgb, var(--card) 88%, transparent); backdrop-filter: blur(20px);
           border-top: 1px solid var(--line); padding: 12px 16px; display: flex; gap: 10px; justify-content: center; align-items: center; }
    .bar button { border: 0; border-radius: 9px; padding: 8px 16px; font: inherit; font-weight: 600; cursor: pointer; background: var(--lock); color: var(--text); }
    .bar button.primary { background: var(--accent); color: #fff; }
    #summary { display: none; }
    .revealed #summary { display: block; }
    @media (max-width: 560px) { .cards { grid-template-columns: 1fr; } }
    </style>
    </head>
    <body>
    <main id="root"></main>
    <div class="bar">
      <span class="muted" id="progress"></span>
      <button id="copy">Copy Grades</button>
      <button class="primary" id="reveal">Reveal Models</button>
    </div>
    <script>
    const DATA = /*DATA*/;
    const POS = ["P", "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF"];
    const KEY = "pm-eval-grades";
    let grades = {};
    try { grades = JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) {}
    const saveGrades = () => { try { localStorage.setItem(KEY, JSON.stringify(grades)); } catch (e) {} progress(); };

    const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
    const players = Object.fromEntries(DATA.players.map(p => [p.id, p]));
    const short = id => { const p = players[id]; if (!p) return "?"; return esc(p.name) + (p.jersey ? ` <span class="muted">#${esc(p.jersey)}</span>` : ""); };
    const letter = i => String.fromCharCode(65 + i);
    const runFor = (subject, model) => DATA.runs.find(r => r.subject === subject && r.model === model);
    const secs = r => r.calls.reduce((a, c) => a + c.seconds, 0);
    const toks = r => r.calls.reduce((a, c) => a + c.inputTokens + c.outputTokens, 0);

    function gradeControls(key, questions) {
      const g = grades[key] || {};
      return `<div class="grade">` + questions.map(([field, title, options]) =>
        `<div class="row"><span>${title}</span>` + options.map(o =>
          `<button class="opt ${g[field] === o ? "on" : ""}" data-key="${key}" data-field="${field}" data-value="${o}">${o}</button>`).join("") + `</div>`
      ).join("") + `<textarea data-key="${key}" data-field="note" placeholder="What's wrong, if anything">${esc(g.note || "")}</textarea></div>`;
    }

    function lineupCard(run, label) {
      const L = run.lineup, c = DATA.lineupCase;
      let body = "";
      if (!L) body = `<p class="error">Failed: ${esc(run.error)}</p>`;
      else {
        const locks = new Set(c.locks.map(l => l.inning + "|" + l.player));
        const adj = new Set(L.adjusted.map(a => a.inning + "|" + a.player));
        const head = `<tr><th>#</th><th>Player</th>${L.innings.map((_, i) => `<th>${i + 1}</th>`).join("")}</tr>`;
        const rows = L.battingOrder.map((id, n) => {
          const cells = L.innings.map((inn, i) => {
            const pos = Object.keys(inn.positions).find(p => inn.positions[p] === id);
            const k = (i + 1) + "|" + id;
            const cls = locks.has(k) ? "lock" : adj.has(k) ? "adj" : pos ? "" : "sit";
            return `<td class="${cls}">${pos || "–"}</td>`;
          }).join("");
          return `<tr><td>${n + 1}</td><td>${short(id)}</td>${cells}</tr>`;
        }).join("");
        body = `<div class="scroll"><table>${head}${rows}</table></div>
          <p class="why"><b>Order.</b> ${esc(L.battingRationale)}</p>
          <p class="why"><b>Defense.</b> ${esc(L.defenseRationale)}</p>` +
          (L.warnings.length ? `<p class="why muted">${L.warnings.map(esc).join("<br>")}</p>` : "");
      }
      const m = L ? `First try ${L.battingRevisions + L.defenseRevisions === 0 ? "valid" : "invalid"} · revisions ${L.battingRevisions}+${L.defenseRevisions} · safety-net cells ${L.adjusted.length + (L.battingAdjusted ? 1 : 0)} · ` : "";
      return `<div class="card"><div class="label">${label}<span class="model">${esc(run.model)}</span></div>
        <div class="metrics">${m}${run.calls.length} calls · ${secs(run).toFixed(0)} s · ${toks(run).toLocaleString()} tokens</div>
        ${body}${gradeControls("lineup|" + run.model, [["print", "Print as-is?", ["Yes", "No"]], ["score", "Quality", ["1", "2", "3", "4", "5"]]])}</div>`;
    }

    function cite(a, ids) {
      const facts = Object.fromEntries(a.facts.facts.map(f => [f.id, f]));
      return (ids || []).map(id => facts[id] ? `<span class="chip">${esc(facts[id].label)} ${esc(facts[id].value)}</span>` : "").join("");
    }

    function playerCard(run, label) {
      const a = run.assessment;
      let body = "";
      if (!a) body = `<p class="error">Failed: ${esc(run.error)}</p>`;
      else {
        const claims = list => `<ul class="claims">${list.map(c => `<li><b>${esc(c.title)}.</b> ${esc(c.detail)} ${cite(a, c.evidence)}</li>`).join("")}</ul>`;
        body = `<p class="why">${esc(a.snapshot)}</p>
          <div class="head">Strengths</div>${claims(a.strengths)}
          <div class="head">Work on</div>${claims(a.weaknesses)}
          <div class="head">Batting</div><p class="why">${esc(a.battingRole)}${a.battingZone ? ", " + esc(a.battingZone) + " of the order" : ""}. ${esc(a.battingReason)}</p>
          <div class="head">Defense</div><ul class="claims">${a.defense.map(d => `<li><b>${esc(d.position)}</b> ${esc(d.fit.replace("_", " "))}. ${esc(d.reason)} ${cite(a, d.evidence)}</li>`).join("")}</ul>` +
          (a.eyeVsData ? `<div class="head">Eye vs. data</div><p class="why">${esc(a.eyeVsData)}</p>` : "") +
          `<div class="head">Develop</div><ul class="claims">${a.development.map(d => `<li><b>${esc(d.focus)}.</b> ${esc(d.drill)}</li>`).join("")}</ul>
          <p class="why muted">Confidence ${esc(a.confidence)}: ${esc(a.confidenceReason)}</p>`;
      }
      const m = run.reused ? "Reused from the library (no new call) · " : `${run.calls.length} call${run.calls.length === 1 ? "" : "s"}${run.calls.length > 1 ? " (retried for bad citations)" : ""} · ${secs(run).toFixed(0)} s · ${toks(run).toLocaleString()} tokens · `;
      return `<div class="card"><div class="label">${label}<span class="model">${esc(run.model)}</span></div>
        <div class="metrics">${m}</div>
        ${body}${gradeControls(run.subject + "|" + run.model, [["accurate", "Accurate?", ["Yes", "Mostly", "No"]], ["score", "Useful", ["1", "2", "3", "4", "5"]]])}</div>`;
    }

    function factsLine(subject) {
      const run = DATA.runs.find(r => r.subject === subject && r.assessment);
      if (!run) return "";
      const show = ["pa", "avg", "obp", "slg", "k_rate", "bb_rate", "fpct"];
      return run.assessment.facts.facts.filter(f => show.includes(f.id)).map(f => `<span class="chip">${esc(f.label)} ${esc(f.value)}</span>`).join("");
    }

    function summary() {
      const models = [...new Set(DATA.runs.map(r => r.model))];
      const rows = models.map(m => {
        const runs = DATA.runs.filter(r => r.model === m && !r.reused);
        const l = DATA.runs.find(r => r.kind === "lineup" && r.model === m);
        const lg = grades["lineup|" + m] || {};
        const pg = DATA.runs.filter(r => r.kind === "player" && r.model === m).map(r => grades[r.subject + "|" + r.model] || {});
        const scores = pg.map(g => +g.score).filter(Boolean);
        const pRuns = DATA.runs.filter(r => r.kind === "player" && r.model === m && !r.reused);
        return `<tr><td>${esc(m)}</td>
          <td>${l?.lineup ? (l.lineup.battingRevisions + l.lineup.defenseRevisions === 0 ? "Yes" : "No") : "–"}</td>
          <td>${l ? secs(l).toFixed(0) + " s" : "–"}</td>
          <td>${lg.print || "–"}</td><td>${lg.score || "–"}</td>
          <td>${pRuns.length ? (pRuns.reduce((a, r) => a + secs(r), 0) / pRuns.length).toFixed(0) + " s" : "–"}</td>
          <td>${scores.length ? (scores.reduce((a, b) => a + b, 0) / scores.length).toFixed(1) : "–"}</td>
          <td>${runs.reduce((a, r) => a + toks(r), 0).toLocaleString()}</td></tr>`;
      }).join("");
      return `<div class="card scroll"><table><tr><th>Model</th><th>Valid first try</th><th>Lineup time</th><th>Print?</th><th>Lineup</th><th>Avg scout time</th><th>Scout</th><th>Tokens</th></tr>${rows}</table></div>`;
    }

    function render() {
      const c = DATA.lineupCase;
      let html = `<h1>Model Eval</h1><p class="sub">Thinking: ${esc(DATA.effort)}. Grade everything, then reveal.</p><div id="summary"><h2>Results</h2>${summary()}</div>`;
      if (c) {
        const order = DATA.blind["lineup"] || [];
        html += `<h2>Lineup · ${esc(c.game)}</h2><p class="sub">${esc(c.ruleSet)} rules: ${c.rules.map(esc).join(" ")} · ${c.locks.length} locked spots (shaded) · highlighted cells were changed by the safety net</p><div class="cards">` +
          order.map((m, i) => runFor("lineup", m)).filter(Boolean).map((r, i) => lineupCard(r, letter(i))).join("") + `</div>`;
      }
      const subjects = Object.keys(DATA.blind).filter(s => s !== "lineup");
      for (const s of subjects) {
        const runs = DATA.blind[s].map(m => runFor(s, m)).filter(Boolean);
        if (!runs.length) continue;
        html += `<h2>${short(s)}</h2><p class="sub">${factsLine(s)}</p><div class="cards">` + runs.map((r, i) => playerCard(r, letter(i))).join("") + `</div>`;
      }
      document.getElementById("root").innerHTML = html;
      progress();
    }

    function progress() {
      const keys = DATA.runs.filter(r => r.lineup || r.assessment).map(r => r.kind === "lineup" ? "lineup|" + r.model : r.subject + "|" + r.model);
      const done = keys.filter(k => grades[k] && grades[k].score).length;
      document.getElementById("progress").textContent = `${done} of ${keys.length} graded`;
    }

    document.addEventListener("click", e => {
      const b = e.target.closest("button.opt");
      if (!b) return;
      const g = grades[b.dataset.key] = grades[b.dataset.key] || {};
      g[b.dataset.field] = g[b.dataset.field] === b.dataset.value ? undefined : b.dataset.value;
      b.parentElement.querySelectorAll("button.opt").forEach(x => x.classList.toggle("on", g[b.dataset.field] === x.dataset.value));
      saveGrades();
    });
    document.addEventListener("input", e => {
      const t = e.target;
      if (t.tagName !== "TEXTAREA") return;
      (grades[t.dataset.key] = grades[t.dataset.key] || {}).note = t.value;
      saveGrades();
    });
    document.getElementById("reveal").onclick = () => {
      document.body.classList.toggle("revealed");
      if (document.body.classList.contains("revealed")) document.getElementById("summary").innerHTML = `<h2>Results</h2>${summary()}`;
      document.getElementById("reveal").textContent = document.body.classList.contains("revealed") ? "Hide Models" : "Reveal Models";
    };
    document.getElementById("copy").onclick = async () => {
      const out = Object.entries(grades).map(([k, g]) => { const [subject, model] = k.split("|"); return { subject: subject === "lineup" ? "lineup" : (players[subject]?.name || subject), model, ...g }; });
      try { await navigator.clipboard.writeText(JSON.stringify(out, null, 2)); document.getElementById("copy").textContent = "Copied"; }
      catch (e) { document.getElementById("root").insertAdjacentHTML("afterbegin", `<textarea readonly>${esc(JSON.stringify(out))}</textarea>`); }
      setTimeout(() => document.getElementById("copy").textContent = "Copy Grades", 1500);
    };
    render();
    </script>
    </body>
    </html>
    """#
}
#endif
