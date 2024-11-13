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

Hooks.Refocus = {
  mounted() {
    this.el.addEventListener("click", (ev) => {
      ev.preventDefault();
      let target_id = ev.currentTarget.getAttribute("data-refocus");
      let el = document.getElementById(target_id);
      if (document.activeElement === el) return;
      el.focus();
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

    const options = {
      placement: "top",
      triggerType: "hover",
      offset: 5,
    };

    new Popover($targetEl, $triggerEl, options);
  },
};

export default Hooks;
