// Tests the browser-side matching against real rendered HTML using jsdom.
//   node test/js-test.cjs <path-to-node_modules-with-jsdom> <go-project-dir>
const path = require("path");
const fs = require("fs");
const { createRequire } = require("module");
const { JSDOM } = createRequire(path.resolve(process.argv[2]) + "/")("jsdom");
const goProject = path.resolve(process.argv[3]);
const js = fs.readFileSync(path.join(__dirname, "../_extensions/quarto-jump/quarto-jump.js"), "utf8");

let failures = 0;
function check(name, cond, info) {
  console.log((cond ? "ok   " : "FAIL ") + name + (cond ? "" : "  -- " + JSON.stringify(info)));
  if (!cond) failures++;
}

function load(file, source) {
  const html = fs.readFileSync(file, "utf8").replace(/<script\b[\s\S]*?<\/script>/gi, "");
  const dom = new JSDOM(html, { url: "http://localhost:4200/x.html", runScripts: "outside-only" });
  const w = dom.window;
  w.QUARTO_JUMP = { port: 7878, key: "j", source };
  w.sent = [];
  w.fetch = (url, opts) => {
    w.sent.push({ url, body: JSON.parse(opts.body) });
    return Promise.resolve({ json: () => ({ ok: true, file: "f", lnum: 1 }) });
  };
  w.eval(js);
  return new Promise((resolve) =>
    w.QuartoJump ? resolve(w) : w.document.addEventListener("DOMContentLoaded", () => resolve(w)));
}

(async () => {

const sectionId = (el) => el && el.closest("section[id]") && el.closest("section[id]").id;

// --- the real deck (Jinja assembled, data-source-file on slides) ---------------
const w = await load(path.join(goProject, "slides_04.html"), "slides_04.qmd");
const define = "slides/04_mocking/01_interfaces/01_define.qmd";
const satisfy = "slides/04_mocking/01_interfaces/02_satisfy.qmd";

let t = w.QuartoJump.findTarget({ file: define, heading: "interface definieren", index: 1,
  text: "nur methodensignaturen keine daten keine implementierung" });
check("sync: paragraph in file", t && t.tagName === "P" && sectionId(t) === "interface-definieren", t && t.outerHTML);

t = w.QuartoJump.findTarget({ file: satisfy, heading: "interface erfüllen", index: 1, text: "" });
check("sync: heading only", t && /^H/.test(t.tagName) && sectionId(t) === "interface-erfüllen", t && t.outerHTML);

t = w.QuartoJump.findTarget({ file: define, heading: "interface definieren", index: 1,
  text: "write p byte n int err error" });
check("sync: code line", t && t.matches("pre code > span"), t && t.outerHTML);

t = w.QuartoJump.findTarget({ file: "slides/does/not/exist.qmd", heading: "", index: 0, text: "" });
check("sync: unknown file -> nothing", t === null, t && t.outerHTML);

// Alt+click on the paragraph
const p = [...w.document.querySelectorAll("p")].find((e) => e.textContent.startsWith("Nur Methodensignaturen"));
p.dispatchEvent(new w.MouseEvent("click", { bubbles: true, altKey: true }));
const b = w.sent[0] && w.sent[0].body;
check("alt+click payload", b && b.sourceFile === define && b.text.startsWith("Nur Methodensignaturen"), b);

// Alt+click on a code token -> whole code line
const tok = w.document.querySelector("section#interface-definieren pre code > span span");
tok.dispatchEvent(new w.MouseEvent("click", { bubbles: true, altKey: true }));
const b2 = w.sent[1] && w.sent[1].body;
check("alt+click code token -> line", b2 && /^type Writer interface/.test(b2.text), b2);

// --- generic fixture: include, no data-source-file --------------------------------
const f = path.join(__dirname, "fixture/deck.html");
if (fs.existsSync(f)) {
  const g = await load(f, "deck.qmd");
  t = g.QuartoJump.findTarget({ file: "parts/_included.qmd", heading: "included slide", index: 1,
    text: "text that lives in an included file" });
  check("fixture: included file found by text", t && sectionId(t) === "included-slide", t && t.outerHTML);
  t = g.QuartoJump.findTarget({ file: "deck.qmd", heading: "last slide", index: 3, text: "item two with a link" });
  check("fixture: list item with link", t && t.tagName === "LI", t && t.outerHTML);
}

console.log(failures ? `\n${failures} test(s) failed` : "\nall tests passed");
process.exit(failures ? 1 : 0);
})();
