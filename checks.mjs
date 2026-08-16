//  checks.mjs — run with:  node ModerationDashboard/checks.mjs
//
//  The dashboard is a single HTML file with no build step and no test runner,
//  which is right for what it is — but bulk delete is a destructive button
//  wired to a set of ids, and "I looked at it and it seemed fine" is not
//  enough for that. This pulls the real <script> out of index.html, stubs
//  Supabase and the DOM, and drives the selection logic directly.
//
//  It is not a substitute for opening the page. It is here so that the parts
//  that can silently do the wrong thing — which ids a bulk action sends,
//  which status column each tab writes, whether select-all can reach a row
//  you cannot see — are checked by something other than eyes.

import fs from "fs";
const src = fs.readFileSync("ModerationDashboard/index.html", "utf8");
let js = src.match(/<script type="module">([\s\S]*)<\/script>/)[1];
js = js.replace(/^import .*$/m, "");
js = js.replace('const sb = createClient(SUPABASE_URL, ANON_KEY);', 'const sb = GLOBALS.sb;');
js = js.replace('const probe = createClient(SUPABASE_URL, ANON_KEY);', 'const probe = GLOBALS.sb;');
js = js.split("const { data: { session } }")[0];

const calls = [];
const els = {};
const el = () => ({ innerHTML: "", textContent: "", style: {}, addEventListener() {} });
const GLOBALS = {
  sb: {
    from() {
      const q = {
        select: () => q, order: () => q,
        limit: () => Promise.resolve({ data: GLOBALS.rows }),
        update: (p) => ({
          in: (c, ids) => { calls.push(["update", p, ids]); return Promise.resolve({}); },
          eq: () => Promise.resolve({}) }),
        delete: () => ({
          in: (c, ids) => { calls.push(["delete", ids]); return Promise.resolve({}); },
          eq: () => Promise.resolve({}) }),
      };
      return q;
    },
    auth: { getSession: () => Promise.resolve({ data: { session: null } }) },
  },
  rows: [],
};
const win = {};
globalThis.GLOBALS = GLOBALS;
globalThis.window = win;
globalThis.alert = (m) => calls.push(["alert", m]);
globalThis.confirm = () => true;
globalThis.document = {
  getElementById: (id) => (els[id] ||= el()),
  querySelectorAll: () => [],
};
globalThis.CSS = { escape: (s) => s };

const mod = new Function("GLOBALS", `${js}
  return { render, visibleRows, cardHTML, load,
           setTab:(t)=>{currentTab=t;}, setRows:(r)=>{rows=r;},
           setReach:(m)=>{Object.assign(reachById,m);},
           selected, tabs:TABS };`)(GLOBALS);

let fails = 0;
const ok = (cond, name) => { console.log((cond ? "PASS " : "FAIL ") + name); if (!cond) fails++; };

// 1. Barcode Fails is gone.
ok(!mod.tabs.some(t => t.id === "moderation_barcode_triage"), "Barcode Fails tab removed");
ok(mod.tabs.length === 5, "five tabs remain");

// 2. Reach hiding.
mod.setTab("moderation_ai_candidates");
mod.setRows([
  { id: "a", name: "Alpha", approval_status: "approved" },
  { id: "b", name: "Beta",  approval_status: "approved" },
  { id: "c", name: "Gamma", approval_status: "pending"  },
]);
mod.setReach({
  a: { active_devices: 10, reached_devices: 10 },   // fully reached
  b: { active_devices: 10, reached_devices: 4  },   // still going
});
ok(JSON.stringify(mod.visibleRows().map(r => r.id)) === '["b","c"]',
   "fully-reached approved row is hidden, others stay");
win.toggleSettled();
ok(mod.visibleRows().length === 3, "toggle shows it again");
win.toggleSettled();

// 3. Select all covers only VISIBLE rows — never the hidden ones.
win.selectAll(true);
ok(!mod.selected.has("a"), "select-all does not reach a hidden row");
ok(mod.selected.size === 2, "select-all picks both visible rows");

// 4. Bulk approve sends the right column and ids.
calls.length = 0;
await win.bulk("approved");
ok(calls[0][0] === "update", "bulk issued an update");
ok(JSON.stringify(calls[0][1]) === '{"approval_status":"approved"}',
   "AI candidates use approval_status, not status");
ok(JSON.stringify(calls[0][2].sort()) === '["b","c"]', "only the selected ids");
ok(mod.selected.size === 0, "selection cleared after the write");

// 5. Other tabs use `status`.
mod.setTab("moderation_submissions");
mod.setRows([{ id: "x" }, { id: "y" }]);
win.selectAll(true);
calls.length = 0;
await win.bulk("rejected");
ok(JSON.stringify(calls[0][1]) === '{"status":"rejected"}', "other tabs use status");

// 6. Bulk delete. (bulk() calls load(), which refetches — so re-seed first.)
mod.setRows([{ id: "x" }, { id: "y" }]);
win.selectAll(true);
calls.length = 0;
await win.bulkDelete();
ok(calls[0][0] === "delete" && calls[0][1].length === 2, "bulk delete sends both ids");

// 7. A card renders a checkbox, and verified_foods locks the numbers.
mod.setTab("verified_foods");
const card = mod.cardHTML({ id: "v1", product_name: "Thing", brand: "B",
                            serving_size_g: 30, calories: 100, protein_g: 2 });
ok(card.includes('class="pick"'), "card has a select checkbox");
ok(card.includes('data-col="product_name"'), "product name editable");
ok(card.includes('data-col="brand"'), "brand editable");
ok(card.includes('data-col="serving_size_g"'), "serving editable");
ok(!card.includes('data-col="calories"'), "calories NOT editable");
ok(!card.includes('data-col="protein_g"'), "protein NOT editable");
ok(!card.includes('data-col="barcode"'), "barcode NOT editable");

console.log(fails ? `\n${fails} FAILED` : "\nall good");
process.exit(fails ? 1 : 0);
