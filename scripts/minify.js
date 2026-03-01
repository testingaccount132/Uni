#!/usr/bin/env node
// scripts/minify.js
// Lua minifier used by GitHub Actions to pre-generate .min.lua files.
// No dependencies — pure Node.js.
//
// Usage:
//   node scripts/minify.js <input.lua> <output.min.lua>

"use strict";

const fs   = require("fs");
const path = require("path");

const EEPROM_MAX = 4096;

// ── Minifier ──────────────────────────────────────────────────────────────────

function minify(src) {
  const out = [];
  let i = 0;
  const len = src.length;

  function ch(offset = 0) { return src[i + offset] ?? ""; }
  function adv(n = 1)     { i += n; }
  function peek(n)        { return src.slice(i, i + n); }

  // Pass 1: strip comments, preserve strings
  let inStr = false, strCh = "";
  let inLongStr = false, longLevel = 0;

  while (i < len) {
    const c = ch();

    if (inLongStr) {
      const close = "]" + "=".repeat(longLevel) + "]";
      const pos   = src.indexOf(close, i);
      if (pos === -1) { out.push(src.slice(i)); break; }
      out.push(src.slice(i, pos + close.length));
      i = pos + close.length;
      inLongStr = false;
      continue;
    }

    if (inStr) {
      if (c === "\\") { out.push(c, ch(1)); adv(2); }
      else if (c === strCh) { out.push(c); adv(); inStr = false; }
      else if (c === "\n") { out.push(c); adv(); inStr = false; }
      else { out.push(c); adv(); }
      continue;
    }

    // Block comment  --[=*[
    if (peek(2) === "--" && ch(2) === "[") {
      let eq = 0;
      while (ch(3 + eq) === "=") eq++;
      if (ch(3 + eq) === "[") {
        const close = "]" + "=".repeat(eq) + "]";
        const pos   = src.indexOf(close, i + 3 + eq + 1);
        if (pos === -1) break;
        out.push("\n"); // preserve line count roughly
        i = pos + close.length;
        continue;
      }
      // Line comment
      const nl = src.indexOf("\n", i);
      i = nl === -1 ? len : nl; // keep \n
      continue;
    }

    // Line comment
    if (peek(2) === "--") {
      const nl = src.indexOf("\n", i);
      i = nl === -1 ? len : nl;
      continue;
    }

    // Long string  [=*[
    if (c === "[") {
      let eq = 0;
      while (ch(1 + eq) === "=") eq++;
      if (ch(1 + eq) === "[") {
        inLongStr  = true;
        longLevel  = eq;
        out.push(src.slice(i, i + 2 + eq));
        adv(2 + eq);
        continue;
      }
    }

    // Short string
    if (c === '"' || c === "'") {
      inStr = true; strCh = c;
      out.push(c); adv();
      continue;
    }

    out.push(c); adv();
  }

  let result = out.join("");

  // Pass 2: collapse blank lines
  result = result.replace(/\n\s*\n+/g, "\n");

  // Pass 3: trim each line
  result = result
    .split("\n")
    .map(l => l.trim())
    .filter(l => l.length > 0)
    .join("\n");

  // Pass 4: collapse multiple spaces to one
  result = result.replace(/  +/g, " ");

  // Pass 5: remove spaces between a word-char/number and a PUNCTUATION-only char.
  // Rules (safe to remove the space):
  //   word/num  BEFORE  (  [  {        e.g.  "foo ("  →  "foo("
  //   )  ]  }   BEFORE  word/num/punct  e.g.  ") end"  →  ")end"  BUT only if safe
  //   word/num  AFTER   )  ]  }               e.g.  ") x"  →  ")x"  (safe - Lua sep)
  //   space around  ,  ;  when neighbours are non-word  →  remove
  // UNSAFE to remove: space between two word-char sequences (would merge tokens).

  // Remove space: wordchar SPACE ( or [ or {
  result = result.replace(/([\w_])\s+([({\[])/g, "$1$2");
  // Remove space: ) or ] or } SPACE wordchar
  result = result.replace(/([)\]}])\s+([\w_])/g, "$1 $2"); // keep one space here
  // Remove space: ) ] } SPACE ) ] } ( [ {
  result = result.replace(/([)\]}])\s+([)\]}(\[{,;])/g, "$1$2");
  // Remove space: , or ; SPACE  →  just collapse to no space
  result = result.replace(/\s*([,;])\s*/g, "$1");
  // Remove space: ( [ {  SPACE  →  remove leading space inside bracket
  result = result.replace(/([({\[])\s+/g, "$1");
  // Remove space: SPACE ) ] }  →  remove trailing space before closing bracket
  result = result.replace(/\s+([)\]}])/g, "$1");

  // Pass 7: join short safe lines
  const lines = result.split("\n");
  const joined = [lines[0] ?? ""];
  for (let j = 1; j < lines.length; j++) {
    const prev = joined[joined.length - 1];
    const cur  = lines[j];
    const prevSafe = !/\s(do|then|else|repeat)$/.test(prev)
                  && !/^(end|else|elseif|until)/.test(prev)
                  && !/^(local\s+function|function)/.test(prev);
    const curSafe  = !/^(end[^\w]|else|elseif|until)/.test(cur);
    if (prevSafe && curSafe && prev.length + 1 + cur.length <= 200) {
      joined[joined.length - 1] = prev + " " + cur;
    } else {
      joined.push(cur);
    }
  }
  result = joined.join("\n");

  return result;
}

// ── CLI ───────────────────────────────────────────────────────────────────────

const [,, inputPath, outputPath] = process.argv;

if (!inputPath || !outputPath) {
  console.error("Usage: node scripts/minify.js <input.lua> <output.min.lua>");
  process.exit(1);
}

const src = fs.readFileSync(inputPath, "utf8");
const result = minify(src);

const saved    = src.length - result.length;
const pct      = Math.floor(saved / src.length * 100);
const fits     = result.length <= EEPROM_MAX;
const overBy   = result.length - EEPROM_MAX;

console.log(`  ${inputPath}`);
console.log(`    original : ${src.length} bytes`);
console.log(`    minified : ${result.length} bytes  (saved ${saved}B / ${pct}%)`);
if (result.length <= EEPROM_MAX) {
  console.log(`    EEPROM   : ✓ fits  (${EEPROM_MAX - result.length}B free)`);
} else {
  console.error(`    EEPROM   : ✗ TOO LARGE by ${overBy}B`);
  process.exit(1);
}

fs.writeFileSync(outputPath, result, "utf8");
console.log(`    written  : ${outputPath}`);
