const SCRIPT_SRC =
  "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";

let scriptPromise = null;

function loadScript() {
  if (window.turnstile) return Promise.resolve(window.turnstile);

  scriptPromise ||= new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = SCRIPT_SRC;
    script.async = true;
    script.onload = () => resolve(window.turnstile);
    script.onerror = () => {
      scriptPromise = null;
      reject(new Error("Turnstile failed to load"));
    };
    document.head.appendChild(script);
  });

  return scriptPromise;
}

// Renders one Turnstile widget and copies its token into every
// `input[data-turnstile-token]` on the page. Tokens are single use, so the
// server asks for a reset after it consumes one. When the script cannot load,
// or the widget cannot run, the hook shows the `[data-turnstile-error]` element.
export const Turnstile = {
  mounted() {
    this.widgetId = null;
    this.removed = false;
    this.target = this.el.querySelector("[data-turnstile-widget]");
    this.errorEl = this.el.querySelector("[data-turnstile-error]");

    this.handleEvent("turnstile:reset", () => {
      this.fill("");
      if (this.widgetId !== null) window.turnstile.reset(this.widgetId);
    });

    loadScript()
      .then((turnstile) => {
        if (this.removed) return;

        this.widgetId = turnstile.render(this.target, {
          sitekey: this.el.dataset.sitekey,
          theme: "auto",
          // The hidden inputs rendered by the server carry the token.
          "response-field": false,
          callback: (token) => this.fill(token),
          "expired-callback": () => this.fill(""),
          "error-callback": () => this.fail(),
          "unsupported-callback": () => this.fail(),
        });
      })
      .catch(() => this.fail());
  },

  destroyed() {
    this.removed = true;
    if (this.widgetId !== null && window.turnstile) {
      window.turnstile.remove(this.widgetId);
    }
  },

  fill(token) {
    if (token !== "") this.showError(false);

    document
      .querySelectorAll("input[data-turnstile-token]")
      .forEach((input) => (input.value = token));
  },

  fail() {
    this.fill("");
    this.showError(true);
  },

  showError(visible) {
    if (this.errorEl) this.errorEl.hidden = !visible;
  },
};
