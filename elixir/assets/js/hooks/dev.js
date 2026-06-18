const ColorEditor = {
  mounted() {
    this._cssVar = this.el.dataset.cssVar;
    this._bindSliders();
    this._readAndPopulate();
  },

  updated() {
    const newVar = this.el.dataset.cssVar;
    if (newVar !== this._cssVar) {
      this._cssVar = newVar;
      this._readAndPopulate();
    }
  },

  destroyed() {
    // Restore the currently edited CSS vars when the editor is dismissed
    if (this._cssVar) {
      document.documentElement.style.removeProperty(this._cssVar);
    }
  },

  _readAndPopulate() {
    const raw = getComputedStyle(document.documentElement)
      .getPropertyValue(this._cssVar)
      .trim();

    const parsed = this._parseOklch(raw);
    if (!parsed) return;

    this._setSlider("l", parsed.l);
    this._setSlider("c", parsed.c);
    this._setSlider("h", parsed.h);
    this._setSlider("a", parsed.a ?? 100);
    this._updateDisplay();
  },

  _parseOklch(raw) {
    // Handle oklch(L% C H) and oklch(L% C H / A%) / oklch(L C H / A%)
    const m = raw.match(
      /oklch\(\s*([0-9.]+)%?\s+([0-9.]+)\s+([0-9.]+)(?:\s*\/\s*([0-9.]+)%?)?\s*\)/
    );
    if (!m) return null;
    return {
      l: parseFloat(m[1]),
      c: parseFloat(m[2]),
      h: parseFloat(m[3]),
      a: m[4] !== undefined ? parseFloat(m[4]) : 100,
    };
  },

  _buildOklch(l, c, h, a) {
    const lStr = parseFloat(l).toFixed(2);
    const cStr = parseFloat(c).toFixed(4);
    const hStr = parseFloat(h).toFixed(2);
    if (parseFloat(a) < 99.9) {
      return `oklch(${lStr}% ${cStr} ${hStr} / ${parseFloat(a).toFixed(1)}%)`;
    }
    return `oklch(${lStr}% ${cStr} ${hStr})`;
  },

  _setSlider(name, value) {
    const el = this.el.querySelector(`[data-channel="${name}"]`);
    if (el) el.value = value;
  },

  _getSlider(name) {
    const el = this.el.querySelector(`[data-channel="${name}"]`);
    return el ? parseFloat(el.value) : 0;
  },

  _bindSliders() {
    this.el.querySelectorAll("[data-channel]").forEach((el) => {
      el.addEventListener("input", () => {
        this._applyColor();
        this._updateDisplay();
      });
    });

    const copyBtn = this.el.querySelector("[data-copy-value]");
    if (copyBtn) {
      copyBtn.addEventListener("click", () => {
        const raw =
          this.el.querySelector("[data-raw-value]")?.textContent ?? "";
        if (!navigator.clipboard) return;
        navigator.clipboard.writeText(raw).then(
          () => {
            copyBtn.textContent = "Copied!";
            setTimeout(() => (copyBtn.textContent = "Copy"), 1500);
          },
          () => {}
        );
      });
    }

    const resetBtn = this.el.querySelector("[data-reset]");
    if (resetBtn) {
      resetBtn.addEventListener("click", () => {
        document.documentElement.style.removeProperty(this._cssVar);
        this._readAndPopulate();
      });
    }
  },

  _applyColor() {
    const value = this._buildOklch(
      this._getSlider("l"),
      this._getSlider("c"),
      this._getSlider("h"),
      this._getSlider("a")
    );
    document.documentElement.style.setProperty(this._cssVar, value);
  },

  _updateDisplay() {
    const value = this._buildOklch(
      this._getSlider("l"),
      this._getSlider("c"),
      this._getSlider("h"),
      this._getSlider("a")
    );
    const el = this.el.querySelector("[data-raw-value]");
    if (el) el.textContent = value;

    this._updateGradients();
  },

  _updateGradients() {
    const l = this._getSlider("l");
    const c = this._getSlider("c");
    const h = this._getSlider("h");

    const lTrack = this.el.querySelector("[data-gradient='l']");
    if (lTrack) {
      lTrack.style.background = `linear-gradient(to right,
        oklch(0% ${c} ${h}),
        oklch(50% ${c} ${h}),
        oklch(100% ${c} ${h}))`;
    }

    const cTrack = this.el.querySelector("[data-gradient='c']");
    if (cTrack) {
      cTrack.style.background = `linear-gradient(to right,
        oklch(${l}% 0 ${h}),
        oklch(${l}% 0.2 ${h}),
        oklch(${l}% 0.4 ${h}))`;
    }

    const hTrack = this.el.querySelector("[data-gradient='h']");
    if (hTrack) {
      hTrack.style.background = `linear-gradient(to right,
        oklch(${l}% ${c} 0),
        oklch(${l}% ${c} 60),
        oklch(${l}% ${c} 120),
        oklch(${l}% ${c} 180),
        oklch(${l}% ${c} 240),
        oklch(${l}% ${c} 300),
        oklch(${l}% ${c} 360))`;
    }
  },
};

export default { ColorEditor };
