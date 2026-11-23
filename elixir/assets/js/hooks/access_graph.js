// The access map: hover a node to trace everything it reaches and everything
// that reaches it; the pinned node (data-pinned) stays traced and outlined.
//
// The map pans and zooms by moving the SVG viewBox:
//   - drag, scroll, or the arrow keys (Shift for bigger steps) move it,
//   - Ctrl or Cmd + scroll (and trackpad pinch), +/- keys and the buttons zoom,
//   - 0 fits the whole map, 1 goes back to actual size at the top.
//   - a new map (a search) starts again from that home view.
// 100% means one SVG unit per CSS pixel.

const MAX_SCALE = 4;
const KEY_STEP = 60;
const DRAG_THRESHOLD = 4;

export const AccessGraph = {
  mounted() {
    this.viewport =
      this.el.closest("#access-graph-viewport") || this.el.parentElement;
    this.scaleLabel = this.viewport.querySelector("[data-graph-scale]");
    this.frame = null;

    this.indexGraph();
    this.home();

    this.onOver = (event) => {
      if (this.drag && this.drag.moved) return;
      const node = event.target.closest("g[data-node]");
      this.trace(node ? node.dataset.node : this.el.dataset.pinned);
    };
    this.onLeave = () => this.trace(this.el.dataset.pinned);
    this.onWheel = (event) => this.wheel(event);
    this.onKey = (event) => this.key(event);
    this.onDown = (event) => this.pointerDown(event);
    this.onMove = (event) => this.pointerMove(event);
    this.onUp = (event) => this.pointerUp(event);
    // A drag must not also pin the node it started on.
    this.onClickCapture = (event) => {
      if (this.suppressClick) {
        event.stopPropagation();
        event.preventDefault();
        this.suppressClick = false;
      }
    };
    this.onButton = (event) => {
      const button = event.target.closest("[data-graph-zoom]");
      if (!button) return;
      const action = button.dataset.graphZoom;
      if (action === "in") this.zoomBy(1.25);
      if (action === "out") this.zoomBy(0.8);
      if (action === "fit") this.fit();
      if (action === "reset") this.actualSize();
    };

    this.el.addEventListener("mouseover", this.onOver);
    this.el.addEventListener("mouseleave", this.onLeave);
    this.el.addEventListener("pointerdown", this.onDown);
    this.el.addEventListener("pointermove", this.onMove);
    this.el.addEventListener("pointerup", this.onUp);
    this.el.addEventListener("pointercancel", this.onUp);
    this.el.addEventListener("click", this.onClickCapture, true);
    this.viewport.addEventListener("wheel", this.onWheel, { passive: false });
    this.viewport.addEventListener("keydown", this.onKey);
    this.viewport.addEventListener("click", this.onButton);

    this.resizeObserver = new ResizeObserver(() => this.apply());
    this.resizeObserver.observe(this.viewport);

    this.trace(this.el.dataset.pinned);
  },

  updated() {
    // A server render puts back the original viewBox; keep the view unless the
    // map itself changed (a new search), which starts again from the top.
    const size = `${this.el.dataset.width}x${this.el.dataset.height}`;
    this.indexGraph();
    if (size !== this.size) {
      this.home();
    } else {
      this.apply();
    }
    this.trace(this.el.dataset.pinned);
  },

  destroyed() {
    this.viewport.removeEventListener("wheel", this.onWheel);
    this.viewport.removeEventListener("keydown", this.onKey);
    this.viewport.removeEventListener("click", this.onButton);
    if (this.resizeObserver) this.resizeObserver.disconnect();
    if (this.frame) cancelAnimationFrame(this.frame);
  },

  // ── View ────────────────────────────────────────────────────────────────

  content() {
    return {
      w: Number(this.el.dataset.width) || 1,
      h: Number(this.el.dataset.height) || 1,
    };
  },

  box() {
    const rect = this.el.getBoundingClientRect();
    return { w: rect.width || 1, h: rect.height || 1 };
  },

  fitScale() {
    const box = this.box();
    const content = this.content();
    return Math.min(box.w / content.w, box.h / content.h);
  },

  minScale() {
    return Math.min(this.fitScale() * 0.5, 1);
  },

  clampScale(scale) {
    return Math.min(MAX_SCALE, Math.max(this.minScale(), scale));
  },

  // Small maps open at actual size; larger ones open fitted so the whole shape shows.
  home() {
    const content = this.content();
    this.size = `${content.w}x${content.h}`;
    if (this.fitScale() < 1) {
      this.fit();
    } else {
      this.actualSize();
    }
  },

  fit() {
    const box = this.box();
    const content = this.content();
    const scale = this.clampScale(this.fitScale());
    this.view = {
      scale,
      x: (content.w - box.w / scale) / 2,
      y: (content.h - box.h / scale) / 2,
    };
    this.apply();
  },

  actualSize() {
    this.view = { x: 0, y: 0, scale: 1 };
    this.apply();
  },

  // Zoom keeping the SVG point under (clientX, clientY) still.
  zoomBy(factor, clientX, clientY) {
    const rect = this.el.getBoundingClientRect();
    const px = clientX === undefined ? rect.width / 2 : clientX - rect.left;
    const py = clientY === undefined ? rect.height / 2 : clientY - rect.top;
    const { x, y, scale } = this.view;
    const next = this.clampScale(scale * factor);
    this.view = {
      scale: next,
      x: x + px / scale - px / next,
      y: y + py / scale - py / next,
    };
    this.apply();
  },

  panBy(dxPixels, dyPixels) {
    this.view.x += dxPixels / this.view.scale;
    this.view.y += dyPixels / this.view.scale;
    this.apply();
  },

  // Keep at least a quarter of the viewport over the map.
  clampView() {
    const box = this.box();
    const content = this.content();
    const w = box.w / this.view.scale;
    const h = box.h / this.view.scale;
    const clamp = (value, size, span) => {
      const margin = span * 0.75;
      const lo = Math.min(0, size - span) - margin;
      const hi = Math.max(0, size - span) + margin;
      return Math.min(hi, Math.max(lo, value));
    };
    this.view.x = clamp(this.view.x, content.w, w);
    this.view.y = clamp(this.view.y, content.h, h);
    return { w, h };
  },

  apply() {
    if (!this.view) return;
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      const { w, h } = this.clampView();
      const { x, y, scale } = this.view;
      this.el.setAttribute("viewBox", `${x} ${y} ${w} ${h}`);
      if (this.scaleLabel)
        this.scaleLabel.textContent = `${Math.round(scale * 100)}%`;
    });
  },

  // ── Input ───────────────────────────────────────────────────────────────

  wheel(event) {
    event.preventDefault();
    if (event.ctrlKey || event.metaKey) {
      // Pixel deltas from wheels and trackpad pinches vary a lot; keep steps gentle.
      const delta = event.deltaMode === 1 ? event.deltaY * 16 : event.deltaY;
      this.zoomBy(Math.exp(-delta * 0.0025), event.clientX, event.clientY);
    } else if (event.shiftKey && event.deltaX === 0) {
      this.panBy(event.deltaY, 0);
    } else {
      const unit = event.deltaMode === 1 ? 16 : 1;
      this.panBy(event.deltaX * unit, event.deltaY * unit);
    }
  },

  key(event) {
    if (event.target.closest("input, textarea, select")) return;
    const step = event.shiftKey ? KEY_STEP * 4 : KEY_STEP;
    const actions = {
      "+": () => this.zoomBy(1.25),
      "=": () => this.zoomBy(1.25),
      "-": () => this.zoomBy(0.8),
      _: () => this.zoomBy(0.8),
      0: () => this.fit(),
      1: () => this.actualSize(),
      ArrowLeft: () => this.panBy(-step, 0),
      ArrowRight: () => this.panBy(step, 0),
      ArrowUp: () => this.panBy(0, -step),
      ArrowDown: () => this.panBy(0, step),
    };
    const action = actions[event.key];
    if (!action || event.altKey || event.ctrlKey || event.metaKey) return;
    event.preventDefault();
    action();
  },

  pointerDown(event) {
    if (event.button !== 0) return;
    this.viewport.focus({ preventScroll: true });
    this.drag = {
      x: event.clientX,
      y: event.clientY,
      moved: false,
      id: event.pointerId,
    };
  },

  pointerMove(event) {
    if (!this.drag || event.pointerId !== this.drag.id) return;
    const dx = event.clientX - this.drag.x;
    const dy = event.clientY - this.drag.y;
    if (!this.drag.moved && Math.hypot(dx, dy) < DRAG_THRESHOLD) return;
    if (!this.drag.moved) {
      this.drag.moved = true;
      this.el.setPointerCapture(event.pointerId);
    }
    this.drag.x = event.clientX;
    this.drag.y = event.clientY;
    this.panBy(-dx, -dy);
  },

  pointerUp(event) {
    if (!this.drag || event.pointerId !== this.drag.id) return;
    if (this.drag.moved) {
      this.suppressClick = true;
      setTimeout(() => (this.suppressClick = false), 0);
      if (this.el.hasPointerCapture(event.pointerId))
        this.el.releasePointerCapture(event.pointerId);
    }
    this.drag = null;
  },

  // ── Tracing ─────────────────────────────────────────────────────────────

  indexGraph() {
    this.paths = Array.from(this.el.querySelectorAll("path[data-from]"));
    this.nodes = Array.from(this.el.querySelectorAll("g[data-node]"));
    this.down = new Map();
    this.up = new Map();
    const add = (map, key, value) => {
      if (!map.has(key)) map.set(key, []);
      map.get(key).push(value);
    };
    this.paths.forEach((path) => {
      add(this.down, path.dataset.from, path.dataset.to);
      add(this.up, path.dataset.to, path.dataset.from);
    });
    this.traced = undefined;
  },

  walk(adjacency, start) {
    const seen = new Set([start]);
    const queue = [start];
    while (queue.length) {
      const id = queue.pop();
      (adjacency.get(id) || []).forEach((next) => {
        if (!seen.has(next)) {
          seen.add(next);
          queue.push(next);
        }
      });
    }
    return seen;
  },

  trace(id) {
    const pinned = this.el.dataset.pinned;
    this.nodes.forEach((node) => {
      const rect = node.querySelector("rect");
      if (rect)
        rect.setAttribute(
          "stroke-width",
          node.dataset.node === pinned ? "2.5" : "1"
        );
    });

    const known =
      id &&
      this.down &&
      (this.down.has(id) ||
        this.up.has(id) ||
        this.nodes.some((n) => n.dataset.node === id));
    const key = known ? id : null;
    if (key === this.traced) return;
    this.traced = key;

    if (!key) {
      this.nodes.forEach((node) => (node.style.opacity = ""));
      this.paths.forEach((path) => {
        path.style.opacity = "";
        path.style.stroke = "";
        path.style.strokeWidth = "";
      });
      return;
    }

    const down = this.walk(this.down, key);
    const up = this.walk(this.up, key);
    const lit = (node) => down.has(node) || up.has(node);

    this.nodes.forEach((node) => {
      node.style.opacity = lit(node.dataset.node) ? "1" : "0.22";
    });

    this.paths.forEach((path) => {
      const on =
        (down.has(path.dataset.from) && down.has(path.dataset.to)) ||
        (up.has(path.dataset.from) && up.has(path.dataset.to));
      path.style.opacity = on ? "1" : "0.1";
      path.style.stroke = on ? "var(--fg)" : "";
      path.style.strokeWidth = on ? "1.6" : "";
    });
  },
};
