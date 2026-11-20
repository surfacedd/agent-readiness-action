// Turns a `surfacedd-check agent-readiness check --json` report into the job summary, step outputs
// and log lines. Node built-ins only (runs on every GitHub-hosted runner).
//   node summary.mjs <report.json> <exit code>
// Env: GITHUB_STEP_SUMMARY, GITHUB_OUTPUT (files; skipped when unset), SUMMARY=false to skip the summary.
import { appendFileSync, readFileSync } from "node:fs";

const [file, codeArg = "0"] = process.argv.slice(2);
const code = Number.parseInt(codeArg, 10) || 0;

let env;
try {
  env = JSON.parse(readFileSync(file, "utf8"));
} catch {
  console.log(`::error::surfacedd-check did not write a report (exit ${code}).`);
  process.exit(0);
}

const append = (path, text) => {
  if (path) appendFileSync(path, text);
};
const output = (k, v) => append(process.env.GITHUB_OUTPUT, `${k}=${v ?? ""}\n`);
output("report", file);

if (!env.ok) {
  const m = env.error?.message ?? "unknown error";
  console.log(`::error title=Agent readiness check failed::${m}`);
  if (process.env.SUMMARY !== "false")
    append(process.env.GITHUB_STEP_SUMMARY, `## Agent readiness check failed\n\n${md(m)}\n`);
  process.exit(0);
}

const d = env.data;
const sc = d.scores ?? {};
const score = (v) => (v === null || v === undefined ? "not scored (no rule applies)" : `${v}/100`);
const problems = d.problems ?? [];
const failing = d.passed === false;
const pages = (n) => `${n} ${n === 1 ? "page" : "pages"}`;

output("score", sc.overall ?? "");
output("reach", sc.reach ?? "");
output("understand", sc.understand ?? "");
output("act", sc.act ?? "");
output("passed", String(d.passed !== false));
output("problems", problems.length);

const verdict =
  d.fail_under === null || d.fail_under === undefined
    ? ""
    : failing
      ? ` · failed (under ${d.fail_under})`
      : ` · passed (${d.fail_under} or more)`;

// Log: a compact version of the human output.
console.log(
  `Agent readiness ${score(sc.overall)}${verdict} · ${d.check.root_url} · ${pages(d.check.pages_checked)}`,
);
console.log(`  Reach ${score(sc.reach)} · Understand ${score(sc.understand)} · Act ${score(sc.act)}`);
for (const p of problems) console.log(`  [${p.weight}] ${p.id}: ${p.summary}`);
if (failing) {
  const s = sc.overall === null || sc.overall === undefined ? "has no score" : `is ${sc.overall}/100`;
  console.log(
    `::error title=Agent readiness under ${d.fail_under}::Agent readiness ${s}, under --fail-under ${d.fail_under}.`,
  );
}

if (process.env.SUMMARY === "false") process.exit(0);

function md(s) {
  return String(s ?? "")
    .replace(/\s+/g, " ")
    .replace(/[|<>]/g, (c) => ({ "|": "\\|", "<": "&lt;", ">": "&gt;" })[c]);
}
const fence = (text, lang) => {
  const t = String(text).replace(/\s+$/, "");
  const ticks = "`".repeat(Math.max(3, ...[...t.matchAll(/`+/g)].map((m) => m[0].length + 1)));
  return `${ticks}${lang ?? ""}\n${t}\n${ticks}`;
};

const lines = [
  `## Agent readiness: ${score(sc.overall)}${verdict}`,
  "",
  `${md(d.check.root_url)} · ${pages(d.check.pages_checked)} checked · rules ${md(d.check.rules_version)}`,
  "",
  "| Category | Score |",
  "| --- | --- |",
  `| **Overall** | **${score(sc.overall)}** |`,
  `| Reach | ${score(sc.reach)} |`,
  `| Understand | ${score(sc.understand)} |`,
  `| Act | ${score(sc.act)} |`,
  "",
];
if (problems.length) {
  lines.push(
    "### Fix these first",
    "",
    "| Weight | Area | Rule | Finding |",
    "| ---: | --- | --- | --- |",
    ...problems.map((p) => `| ${p.weight} | ${md(p.category)} | \`${md(p.id)}\` | ${md(p.summary)} |`),
    "",
  );
  for (const p of problems) {
    const body = [`**${md(p.title)}.** ${md(p.fix?.text)}`];
    for (const e of (p.evidence ?? []).slice(0, 3))
      body.push(`- ${md(e.label ?? e.url)}${e.snippet ? `: \`${md(e.snippet).slice(0, 160)}\`` : ""}`);
    if (p.fix?.snippet) body.push("", fence(p.fix.snippet, p.fix.language === "text" ? "" : p.fix.language));
    if (p.sources?.length) body.push("", `Sources: ${p.sources.map((u, i) => `[${i + 1}](${u})`).join(" ")}`);
    lines.push(
      `<details><summary><code>${md(p.id)}</code>: how to fix</summary>`,
      "",
      ...body,
      "",
      "</details>",
      "",
    );
  }
} else {
  lines.push("No problems found.", "");
}
const info = (d.informational ?? []).length;
if (info) lines.push(`${info} informational findings on emerging agent protocols are never scored.`, "");
lines.push(
  '<sub>Checked by surfacedd-check: no AI calls, nothing stored. Whole-site crawls, history and step-by-step fixes: the <a href="https://surfacedd.com/features/agent-readiness">Surfacedd app</a>.</sub>',
  "",
);
append(process.env.GITHUB_STEP_SUMMARY, lines.join("\n"));
