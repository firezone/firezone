import { initTabs, Popover } from "flowbite";

let Hooks = {};

Hooks.Tabs = {
  mounted() {
    initTabs();
  },

  updated() {
    initTabs();
  },
};

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
    const $triggerEl = this.el;
    const $targetEl = document.getElementById(
      $triggerEl.getAttribute("data-popover-target-id")
    );

    const placement =
      $triggerEl.getAttribute("data-popover-placement") || "top";
    const triggerType =
      $triggerEl.getAttribute("data-popover-trigger") || "hover";

    const options = {
      placement: placement,
      triggerType: triggerType,
      offset: 5,
    };

    // Store the popover instance so it can be cleaned up later
    this.popover = new Popover($targetEl, $triggerEl, options);

    // For click trigger type, manually handle toggle to ensure it works properly
    if (triggerType === "click") {
      this.clickHandler = (e) => {
        e.preventDefault();
        e.stopPropagation();
        this.popover.toggle();
      };

      // Find the actual button element inside the trigger
      const button = $triggerEl.querySelector("button");
      if (button) {
        button.addEventListener("click", this.clickHandler);
      }
    }
  },

  updated() {
    // Clean up old event listeners and popover
    if (this.popover) {
      const $triggerEl = this.el;
      const triggerType =
        $triggerEl.getAttribute("data-popover-trigger") || "hover";

      if (triggerType === "click" && this.clickHandler) {
        const button = $triggerEl.querySelector("button");
        if (button) {
          button.removeEventListener("click", this.clickHandler);
        }
      }

      this.popover.hide();
      this.popover.destroyAndRemoveInstance();
    }

    // Recreate the popover with updated DOM
    this.mounted();
  },

  destroyed() {
    // Clean up event listeners and popover instance
    if (this.popover) {
      const $triggerEl = this.el;
      const triggerType =
        $triggerEl.getAttribute("data-popover-trigger") || "hover";

      if (triggerType === "click" && this.clickHandler) {
        const button = $triggerEl.querySelector("button");
        if (button) {
          button.removeEventListener("click", this.clickHandler);
        }
      }

      this.popover.hide();
      this.popover.destroyAndRemoveInstance();
    }
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
          if ($defaultMessage) $defaultMessage.classList.add("hidden");
          if ($successMessage) $successMessage.classList.remove("hidden");

          // Reset after 2 seconds
          setTimeout(() => {
            if ($defaultMessage) $defaultMessage.classList.remove("hidden");
            if ($successMessage) $successMessage.classList.add("hidden");
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
      window.open(url, "_blank");
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
    const seconds = parseInt(this.el.dataset.seconds) || 5;

    this.timer = setTimeout(() => {
      window.close();
    }, seconds * 1000);
  },
  destroyed() {
    if (this.timer) clearTimeout(this.timer);
  }
};

export default Hooks;
