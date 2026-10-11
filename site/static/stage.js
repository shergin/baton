// The stage: a screen over real records. Click a field in the store and
// the views whose fragment read that field of that record light up; the
// tally counts bodies that ran. The view tree and what each view reads
// came from the compiler's report when the page was built.

for (const stage of document.querySelectorAll(".stage")) {
  const data = JSON.parse(stage.querySelector("script.stage-data").textContent);
  const views = new Map(data.views.map((view) => [view.id, view]));
  const elements = new Map();
  for (const element of stage.querySelectorAll(".view")) elements.set(element.dataset.view, element);
  const readers = new Map();
  for (const view of data.views) {
    for (const [record, field] of view.reads) {
      const key = `${record}\u0000${field}`;
      const list = readers.get(key) ?? [];
      list.push(view.id);
      readers.set(key, list);
    }
  }
  const total = stage.querySelector(".total");
  const count = stage.querySelector("#tally-count") ?? stage.querySelector(".count");
  const last = stage.querySelector("#tally-last") ?? stage.querySelector(".last");
  total.textContent = String(data.views.length);
  let ran = 0;
  const describe = (ids) => {
    const names = ids.map((id) => {
      const view = views.get(id);
      return view.record ? `${view.name} for ${view.record}` : view.name;
    });
    if (names.length === 0) return "No body ran: no view read that field.";
    if (names.length === 1) return `One body ran: ${names[0]}.`;
    return `${names.length} bodies ran: ${names.join(", ")}.`;
  };
  const flash = (ids) => {
    for (const id of ids) {
      const element = elements.get(id);
      if (!element) continue;
      element.classList.remove("is-flash");
      void element.offsetWidth;
      element.classList.add("is-flash");
    }
  };
  const change = (record, field, label) => {
    const ids = readers.get(`${record}\u0000${field}`) ?? [];
    ran += ids.length;
    count.textContent = String(ran);
    last.textContent = `${label} ${describe(ids)}`;
    flash(ids);
    const slot = stage.querySelector(`.slot[data-record="${CSS.escape(record)}"][data-field="${CSS.escape(field)}"]`);
    if (slot) {
      slot.classList.add("is-changed");
      window.setTimeout(() => slot.classList.remove("is-changed"), 900);
    }
  };
  for (const slot of stage.querySelectorAll(".slot")) {
    slot.addEventListener("click", () => {
      change(slot.dataset.record, slot.dataset.field, `${slot.dataset.record}.${slot.dataset.field} changed.`);
    });
    slot.addEventListener("mouseenter", () => {
      for (const id of readers.get(`${slot.dataset.record}\u0000${slot.dataset.field}`) ?? []) {
        elements.get(id)?.classList.add("is-hover");
      }
    });
    slot.addEventListener("mouseleave", () => {
      for (const element of elements.values()) element.classList.remove("is-hover");
    });
  }
  for (const button of stage.querySelectorAll(".scenario")) {
    button.addEventListener("click", () => {
      switch (button.dataset.scenario) {
        case "same": {
          last.textContent = "A refetch answered with the same bytes. The store compared each slot, found no change, and notified nothing: no body ran.";
          break;
        }
        case "first-name": {
          const row = data.views.find((view) => view.record);
          if (row) change(row.record, "name", `${row.record}.name changed.`);
          break;
        }
        case "list": {
          const [record, field] = data.list;
          change(record, field, `The list ${record}.${field} gained a link.`);
          break;
        }
        case "reset": {
          ran = 0;
          count.textContent = "0";
          last.textContent = "Nothing has changed yet.";
          break;
        }
        default:
          break;
      }
    });
  }
}
