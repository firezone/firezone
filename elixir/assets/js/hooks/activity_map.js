// Draws new connections on the Activity map: an arc from the device to the
// gateway with a short pulse at both ends. The land dots are server-rendered;
// this hook only adds and removes the transient marks.
const SVG_NS = "http://www.w3.org/2000/svg";
const MAX_ENDPOINTS = 600;
const MAX_ARCS = 80;

export const ActivityMap = {
  mounted() {
    this.endpoints = this.el.querySelector("[data-endpoints]");
    this.arcs = this.el.querySelector("[data-arcs]");
    this.seen = new Set();
    this.timers = new Set();
    this.motion = window.matchMedia("(prefers-reduced-motion: reduce)");

    this.handleEvent("activity-map:connections", ({ connections, animate }) => {
      connections.forEach((connection, index) => {
        const delay = animate ? Math.min(index * 90, 2000) : 0;
        this.later(() => this.draw(connection, animate), delay);
      });
    });
  },

  destroyed() {
    this.timers.forEach((timer) => clearTimeout(timer));
    this.timers.clear();
  },

  later(fun, delay) {
    const timer = setTimeout(() => {
      this.timers.delete(timer);
      fun();
    }, delay);
    this.timers.add(timer);
  },

  draw({ from, to }, animate) {
    const still = !animate || this.motion.matches;

    [from, to].forEach((point) => point && this.endpoint(point));

    if (from && to) this.arc(from, to, still);

    if (animate) {
      [from, to].forEach((point) => point && this.pulse(point, still));
    }
  },

  endpoint([x, y]) {
    const key = `${x},${y}`;
    if (this.seen.has(key) || this.seen.size >= MAX_ENDPOINTS) return;
    this.seen.add(key);

    const dot = el("circle", { cx: x, cy: y, r: 0.55 });
    dot.style.fill = "currentColor";
    dot.style.opacity = "0.7";
    this.endpoints.appendChild(dot);
  },

  arc([x1, y1], [x2, y2], still) {
    while (this.arcs.childElementCount >= MAX_ARCS) {
      this.arcs.firstElementChild.remove();
    }

    const distance = Math.hypot(x2 - x1, y2 - y1);
    const lift = Math.min(distance * 0.35, 30);
    const cx = (x1 + x2) / 2;
    const cy = (y1 + y2) / 2 - lift;
    const path = el("path", {
      d: `M${x1} ${y1}Q${cx} ${cy} ${x2} ${y2}`,
      fill: "none",
      "stroke-width": 0.35,
      "stroke-linecap": "round",
    });
    path.style.stroke = "currentColor";
    path.style.opacity = still ? "0.35" : "0.8";
    this.arcs.appendChild(path);

    if (still) {
      this.later(() => path.remove(), 8000);
      return;
    }

    const length = path.getTotalLength ? path.getTotalLength() : distance;
    path.style.strokeDasharray = `${length}`;
    path.animate([{ strokeDashoffset: length }, { strokeDashoffset: 0 }], {
      duration: 700,
      easing: "ease-out",
      fill: "forwards",
    });
    path
      .animate([{ opacity: 0.8 }, { opacity: 0 }], {
        duration: 5000,
        delay: 2500,
        easing: "ease-in",
        fill: "forwards",
      })
      .finished.then(() => path.remove())
      .catch(() => path.remove());
  },

  pulse([x, y], still) {
    const ring = el("circle", {
      cx: x,
      cy: y,
      r: still ? 1.4 : 4.5,
      fill: "none",
      "vector-effect": "non-scaling-stroke",
    });
    ring.style.stroke = "var(--attn)";
    ring.style.strokeWidth = "1.5px";
    ring.style.transformBox = "fill-box";
    ring.style.transformOrigin = "center";
    this.arcs.appendChild(ring);

    if (still) {
      this.later(() => ring.remove(), 1500);
      return;
    }

    ring
      .animate(
        [
          { transform: "scale(0.12)", opacity: 1 },
          { transform: "scale(1)", opacity: 0 },
        ],
        { duration: 1400, iterations: 2, easing: "ease-out", fill: "forwards" }
      )
      .finished.then(() => ring.remove())
      .catch(() => ring.remove());
  },
};

function el(name, attributes) {
  const node = document.createElementNS(SVG_NS, name);
  Object.entries(attributes).forEach(([key, value]) =>
    node.setAttribute(key, value)
  );
  return node;
}
