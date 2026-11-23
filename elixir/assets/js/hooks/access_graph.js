// Hover a node on the access map to trace everything it reaches and
// everything that reaches it. The pinned node (data-pinned) stays traced
// when the pointer leaves.
export const AccessGraph = {
  mounted() {
    this.onOver = (event) => {
      const node = event.target.closest("g[data-node]");
      this.trace(node ? node.dataset.node : this.el.dataset.pinned);
    };
    this.onLeave = () => this.trace(this.el.dataset.pinned);
    this.el.addEventListener("mouseover", this.onOver);
    this.el.addEventListener("mouseleave", this.onLeave);
    this.trace(this.el.dataset.pinned);
  },

  updated() {
    this.trace(this.el.dataset.pinned);
  },

  destroyed() {
    this.el.removeEventListener("mouseover", this.onOver);
    this.el.removeEventListener("mouseleave", this.onLeave);
  },

  walk(paths, start, from, to) {
    const seen = new Set([start]);
    const queue = [start];
    while (queue.length) {
      const id = queue.pop();
      paths.forEach((path) => {
        if (path.dataset[from] !== id) return;
        const next = path.dataset[to];
        if (!seen.has(next)) {
          seen.add(next);
          queue.push(next);
        }
      });
    }
    return seen;
  },

  trace(id) {
    const paths = Array.from(this.el.querySelectorAll("path[data-from]"));
    const nodes = Array.from(this.el.querySelectorAll("g[data-node]"));

    if (!id || !nodes.some((node) => node.dataset.node === id)) {
      nodes.forEach((node) => (node.style.opacity = ""));
      paths.forEach((path) => {
        path.style.opacity = "";
        path.style.stroke = "";
        path.style.strokeWidth = "";
      });
      return;
    }

    const down = this.walk(paths, id, "from", "to");
    const up = this.walk(paths, id, "to", "from");
    const lit = (node) => down.has(node) || up.has(node);

    nodes.forEach((node) => {
      node.style.opacity = lit(node.dataset.node) ? "1" : "0.22";
    });

    paths.forEach((path) => {
      const on =
        (down.has(path.dataset.from) && down.has(path.dataset.to)) ||
        (up.has(path.dataset.from) && up.has(path.dataset.to));
      path.style.opacity = on ? "1" : "0.1";
      path.style.stroke = on ? "var(--fg)" : "";
      path.style.strokeWidth = on ? "1.6" : "";
    });
  },
};
