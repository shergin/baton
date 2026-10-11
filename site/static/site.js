// Site chrome: the contents toggle, the search box, copy buttons, the table
// of contents that follows the reader, tabs (a SwiftUI or Compose choice
// holds across the page and across visits), and the hovers that make a
// store legible: a link lights its record, a response field lights the
// slot it became.

(() => {
  const root = window.BATON_ROOT ?? "./";

  // Contents toggle on narrow screens.
  const toggle = document.querySelector(".nav-toggle");
  const sidebar = document.getElementById("sidebar");
  if (toggle && sidebar) {
    toggle.addEventListener("click", () => {
      const open = sidebar.classList.toggle("open");
      toggle.setAttribute("aria-expanded", String(open));
    });
  }

  // Copy buttons on code blocks.
  const wireCopy = (scope) => {
    for (const block of scope.querySelectorAll(".code")) {
      if (block.querySelector(":scope > .copy")) continue;
      const pre = block.querySelector("pre");
      if (!pre) continue;
      const button = document.createElement("button");
      button.type = "button";
      button.className = "copy";
      button.textContent = "copy";
      button.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(pre.textContent ?? "");
          button.textContent = "copied";
        } catch {
          button.textContent = "select it";
        }
        window.setTimeout(() => {
          button.textContent = "copy";
        }, 1400);
      });
      block.append(button);
    }
  };

  // Tabs. A language group remembers the reader's platform.
  let language = null;
  try {
    language = window.localStorage.getItem("baton-language");
  } catch {
    language = null;
  }
  const select = (panels, key) => {
    const tabs = [...panels.querySelectorAll(":scope > .tabs > button")];
    const bodies = [...panels.querySelectorAll(":scope > .panel")];
    if (!tabs.some((tab) => tab.dataset.panel === key)) return;
    for (const tab of tabs) tab.setAttribute("aria-selected", String(tab.dataset.panel === key));
    for (const body of bodies) body.hidden = body.dataset.panel !== key;
  };
  const wireTabs = (scope) => {
    for (const panels of scope.querySelectorAll(".panels")) {
      const tabs = [...panels.querySelectorAll(":scope > .tabs > button")];
      const grouped = panels.dataset.group === "language";
      if (grouped && language) select(panels, language);
      for (const tab of tabs) {
        tab.addEventListener("click", () => {
          const key = tab.dataset.panel;
          if (grouped) {
            language = key;
            try {
              window.localStorage.setItem("baton-language", key);
            } catch {
              // A private window keeps nothing; the choice still holds here.
            }
            for (const other of document.querySelectorAll(".panels[data-group='language']")) select(other, key);
          } else {
            select(panels, key);
          }
        });
      }
    }
  };

  // A link in a record lights its target; a target record is a link away.
  const wireRecords = (scope) => {
    for (const records of scope.querySelectorAll(".records")) {
      const byKey = new Map();
      for (const record of records.querySelectorAll(".record")) byKey.set(record.dataset.key, record);
      for (const ref of records.querySelectorAll(".ref")) {
        const target = byKey.get(ref.dataset.ref);
        if (!target) continue;
        ref.addEventListener("mouseenter", () => target.classList.add("is-target"));
        ref.addEventListener("mouseleave", () => target.classList.remove("is-target"));
        ref.addEventListener("click", (event) => {
          event.preventDefault();
          target.scrollIntoView({ block: "nearest", behavior: "smooth" });
          target.classList.add("is-target");
          window.setTimeout(() => target.classList.remove("is-target"), 1200);
        });
      }
    }
  };

  // The normalize plate: a response field and the slot it became light
  // together.
  const wireNormalize = (scope) => {
    for (const plate of scope.querySelectorAll(".normalize")) {
      const data = plate.querySelector("script.link-map");
      if (!data) continue;
      let map;
      try {
        map = JSON.parse(data.textContent);
      } catch {
        continue;
      }
      const slots = new Map();
      for (const row of plate.querySelectorAll(".record tr")) {
        slots.set(`${row.dataset.record}\u0000${row.dataset.field}`, row);
      }
      const records = new Map();
      for (const record of plate.querySelectorAll(".record")) records.set(record.dataset.key, record);
      const fields = new Map();
      for (const field of plate.querySelectorAll("[data-path]")) {
        const list = fields.get(field.dataset.path) ?? [];
        list.push(field);
        fields.set(field.dataset.path, list);
      }
      const byRecord = new Map();
      for (const [path, [record, field]] of Object.entries(map)) {
        const key = `${record}\u0000${field}`;
        const list = byRecord.get(key) ?? [];
        list.push(path);
        byRecord.set(key, list);
      }
      let lit = [];
      const clear = () => {
        for (const element of lit) element.classList.remove("is-hover", "is-target");
        lit = [];
      };
      const light = (path) => {
        clear();
        const hit = map[path];
        if (!hit) return;
        const [record, field] = hit;
        for (const element of fields.get(path) ?? []) {
          element.classList.add("is-hover");
          lit.push(element);
        }
        const row = slots.get(`${record}\u0000${field}`);
        if (row) {
          row.classList.add("is-hover");
          lit.push(row);
        }
        const card = records.get(record);
        if (card) {
          card.classList.add("is-target");
          lit.push(card);
          if (!row) card.scrollIntoView({ block: "nearest" });
        }
      };
      for (const [path, elements] of fields) {
        for (const element of elements) {
          element.addEventListener("mouseenter", () => light(path));
        }
      }
      for (const [key, row] of slots) {
        row.addEventListener("mouseenter", () => {
          clear();
          row.classList.add("is-hover");
          lit.push(row);
          for (const path of byRecord.get(key) ?? []) {
            for (const element of fields.get(path) ?? []) {
              element.classList.add("is-hover");
              lit.push(element);
            }
          }
        });
      }
      plate.addEventListener("mouseleave", clear);
    }
  };

  window.batonWire = (scope) => {
    wireCopy(scope);
    wireTabs(scope);
    wireRecords(scope);
    wireNormalize(scope);
  };
  window.batonWire(document);

  // The table of contents follows the section in view.
  const toc = document.querySelector(".toc");
  if (toc && "IntersectionObserver" in window) {
    const links = new Map();
    for (const link of toc.querySelectorAll("a[href^='#']")) {
      links.set(decodeURIComponent(link.getAttribute("href").slice(1)), link);
    }
    const headings = [...links.keys()].map((id) => document.getElementById(id)).filter(Boolean);
    let current = null;
    const mark = (id) => {
      if (current) current.removeAttribute("aria-current");
      current = links.get(id) ?? null;
      if (current) current.setAttribute("aria-current", "true");
    };
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) mark(entry.target.id);
        }
      },
      { rootMargin: "-10% 0px -80% 0px" },
    );
    for (const heading of headings) observer.observe(heading);
  }

  // Search: a small index, substring matching, keyboard navigable.
  const input = document.getElementById("search");
  const results = document.getElementById("results");
  if (!input || !results) return;
  let index = null;
  let selected = -1;
  const load = async () => {
    if (index) return index;
    const response = await fetch(`${root}search.json`);
    index = await response.json();
    return index;
  };
  const escape = (text) =>
    text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const snippet = (text, query) => {
    const at = text.toLowerCase().indexOf(query);
    if (at < 0) return text.slice(0, 110);
    const start = Math.max(0, at - 40);
    return (start > 0 ? "…" : "") + text.slice(start, start + 120) + "…";
  };
  const score = (entry, query) => {
    const title = entry.title.toLowerCase();
    if (title === query) return 100;
    if (title.startsWith(query)) return 60;
    if (title.includes(query)) return 40;
    const heading = entry.headings.find((h) => h.toLowerCase().includes(query));
    if (heading) return 25;
    if (entry.text.toLowerCase().includes(query)) return 10;
    return 0;
  };
  const slug = (text) =>
    text
      .toLowerCase()
      .replace(/[^\p{L}\p{N} -]/gu, "")
      .replace(/[ ]/g, "-");
  const render = async () => {
    const query = input.value.trim().toLowerCase();
    selected = -1;
    if (query.length < 2) {
      results.hidden = true;
      results.innerHTML = "";
      return;
    }
    const entries = await load();
    const hits = entries
      .map((entry) => ({ entry, score: score(entry, query) }))
      .filter((hit) => hit.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, 8);
    if (hits.length === 0) {
      results.innerHTML = `<p class="empty">Nothing matches “${escape(input.value.trim())}”.</p>`;
      results.hidden = false;
      return;
    }
    results.innerHTML = hits
      .map(({ entry }) => {
        const heading = entry.headings.find((h) => h.toLowerCase().includes(query));
        const anchor = heading ? `#${slug(heading)}` : "";
        const where = heading ? `${entry.section} › ${escape(entry.title)}` : entry.section;
        const label = heading ? escape(heading) : escape(entry.title);
        return `<a href="${root}${entry.url.replace(/^\//, "")}${anchor}"><span class="where">${where}</span>${label}<span class="snippet">${escape(snippet(entry.text, query))}</span></a>`;
      })
      .join("");
    results.hidden = false;
  };
  input.addEventListener("input", render);
  input.addEventListener("focus", render);
  input.addEventListener("keydown", (event) => {
    const items = [...results.querySelectorAll("a")];
    if (event.key === "Escape") {
      results.hidden = true;
      input.blur();
      return;
    }
    if (items.length === 0) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      items[selected]?.removeAttribute("aria-selected");
      selected = event.key === "ArrowDown" ? (selected + 1) % items.length : (selected - 1 + items.length) % items.length;
      items[selected].setAttribute("aria-selected", "true");
      items[selected].scrollIntoView({ block: "nearest" });
    }
    if (event.key === "Enter" && selected >= 0) {
      event.preventDefault();
      items[selected].click();
    }
  });
  document.addEventListener("click", (event) => {
    if (!results.contains(event.target) && event.target !== input) results.hidden = true;
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "/" && document.activeElement !== input && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName ?? "")) {
      event.preventDefault();
      input.focus();
    }
  });
})();
