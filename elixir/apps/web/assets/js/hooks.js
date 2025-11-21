import { initCopyClipboards, initTabs, Popover } from "flowbite";

let Hooks = {};

Hooks.Tabs = {
  mounted() {
    initTabs();
  },

  updated() {
    initTabs();
  },
};

Hooks.Analytics = {
  mounted() {
    this.handleEvent("identify", ({ id, account_id, name, email }) => {
      var mixpanel = window.mixpanel || null;
      if (mixpanel) {
        mixpanel.identify(id);
        mixpanel.people.set({
          $name: name,
          $email: email,
          account_id: account_id,
        });
        mixpanel.set_group("account", account_id);
      }

      var _hsq = window._hsq || null;
      if (_hsq) {
        _hsq.push(["identify", { id: id, email: email }]);
      }
    });

    this.handleEvent("track_event", ({ name, properties }) => {
      var mixpanel = window.mixpanel || null;
      if (mixpanel) {
        mixpanel.track(name, properties);
      }

      var _hsq = window._hsq || null;
      if (_hsq) {
        _hsq.push([
          "trackCustomBehavioralEvent",
          {
            name: name,
            properties: properties,
          },
        ]);
      }
    });
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
    this.focusedElement = document.activeElement
  },

  // When LiveView re-renders the modal, it closes, so we need to re-open it
  // and restore the focus state.
  updated() {
    if (!this.el.open) this.el.showModal();

    if (this.focusedElement) {
      this.focusedElement.focus()
    }
  }
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

    const placement = $triggerEl.getAttribute("data-popover-placement") || "top";
    const triggerType = $triggerEl.getAttribute("data-popover-trigger") || "hover";

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
      const button = $triggerEl.querySelector('button');
      if (button) {
        button.addEventListener('click', this.clickHandler);
      }
    }
  },

  updated() {
    // Clean up old event listeners and popover
    if (this.popover) {
      const $triggerEl = this.el;
      const triggerType = $triggerEl.getAttribute("data-popover-trigger") || "hover";

      if (triggerType === "click" && this.clickHandler) {
        const button = $triggerEl.querySelector('button');
        if (button) {
          button.removeEventListener('click', this.clickHandler);
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
      const triggerType = $triggerEl.getAttribute("data-popover-trigger") || "hover";

      if (triggerType === "click" && this.clickHandler) {
        const button = $triggerEl.querySelector('button');
        if (button) {
          button.removeEventListener('click', this.clickHandler);
        }
      }

      this.popover.hide();
      this.popover.destroyAndRemoveInstance();
    }
  }
};

Hooks.CopyClipboard = {
  mounted() {
    initCopyClipboards();

    const id = this.el.id;
    const clipboard = FlowbiteInstances.getInstance('CopyClipboard', `${id}-code`);

    const $defaultMessage = document.getElementById(`${id}-default-message`);
    const $successMessage = document.getElementById(`${id}-success-message`);

    clipboard.updateOnCopyCallback((clipboard) => {
        showSuccess();

        // reset to default state
        setTimeout(() => {
            resetToDefault();
        }, 2000);
    })

    const showSuccess = () => {
        $defaultMessage.classList.add('hidden');
        $successMessage.classList.remove('hidden');
    }

    const resetToDefault = () => {
        $defaultMessage.classList.remove('hidden');
        $successMessage.classList.add('hidden');
    }
  },

  updated() {
    this.mounted();
  }
};

Hooks.OpenURL = {
  mounted() {
    this.handleEvent("open_url", ({ url }) => {
      window.open(url, "_blank");
    });
  }
};

Hooks.FormatJSON = {
  mounted() {
    this.formatJSON();
  },

  updated() {
    this.formatJSON();
  },

  formatJSON() {
    const code = this.el.querySelector('code');
    if (code && code.textContent.trim()) {
      try {
        const json = JSON.parse(code.textContent);
        code.textContent = JSON.stringify(json, null, 2);
      } catch (e) {
        // If parsing fails, leave the content as is
      }
    }
  }
};

Hooks.Toast = {
  mounted() {
    const autoshow = this.el.dataset.autoshow !== "false";

    // Position the toast in the top-right corner with equal margins
    this.el.style.position = 'fixed';
    this.el.style.top = '1rem';
    this.el.style.right = '1rem';
    this.el.style.left = 'auto';
    this.el.style.margin = '0';
    this.el.style.maxWidth = '400px';
    this.el.style.minWidth = '300px';
    this.el.style.zIndex = '2147483647'; // Maximum z-index value to appear above everything

    // Add transition styles
    this.el.style.transition = 'transform 0.3s ease-out, opacity 0.3s ease-out';
    this.el.style.transform = 'translateX(calc(100% + 1rem))';
    this.el.style.opacity = '0';

    // Create and add progress bar
    const progressBar = document.createElement('div');
    progressBar.className = 'toast-progress';
    progressBar.style.position = 'absolute';
    progressBar.style.bottom = '0';
    progressBar.style.left = '0';
    progressBar.style.height = '3px';
    progressBar.style.width = '100%';
    progressBar.style.backgroundColor = 'currentColor';
    progressBar.style.opacity = '0.3';
    progressBar.style.transformOrigin = 'left';
    progressBar.style.transition = 'transform 5s linear';
    progressBar.style.transform = 'scaleX(1)';
    this.el.style.position = 'relative';
    this.el.appendChild(progressBar);
    this.progressBar = progressBar;

    if (autoshow) {
      // Auto-show the toast popover when mounted
      try {
        this.el.showPopover();

        // Slide in after a tiny delay to trigger the transition
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            this.el.style.transform = 'translateX(0)';
            this.el.style.opacity = '1';

            // Start progress bar animation
            requestAnimationFrame(() => {
              this.progressBar.style.transform = 'scaleX(0)';
            });
          });
        });
      } catch (error) {
        console.error("showPopover error:", error);
      }

      // Auto-hide after 5 seconds
      this.timeout = setTimeout(() => {
        if (this.el.matches(':popover-open')) {
          // Slide out before hiding
          this.el.style.transform = 'translateX(calc(100% + 1rem))';
          this.el.style.opacity = '0';

          setTimeout(() => {
            this.el.hidePopover();
          }, 300); // Wait for transition to complete
        }
      }, 5000);
    }
  },

  destroyed() {
    // Clear timeout on cleanup
    if (this.timeout) {
      clearTimeout(this.timeout);
    }
  }
};

export default Hooks;
