export const DismissableBanner = {
  mounted() {
    this.dismissedHashes = new Set();
    this.onDismiss = (event) => {
      if (!event.target.closest("[data-dismiss-banner]")) return;

      const hash = this.el.dataset.contentHash;
      this.dismissedHashes.add(hash);
      this.el.hidden = true;
      try {
        localStorage.setItem(`dismissedBanner:${hash}`, hash);
      } catch {
        // Dismiss for this mount even if browser storage is unavailable.
      }
    };
    this.el.addEventListener("click", this.onDismiss);
    this.updated();
  },

  updated() {
    const hash = this.el.dataset.contentHash;
    let dismissed = this.dismissedHashes.has(hash);
    try {
      dismissed ||= localStorage.getItem(`dismissedBanner:${hash}`) === hash;
    } catch {
      // Storage restrictions should not prevent announcements from appearing.
    }
    this.el.hidden = dismissed;
  },

  destroyed() {
    this.el.removeEventListener("click", this.onDismiss);
  },
};
