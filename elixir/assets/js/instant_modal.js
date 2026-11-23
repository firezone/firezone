// Opens an item's modal in the browser before the server answers, so a click
// on a list row feels instant even on a slow link. The server's own modal
// replaces this preview when the patch it started comes back.
//
// Triggered by `Page.open_modal/2` (a `fz:instant-modal` event) and closed by
// Escape, a click on the veil, or the server's patch landing.

const SIZES = { md: "max-w-2xl", lg: "max-w-4xl", xl: "max-w-6xl" };

let root = null;
let pending = false;

function container() {
  if (root && document.body.contains(root)) return root;
  root = document.createElement("div");
  root.id = "instant-modal";
  root.className =
    "fixed inset-0 z-50 hidden items-start justify-center px-4 pt-[5vh] pb-6";
  document.body.appendChild(root);
  return root;
}

function headerOnly(title, subtitle) {
  const wrap = document.createElement("div");
  wrap.className =
    "shrink-0 flex items-center justify-between gap-3 border-b border-hair px-6 py-4";
  const text = document.createElement("div");
  text.className = "min-w-0";
  const h = document.createElement("h2");
  h.className = "text-lg font-bold tracking-tight text-fg truncate";
  h.textContent = title || "";
  text.appendChild(h);
  if (subtitle) {
    const p = document.createElement("p");
    p.className = "text-xs text-muted truncate font-mono";
    p.textContent = subtitle;
    text.appendChild(p);
  }
  wrap.appendChild(text);
  const body = document.createElement("div");
  body.className = "px-6 py-5 space-y-3 animate-pulse";
  body.innerHTML =
    '<div class="h-2.5 w-24 bg-hair"></div><div class="h-2 w-full bg-hover"></div><div class="h-2 w-5/6 bg-hover"></div>';
  const frag = document.createDocumentFragment();
  frag.appendChild(wrap);
  frag.appendChild(body);
  return frag;
}

// A copy of the clicked row: its first cell as the header, every other labelled
// column as a field, then placeholders for what only the server knows.
function fromRow(row) {
  const table = row.closest("table");
  const labels = table
    ? [...table.querySelectorAll("thead th")].map((th) => th.textContent.trim())
    : [];
  const cells = [...row.children].filter((c) => c.tagName === "TD");
  const frag = headerOnly("", "");
  const header = frag.firstChild;
  const title = header.firstChild;
  title.replaceChildren(copyOf(cells[0]));

  const fields = document.createElement("dl");
  fields.className =
    "grid grid-cols-[10rem_1fr] border-t border-rule mx-6 mt-5";
  cells.slice(1).forEach((cell, i) => {
    const label = labels[i + 1];
    if (!label) return;
    const dt = document.createElement("dt");
    dt.className = "py-2.5 border-b border-hair text-sm text-muted";
    dt.textContent = label;
    const dd = document.createElement("dd");
    dd.className = "py-2.5 border-b border-hair text-sm text-fg min-w-0";
    dd.appendChild(copyOf(cell));
    fields.append(dt, dd);
  });
  if (fields.children.length) frag.insertBefore(fields, header.nextSibling);
  return frag;
}

// Live markup copied out of the page: no ids, hooks or bindings may come along.
function copyOf(node) {
  const copy = document.createDocumentFragment();
  if (!node) return copy;
  [...node.childNodes].forEach((child) =>
    copy.appendChild(child.cloneNode(true))
  );
  copy.querySelectorAll("[id]").forEach((n) => n.removeAttribute("id"));
  copy
    .querySelectorAll("[phx-hook], [phx-click], [data-phx-link], a")
    .forEach((n) => {
      n.removeAttribute("phx-hook");
      n.removeAttribute("phx-click");
      n.removeAttribute("data-phx-link");
      n.removeAttribute("href");
    });
  return copy;
}

function hide() {
  pending = false;
  stopWatching();
  if (!root) return;
  root.classList.add("hidden");
  root.classList.remove("flex");
  root.replaceChildren();
}

function show(detail) {
  const el = container();
  const veil = document.createElement("div");
  veil.className = "absolute inset-0 bg-veil backdrop-blur-[1px]";
  veil.addEventListener("click", cancel);

  const dialog = document.createElement("div");
  dialog.setAttribute("role", "dialog");
  dialog.setAttribute("aria-busy", "true");
  dialog.className = [
    "relative flex flex-col w-full max-h-[90vh] overflow-hidden",
    "bg-bg text-fg border border-rule shadow-lg",
    SIZES[detail.size] || SIZES.lg,
  ].join(" ");

  const row = detail.from_row && detail.source;
  dialog.appendChild(
    row ? fromRow(row) : headerOnly(detail.title, detail.subtitle)
  );
  dialog
    .querySelectorAll("[data-instant-modal-close]")
    .forEach((close) => close.addEventListener("click", cancel));

  el.replaceChildren(veil, dialog);
  el.classList.remove("hidden");
  el.classList.add("flex");
  pending = true;
  watchForServerModal();
}

// Some buttons open a modal through an event that does not patch the URL, so
// the patch-finished signal never comes. Hide the preview as soon as the
// server renders a modal layer, and give up after a while either way.
let observer = null;
let timer = null;

function watchForServerModal() {
  const before = new Set(document.querySelectorAll("[data-modal-layer]"));
  stopWatching();
  observer = new MutationObserver(() => {
    const layers = document.querySelectorAll("[data-modal-layer]");
    for (const layer of layers) {
      if (!before.has(layer)) return hide();
    }
  });
  observer.observe(document.body, { childList: true, subtree: true });
  timer = setTimeout(hide, 10000);
}

function stopWatching() {
  if (observer) observer.disconnect();
  if (timer) clearTimeout(timer);
  observer = null;
  timer = null;
}

// Closing before the server answered: go back to the list the click came from.
function cancel() {
  if (!pending) return;
  hide();
  history.back();
}

window.addEventListener("fz:instant-modal", (e) => {
  show({ ...(e.detail || {}), source: e.target });
});

window.addEventListener("phx:page-loading-stop", (info) => {
  if (pending && info.detail && info.detail.kind === "patch") hide();
});

window.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && pending) cancel();
});

// A modal layer closed from the browser: hidden now, removed when the server
// renders. An inline style, so a server render that keeps it open shows it again.
window.addEventListener("fz:modal-hide", (e) => {
  if (e.target && e.target.style) e.target.style.display = "none";
});

// Patch links that open a modal can opt in with `data-instant-modal="Title"`
// (and `data-instant-modal-size`); LiveView still runs the patch itself.
document.addEventListener(
  "click",
  (e) => {
    const link = e.target.closest("a[data-instant-modal]");
    if (!link || e.defaultPrevented) return;
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey)
      return;
    show({
      title: link.dataset.instantModal,
      subtitle: link.dataset.instantModalSubtitle,
      size: link.dataset.instantModalSize,
    });
  },
  true
);
