// quarto-jump: browser side.
//
//   Alt+J        jump to the current slide (revealjs) / section (html) in Neovim
//   Ctrl+click   jump to the clicked element in Neovim (Cmd+click on Mac)
//   (automatic)  follow the Neovim cursor (Server-Sent Events from Neovim)
//
// Only active when the page is served from localhost (quarto preview).
(function () {
  "use strict";

  const LOCAL = ["localhost", "127.0.0.1", "[::1]", "::1"];
  if (!LOCAL.includes(location.hostname)) return;

  const BLOCK = [
    "pre code > span", "li", "p", "h1", "h2", "h3", "h4", "h5", "h6",
    "td", "th", "dt", "dd", "figcaption", "blockquote", "summary",
    ".callout-title-container", "img",
  ].join(",");
  const PENDING_KEY = "quarto-jump-pending";

  let cfg, base, clickMods;

  const words = (s) => (s || "").toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const norm = (s) => words(s).join(" ");
  const isReveal = () => !!(window.Reveal && document.querySelector(".reveal .slides"));

  function textOf(el) {
    if (!el) return "";
    if (el.tagName === "IMG") return el.getAttribute("alt") || "";
    return (el.textContent || "").trim();
  }

  function sourceOf(el) {
    const s = el && el.closest && el.closest("[data-source-file]");
    return s ? s.getAttribute("data-source-file") : cfg.source || null;
  }

  function headingOf(section) {
    if (!section) return null;
    for (const h of section.querySelectorAll("h1,h2,h3,h4,h5,h6")) {
      if (h.closest("section") === section) return h;
    }
    return null;
  }

  // ---------------------------------------------------------------- toast
  let toastEl, toastTimer;
  function toast(msg) {
    if (!toastEl) {
      toastEl = document.createElement("div");
      toastEl.style.cssText =
        "position:fixed;bottom:12px;left:50%;transform:translateX(-50%);z-index:100000;" +
        "background:#333;color:#fff;padding:6px 14px;border-radius:6px;font:14px sans-serif;" +
        "opacity:0;transition:opacity .2s;pointer-events:none";
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = msg;
    toastEl.style.opacity = "0.9";
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (toastEl.style.opacity = "0"), 2000);
  }

  function flash(el) {
    if (!el || !el.animate) return;
    el.animate(
      [{ outline: "3px solid rgba(255,165,0,.9)", outlineOffset: "2px" }, { outline: "3px solid rgba(255,165,0,0)" }],
      { duration: 1200, easing: "ease-out" }
    );
  }

  // ---------------------------------------------------------- browser -> nvim
  function send(payload) {
    payload.page = location.pathname;
    fetch(base + "/jump", {
      method: "POST",
      headers: { "Content-Type": "text/plain" }, // "simple" request, no preflight
      body: JSON.stringify(payload),
    })
      .then((r) => r.json())
      .then((res) => toast(res.ok ? `→ ${res.file}:${res.lnum}` : `quarto-jump: ${res.error}`))
      .catch(() => toast(`quarto-jump: Neovim not reachable on port ${cfg.port}`));
  }

  // Current slide (reveal) or the section heading nearest above the viewport top.
  function currentAnchor() {
    if (isReveal()) {
      const slide = window.Reveal.getCurrentSlide();
      const h = headingOf(slide);
      return { el: slide, text: h ? textOf(h) : textOf(slide).slice(0, 300) };
    }
    const hs = [...document.querySelectorAll("main h1, main h2, main h3, main h4, main h5, main h6")];
    if (!hs.length) return { el: document.body, text: document.title };
    let cur = hs[0];
    for (const h of hs) {
      if (h.getBoundingClientRect().top <= 80) cur = h;
      else break;
    }
    return { el: cur, text: textOf(cur) };
  }

  function onKey(e) {
    if (!e.altKey || e.ctrlKey || e.metaKey) return;
    if (e.code !== "Key" + cfg.key.toUpperCase()) return;
    e.preventDefault();
    e.stopPropagation();
    const a = currentAnchor();
    send({ sourceFile: sourceOf(a.el), text: a.text });
  }

  // "ctrl", "alt+shift", … or "auto" = Ctrl, on Mac Cmd (Ctrl+click is the
  // context menu there). Reveal's zoom plugin zooms on Alt+click (on Linux
  // Ctrl+click); the mousedown handler below keeps it from seeing our click.
  function clickModifiers() {
    let spec = String(cfg.click || "auto").toLowerCase();
    if (spec === "auto") {
      const p = navigator.platform || "";
      spec = /Mac|iPhone|iPad/.test(p) ? "meta" : "ctrl";
    }
    const want = new Set(spec.split("+").map((m) => m.trim().replace(/^cmd$/, "meta")));
    return ["ctrl", "alt", "shift", "meta"].map((m) => [m + "Key", want.has(m)]);
  }

  function isJumpClick(e) {
    return clickMods.every(([k, v]) => !!e[k] === v);
  }

  function onClick(e) {
    if (!isJumpClick(e)) return;
    e.preventDefault();
    e.stopPropagation();
    const el = (e.target.closest && e.target.closest(BLOCK)) || e.target;
    let text = textOf(el).slice(0, 500);
    if (!words(text).length) {
      const h = headingOf(el.closest("section"));
      text = h ? textOf(h) : "";
    }
    send({ sourceFile: sourceOf(el), text });
  }

  // ---------------------------------------------------------- nvim -> browser
  function root() {
    return document.querySelector(".reveal .slides") || document.querySelector("main") || document.body;
  }

  // Find the element that corresponds to the Neovim cursor position.
  function findTarget(msg) {
    const all = [...root().querySelectorAll(BLOCK)];
    const inFile = all.filter((el) => sourceOf(el) === msg.file);
    const scope = inFile.length ? inFile : all;

    // 1. current line text (most specific); prefer the smallest element,
    //    and one under the right heading if there are several.
    if (msg.text) {
      const hits = scope.filter((el) => norm(textOf(el)).includes(msg.text));
      if (hits.length) {
        const under = hits.filter((el) => {
          const h = headingOf(el.closest("section"));
          return h && norm(textOf(h)) === msg.heading;
        });
        const pool = under.length ? under : hits;
        return pool.reduce((a, b) => (textOf(b).length < textOf(a).length ? b : a));
      }
    }
    // 2. heading text
    if (msg.heading) {
      const hs = scope.filter((el) => /^H[1-6]$/.test(el.tagName) && norm(textOf(el)) === msg.heading);
      if (hs.length) return hs[0];
    }
    // 3. n-th heading of the file (only if we know which elements belong to it)
    if (inFile.length) {
      const hs = inFile.filter((el) => /^H[1-6]$/.test(el.tagName));
      return hs[Math.max(0, Math.min(hs.length - 1, msg.index - 1))] || inFile[0];
    }
    return null;
  }

  function show(el) {
    if (isReveal()) {
      let slide = el.closest("section");
      while (slide && slide.querySelector("section")) slide = slide.querySelector("section");
      if (!slide) return;
      const idx = window.Reveal.getIndices(slide);
      const cur = window.Reveal.getIndices();
      if (idx.h !== cur.h || idx.v !== cur.v) window.Reveal.slide(idx.h, idx.v);
      setTimeout(() => flash(el), 300);
    } else {
      el.scrollIntoView({ behavior: "smooth", block: "center" });
      flash(el);
    }
  }

  function gotoSource(msg) {
    const el = findTarget(msg);
    if (el) return show(el);
    // Website: the file is not on this page -> navigate if a page exists for it.
    if (isReveal() || !msg.html || cfg.source === msg.file) return;
    if (document.querySelector(`[data-source-file="${CSS.escape(msg.file)}"]`)) return;
    const url = "/" + msg.html;
    fetch(url, { method: "HEAD" })
      .then((r) => {
        if (!r.ok) return;
        sessionStorage.setItem(PENDING_KEY, JSON.stringify(msg));
        location.href = url;
      })
      .catch(() => {});
  }

  let retry = 1000;
  function connect() {
    const es = new EventSource(base + "/events");
    es.onopen = () => (retry = 1000);
    es.addEventListener("goto", (ev) => {
      try {
        gotoSource(JSON.parse(ev.data));
      } catch (err) {
        console.warn("quarto-jump:", err);
      }
    });
    es.onerror = () => {
      if (es.readyState === EventSource.CLOSED) {
        setTimeout(connect, retry);
        retry = Math.min(retry * 2, 30000);
      }
    };
  }

  function init() {
    cfg = Object.assign({ port: 7878, key: "j", click: "auto", source: null }, window.QUARTO_JUMP || {});
    clickMods = clickModifiers();
    base = `http://127.0.0.1:${cfg.port}`;
    document.addEventListener("keydown", onKey, true);
    document.addEventListener("click", onClick, true);
    // Swallow the mousedown too, so nothing else (Reveal's zoom, chalkboard,
    // text selection) reacts to the jump click. Capture phase on document runs
    // before Reveal's listener on .reveal.
    document.addEventListener("mousedown", (e) => {
      if (isJumpClick(e)) { e.preventDefault(); e.stopPropagation(); }
    }, true);
    if (window.EventSource) connect();
    window.QuartoJump = { findTarget, gotoSource, currentAnchor, sourceOf }; // for debugging/tests

    const pending = sessionStorage.getItem(PENDING_KEY);
    if (pending) {
      sessionStorage.removeItem(PENDING_KEY);
      const run = () => {
        try { gotoSource(JSON.parse(pending)); } catch (_) {}
      };
      isReveal() ? window.Reveal.on("ready", run) : setTimeout(run, 100);
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
