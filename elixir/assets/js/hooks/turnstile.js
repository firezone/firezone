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
// server asks for a reset after it consumes one.
export const Turnstile = {
  mounted() {
    this.widgetId = null;
    this.removed = false;

    this.handleEvent("turnstile:reset", () => {
      this.fill("");
      if (this.widgetId !== null) window.turnstile.reset(this.widgetId);
    });

    loadScript()
      .then((turnstile) => {
        if (this.removed) return;

        this.widgetId = turnstile.render(this.el, {
          sitekey: this.el.dataset.sitekey,
          theme: "auto",
          callback: (token) => this.fill(token),
          "expired-callback": () => this.fill(""),
          "error-callback": () => this.fill(""),
        });
      })
      .catch(() => this.fill(""));
  },

  destroyed() {
    this.removed = true;
    if (this.widgetId !== null && window.turnstile) {
      window.turnstile.remove(this.widgetId);
    }
  },

  fill(token) {
    document
      .querySelectorAll("input[data-turnstile-token]")
      .forEach((input) => (input.value = token));
  },
};
