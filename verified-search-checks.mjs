//  verified-search-checks.mjs — run with:
//      node ModerationDashboard/verified-search-checks.mjs
//
//  The `search` task on the verified-foods edge function decides which rows a
//  typed query reaches. Its matching rule is pure and is the part that can
//  silently do the wrong thing, so it is checked here rather than by eye.
//
//  It exists because the first deployed version used `haystack.includes(word)`
//  and a search for "old gold" returned "GOLD STANDARD 100% ISOLATE" and
//  "Gold Medal Snacks / Pork Krackles" — "old" sits inside "gold". That is the
//  same substring trap that has now bitten this project in the drink
//  classifier, the beverage classifier, the icon resolver and here.
//
//  The functions are pulled out of the real index.ts so this cannot drift from
//  what is deployed.

import fs from "fs";
const src = fs.readFileSync("supabase/functions/verified-foods/index.ts", "utf8");

function extract(name) {
  // Plain scanning rather than a regex: brace-counting is exact, and the
  // escaping needed to write this as a regex through a shell heredoc is its
  // own source of bugs.
  const head = src.indexOf(`function ${name}(`);
  if (head < 0) throw new Error(`could not find ${name} in index.ts`);
  let i = src.indexOf("{", head), depth = 0;
  for (let j = i; j < src.length; j++) {
    if (src[j] === "{") depth++;
    else if (src[j] === "}") {
      depth--;
      if (depth === 0) {
        return src.slice(head, j + 1)
          .split(": string[]").join("")
          .split(": string").join("")
          .split(": boolean").join("");
      }
    }
  }
  throw new Error(`unbalanced braces in ${name}`);
}

const mod = new Function(
  `${extract("likeSafe")}\n${extract("handleSearchWords")}\n${extract("wordsMatch")}
   return { likeSafe, handleSearchWords, wordsMatch };`)();

let fails = 0;
const ok = (cond, msg) => {
  if (!cond) { fails++; console.log(`FAIL  ${msg}`); }
  else console.log(`ok    ${msg}`);
};

const match = (query, brand, name, flavour = "") =>
  mod.wordsMatch(mod.handleSearchWords(query),
                 mod.likeSafe(`${brand} ${name} ${flavour}`));

// ── the regression ──
ok(!match("old gold", "OPTIMUM NUTRITION", "GOLD STANDARD 100% ISOLATE"),
   '"old gold" must not reach GOLD STANDARD — "old" is inside "gold"');
ok(!match("old gold", "Gold Medal Snacks", "Pork Krackles"),
   '"old gold" must not reach Pork Krackles');
ok(match("old gold", "Cadbury", "Old Gold Dark Chocolate Espresso Affogato"),
   '"old gold" still reaches the product actually called Old Gold');

// ── what a search box has to keep doing ──
ok(match("choc", "Cadbury", "Old Gold Dark Chocolate Espresso Affogato"),
   'a prefix still matches: "choc" finds "Chocolate"');
ok(match("affog", "Cadbury", "Old Gold Dark Chocolate Espresso Affogato"),
   '"affog" finds "Affogato"');
ok(match("cadbury old gold espresso", "Cadbury",
         "Old Gold Dark Chocolate Espresso Affogato"),
   "brand word plus name words match across both columns");
ok(match("espresso affogato", "Cadbury",
         "Old Gold Dark Chocolate Espresso Affogato"),
   "words that are not adjacent in the name still match");
ok(!match("cadbury pork", "Cadbury", "Old Gold Dark Chocolate Espresso Affogato"),
   "EVERY word must match, not just one");

// ── flavour is searchable too ──
ok(match("mint", "Cadbury", "Old Gold Dark Chocolate", "Peppermint") === false,
   '"mint" does not match "Peppermint" mid-word');
ok(match("pepper", "Cadbury", "Old Gold Dark Chocolate", "Peppermint"),
   "flavour is part of the haystack");

// ── the sanitiser ──
ok(mod.likeSafe("Reese's, Peanut (Butter)") === "reese s  peanut  butter",
   "punctuation is reduced to spaces so it cannot reach a PostgREST filter");
ok(mod.handleSearchWords("  OLD   gold  ").join("|") === "old|gold",
   "words are lowercased and collapsed");
ok(mod.handleSearchWords("%,()").length === 0,
   "a query of pure punctuation yields no words");

console.log(fails ? `\n${fails} FAILED` : "\nall good");
process.exit(fails ? 1 : 0);
