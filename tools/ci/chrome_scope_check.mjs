#!/usr/bin/env node
// Chrome scope check. Assertion 27 of the design note's `## Tests`.
//
// TWO things, both of which have shipped broken before:
//
// 1. No identifier exported by client/chrome_common.js may be re-declared as
//    a top-level `function` or `var` in client/renderer.js. A game-block
//    `function markBeat` is HOISTED over the chrome alias `var markBeat =
//    C.markBeat` and silently turns every scrubber beat into an unlabelled
//    div that never seeks — every static grep stays green (tandem,
//    2026-08-23). The game block reaches the chrome through `C.` only.
//
// 2. client/chrome_common.js still carries its copied-region markers. They
//    are the evidence that the chrome is cogame-babel's chrome and not a
//    lookalike, so a future "tidy-up" that rewrites it fails loudly here
//    rather than quietly at review.
//
//   node tools/ci/chrome_scope_check.mjs

import { readFileSync } from "node:fs";
import process from "node:process";

const CHROME = "client/chrome_common.js";
const GAME = "client/renderer.js";

const chrome = readFileSync(CHROME, "utf8");
const game = readFileSync(GAME, "utf8");

const problems = [];

// ---- 1. the exported surface -------------------------------------------
const exportBlock = chrome.match(
  /window\.GozuChrome\s*=\s*\{([\s\S]*?)\n\s*\};/);
if (!exportBlock) {
  problems.push(`${CHROME}: no window.GozuChrome = { ... } export block`);
}
const exported = exportBlock
  ? [...exportBlock[1].matchAll(/^\s*([A-Za-z_$][\w$]*)\s*:/gm)]
      .map((m) => m[1])
  : [];
if (exported.length < 20) {
  problems.push(`${CHROME}: only ${exported.length} exported names found; ` +
    "the copied chrome exports far more than that");
}

const declared = new Set();
for (const match of game.matchAll(/^\s{0,4}function\s+([A-Za-z_$][\w$]*)/gm)) {
  declared.add(match[1]);
}
for (const match of game.matchAll(/^\s{0,4}var\s+([A-Za-z_$][\w$]*)/gm)) {
  declared.add(match[1]);
}
const clashes = exported.filter((name) => declared.has(name));
if (clashes.length) {
  problems.push(`${GAME} re-declares chrome identifiers at top level: ` +
    `${clashes.join(", ")}. A hoisted game-block declaration shadows the ` +
    "chrome one and the failure is silent (tandem, 2026-08-23). Reach the " +
    "chrome through the GozuChrome handle instead.");
}

// ---- 2. the copied regions ---------------------------------------------
const REQUIRED_REGIONS = [
  "lines 20-37", "lines 85-87", "lines 101-127", "lines 327-334",
  "lines 680-734", "lines 735-745", "lines 790-864", "lines 865-901",
  "lines 934-1049", "lines 1145-1222",
];
for (const region of REQUIRED_REGIONS) {
  if (!chrome.includes(`copied from cogame-babel@d55d999 ` +
      `client/renderer.js ${region}`)) {
    problems.push(`${CHROME}: the marker for the copied region ` +
      `"${region}" is gone. The chrome is cogame-babel's, copied; if you ` +
      "meant to change it, change the design note first.");
  }
}
if (!chrome.includes("feedText(event, nameMap, ctx)")) {
  problems.push(`${CHROME}: renderFeed no longer calls the injected ` +
    "feedText — that is the ONE edit the copy is allowed to carry.");
}
if (!chrome.includes("function markRoundBeat(")) {
  problems.push(`${CHROME}: markRoundBeat is missing (the labelled, ` +
    "clickable beat builder).");
}
if (/^\s{0,4}function\s+markBeat\b/m.test(game)) {
  problems.push(`${GAME}: declares markBeat. Use markRoundBeat — that ` +
    "rename is the tandem fix, not a style preference.");
}
if (!chrome.includes("function relayout(")) {
  problems.push(`${CHROME}: relayout() is missing (--band / --hudscale).`);
}

if (problems.length) {
  for (const problem of problems) console.error(`::error::${problem}`);
  process.exit(1);
}
console.log(`chrome scope OK: ${exported.length} exported names, ` +
  `${REQUIRED_REGIONS.length} copied regions intact, no shadowing in ${GAME}`);
