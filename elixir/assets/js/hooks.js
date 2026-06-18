import { Popover } from "./popover";

let Hooks = {};

/* The phx-disable-with attribute on submit buttons only applies to liveview forms.
 * However, we need to disable the submit button for regular forms as well to prevent
 * double submissions and cases where the submit handler is slow (e.g. constant-time auth).
 */
const handleDisableSubmit = (ev) => {
  let submit = ev.target.querySelector('[type="submit"]');
  submit.setAttribute("disabled", "disabled");
  submit.classList.add("cursor-wait");
  submit.classList.add("opacity-75");

  ev.target.submit();

  setTimeout(() => {
    submit.classList.remove("cursor-wait");
    submit.classList.remove("opacity-75");
    submit.removeAttribute("disabled");
  }, 5000);
};

Hooks.AttachDisableSubmit = {
  mounted() {
    this.el.addEventListener("form:disable_and_submit", handleDisableSubmit);
  },

  destroyed() {
    this.el.removeEventListener("form:disable_and_submit", handleDisableSubmit);
  },
};

Hooks.Modal = {
  mounted() {
    this.el.showModal();

    // Listen for the dialog close event
    this.el.addEventListener("close", () => {
      const onClose = this.el.getAttribute("phx-on-close");
      if (onClose) {
        this.pushEvent(onClose, {});
      }
    });
  },

  beforeUpdate() {
    this.focusedElement = document.activeElement;
  },

  // When LiveView re-renders the modal, it closes, so we need to re-open it
  // and restore the focus state.
  updated() {
    if (!this.el.open) this.el.showModal();

    if (this.focusedElement) {
      this.focusedElement.focus();
    }
  },
};

Hooks.ConfirmDialog = {
  mounted() {
    this.el.addEventListener("click", (ev) => {
      ev.stopPropagation();
      ev.preventDefault();

      let id = ev.currentTarget.getAttribute("id");
      let dialog_el = document.getElementById(id + "_dialog");
      dialog_el.returnValue = "cancel";
      dialog_el.close();
      dialog_el.showModal();

      let close_button = dialog_el.querySelector("[data-dialog-action=cancel]");
      close_button.focus();
    });
  },
};

Hooks.Popover = {
  mounted() {
    this.setupPopover();
  },

  // The `target_id` in the Elixir component is regenerated on every render, so
  // a LiveView patch that updates this hook's element in place would leave the
  // Popover instance pointing at a stale (now-removed) target node. Tear down
  // and rebuild on update so the references stay in sync with the DOM.
  updated() {
    this.popover?.destroy();
    this.setupPopover();
  },

  destroyed() {
    this.popover?.destroy();
  },

  setupPopover() {
    this.popover = new Popover(this.el, {
      target: this.el.getAttribute("data-popover-target-id"),
      placement: this.el.getAttribute("data-popover-placement") || "top",
      triggerType: this.el.getAttribute("data-popover-trigger") || "hover",
    });
  },
};

Hooks.CopyClipboard = {
  mounted() {
    this.setupCopyButton();
  },

  updated() {
    this.setupCopyButton();
  },

  setupCopyButton() {
    const id = this.el.id;
    const button = this.el.querySelector(
      "button[data-copy-to-clipboard-target]"
    );

    if (!button) return;

    // Remove any existing listeners to prevent duplicates
    if (this.clickHandler) {
      button.removeEventListener("click", this.clickHandler, { capture: true });
    }

    const targetId = button.getAttribute("data-copy-to-clipboard-target");
    const $defaultMessage = document.getElementById(`${id}-default-message`);
    const $successMessage = document.getElementById(`${id}-success-message`);

    this.clickHandler = (e) => {
      e.preventDefault();
      e.stopPropagation();

      const targetEl = document.getElementById(targetId);
      if (!targetEl) return;

      const textToCopy = (targetEl.innerText || targetEl.textContent).trim();

      navigator.clipboard
        .writeText(textToCopy)
        .then(() => {
          // Show success state
          if ($defaultMessage) {
            $defaultMessage.classList.add("hidden");
            $defaultMessage.classList.remove("inline-flex");
          }
          if ($successMessage) {
            $successMessage.classList.remove("hidden");
            $successMessage.classList.add("inline-flex");
          }

          // Reset after 2 seconds
          setTimeout(() => {
            if ($defaultMessage) {
              $defaultMessage.classList.remove("hidden");
              $defaultMessage.classList.add("inline-flex");
            }
            if ($successMessage) {
              $successMessage.classList.remove("inline-flex");
              $successMessage.classList.add("hidden");
            }
          }, 2000);
        })
        .catch((err) => {
          console.error("Failed to copy:", err);
        });
    };

    button.addEventListener("click", this.clickHandler, { capture: true });
  },

  destroyed() {
    const button = this.el.querySelector(
      "button[data-copy-to-clipboard-target]"
    );
    if (button && this.clickHandler) {
      button.removeEventListener("click", this.clickHandler, { capture: true });
    }
  },
};

Hooks.OpenURL = {
  mounted() {
    this.handleEvent("open_url", ({ url }) => {
      window.open(url, "_blank", "noopener,noreferrer");
    });
  },
};

Hooks.FormatJSON = {
  mounted() {
    this.formatJSON();
  },

  updated() {
    this.formatJSON();
  },

  formatJSON() {
    const code = this.el.querySelector("code");
    if (code && code.textContent.trim()) {
      try {
        const json = JSON.parse(code.textContent);
        code.textContent = JSON.stringify(json, null, 2);
      } catch (e) {
        // If parsing fails, leave the content as is
      }
    }
  },
};

Hooks.Toast = {
  mounted() {
    this.flashKey = this.el.className.match(/flash-(\w+)/)?.[1];
    this.lastContent = this.el.textContent;

    this.applyBaseStyles();
    this.resetPosition();
    this.ensureProgressBar();

    // Add click handler to clear flash
    const closeButton = this.el.querySelector(
      'button[popovertargetaction="hide"]'
    );
    if (closeButton && this.flashKey) {
      closeButton.addEventListener("click", () => {
        this.pushEvent("lv:clear-flash", { key: this.flashKey });
      });
    }

    if (this.shouldAutoShow()) {
      this.show();
    }
  },

  updated() {
    this.applyBaseStyles();

    // Only re-show if content actually changed and autoshow is enabled
    const currentContent = this.el.textContent;
    if (currentContent !== this.lastContent && this.shouldAutoShow()) {
      this.lastContent = currentContent;
      this.clearTimeout();
      this.resetPosition();
      this.ensureProgressBar();
      this.resetProgressBar();
      this.show();
    }
  },

  destroyed() {
    this.clearTimeout();
  },

  // Helpers
  applyBaseStyles() {
    Object.assign(this.el.style, {
      position: "fixed",
      top: "1rem",
      right: "1rem",
      left: "auto",
      margin: "0",
      maxWidth: "400px",
      minWidth: "300px",
      zIndex: "2147483647",
      transition: "transform 0.3s ease-out, opacity 0.3s ease-out",
    });
  },

  shouldAutoShow() {
    return this.el.dataset.autoshow !== "false";
  },

  resetPosition() {
    this.el.style.transform = "translateX(calc(100% + 1rem))";
    this.el.style.opacity = "0";
  },

  ensureProgressBar() {
    if (this.progressBar && this.el.contains(this.progressBar)) return;

    const bar = document.createElement("div");
    Object.assign(bar.style, {
      position: "absolute",
      bottom: "0",
      left: "0",
      height: "3px",
      width: "100%",
      backgroundColor: "currentColor",
      opacity: "0.3",
      transformOrigin: "left",
      transition: "transform 5s linear",
      transform: "scaleX(1)",
    });
    this.el.appendChild(bar);
    this.progressBar = bar;
  },

  resetProgressBar() {
    if (!this.progressBar) return;
    this.progressBar.style.transition = "none";
    this.progressBar.style.transform = "scaleX(1)";
  },

  show() {
    try {
      if (!this.el.matches(":popover-open")) {
        this.el.showPopover();
      }

      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          this.el.style.transform = "translateX(0)";
          this.el.style.opacity = "1";

          if (this.progressBar) {
            this.progressBar.style.transition = "transform 5s linear";
            requestAnimationFrame(() => {
              this.progressBar.style.transform = "scaleX(0)";
            });
          }
        });
      });
    } catch (error) {
      console.error("showPopover error:", error);
    }

    this.scheduleHide();
  },

  scheduleHide() {
    this.clearTimeout();
    this.timeout = setTimeout(() => {
      if (!this.el.matches(":popover-open")) return;

      this.el.style.transform = "translateX(calc(100% + 1rem))";
      this.el.style.opacity = "0";

      setTimeout(() => {
        this.el.hidePopover();
        if (this.flashKey) {
          this.pushEvent("lv:clear-flash", { key: this.flashKey });
        }
      }, 300);
    }, 5000);
  },

  clearTimeout() {
    if (this.timeout) {
      clearTimeout(this.timeout);
      this.timeout = null;
    }
  },
};

Hooks.CloseWindow = {
  mounted() {
    const parsed = parseInt(this.el.dataset.seconds, 10);
    const seconds = Number.isNaN(parsed) ? 5 : parsed;

    this.timer = setTimeout(() => {
      window.close();
    }, seconds * 1000);
  },
  destroyed() {
    if (this.timer) clearTimeout(this.timer);
  },
};

Hooks.PINInput = {
  mounted() {
    const inputs = Array.from(
      this.el.querySelectorAll("input[data-pin-index]")
    ).sort(
      (a, b) =>
        parseInt(a.dataset.pinIndex, 10) - parseInt(b.dataset.pinIndex, 10)
    );
    const hidden = document.getElementById("secret");

    const update = () => {
      hidden.value = inputs.map((i) => i.value).join("");
    };

    inputs.forEach((input, idx) => {
      input.addEventListener("input", (e) => {
        const val = e.target.value.toLowerCase().replace(/[^a-z0-9]/g, "");
        input.value = val ? val[val.length - 1] : "";
        update();
        if (input.value && idx < inputs.length - 1) {
          inputs[idx + 1].focus();
        }
      });

      input.addEventListener("keydown", (e) => {
        if (e.key === "Backspace") {
          if (!input.value && idx > 0) {
            inputs[idx - 1].value = "";
            inputs[idx - 1].focus();
            update();
          }
        } else if (e.key === "Enter") {
          const allFilled = inputs.every((i) => i.value);
          if (allFilled) {
            update();
            const form = this.el.closest("form");
            if (form)
              form.dispatchEvent(
                new Event("submit", { bubbles: true, cancelable: true })
              );
          }
        }
      });

      input.addEventListener("paste", (e) => {
        e.preventDefault();
        const text = (e.clipboardData || window.clipboardData)
          .getData("text")
          .toLowerCase()
          .replace(/[^a-z0-9]/g, "");
        text.split("").forEach((char, i) => {
          if (idx + i < inputs.length) {
            inputs[idx + i].value = char;
          }
        });
        update();
        const nextEmpty = inputs.findIndex((i) => !i.value);
        (nextEmpty === -1
          ? inputs[inputs.length - 1]
          : inputs[nextEmpty]
        ).focus();
      });
    });
  },
};

Hooks.ProgressBar = {
  mounted() {
    this.update();
  },
  updated() {
    this.update();
  },
  update() {
    const parsed = parseFloat(this.el.dataset.pct);
    const pct = Number.isFinite(parsed)
      ? Math.min(100, Math.max(0, parsed))
      : 0;
    this.el.style.width = `${pct}%`;
  },
};

Hooks.ColorEditor = {
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
        navigator.clipboard.writeText(raw).then(() => {
          copyBtn.textContent = "Copied!";
          setTimeout(() => (copyBtn.textContent = "Copy"), 1500);
        });
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

    // Update gradient previews for L, C, H sliders
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

export default Hooks;
