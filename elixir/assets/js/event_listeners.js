// Helper for copying text to the clipboard in a Phoenix-idiomatic way.
window.addEventListener("phx:copy", (event) => {
  let text = event.target.dataset.copy;
  navigator.clipboard.writeText(text).then(() => {
    // noop
  });
});

// Toast API helpers
window.addEventListener("toast:show", (event) => {
  const el = event.target;
  if (el && !el.matches(":popover-open")) {
    el.showPopover();
  }
});

window.addEventListener("toast:hide", (event) => {
  const el = event.target;
  if (el && el.matches(":popover-open")) {
    el.hidePopover();
  }
});

window.addEventListener("click", (event) => {
  const closeWindowButton = event.target.closest("[data-close-window-button]");

  if (closeWindowButton) {
    window.close();
    return;
  }

  const copyTokenButton = event.target.closest("[data-copy-token-button]");

  if (!copyTokenButton) {
    return;
  }

  const targetSelector = copyTokenButton.dataset.copyTarget || "#token-value";
  const tokenElement = document.querySelector(targetSelector);
  const token = tokenElement?.textContent;

  if (!token) {
    return;
  }

  if (!navigator.clipboard) {
    alert("Clipboard API not available. Please copy the token manually.");
    return;
  }

  navigator.clipboard
    .writeText(token)
    .then(() => {
      const originalText = copyTokenButton.textContent;

      copyTokenButton.textContent = "Copied!";
      copyTokenButton.classList.add("bg-green-600");
      copyTokenButton.classList.remove("bg-accent-500", "hover:bg-accent-700");

      window.setTimeout(() => {
        copyTokenButton.textContent = originalText;
        copyTokenButton.classList.remove("bg-green-600");
        copyTokenButton.classList.add("bg-accent-500", "hover:bg-accent-700");
      }, 2000);
    })
    .catch(() => {
      alert("Failed to copy token. Please copy it manually.");
    });
});

window.addEventListener("keydown", (event) => {
  if (event.key !== "Enter") {
    return;
  }

  if (event.target instanceof HTMLTextAreaElement) {
    return;
  }

  if (event.target.closest("[data-prevent-enter-submit]")) {
    event.preventDefault();
  }
});

window.addEventListener("DOMContentLoaded", () => {
  const autoCloseWindowElement = document.querySelector(
    "[data-auto-close-window-after-ms]"
  );

  if (!autoCloseWindowElement) {
    return;
  }

  const timeoutMs = Number.parseInt(
    autoCloseWindowElement.dataset.autoCloseWindowAfterMs || "",
    10
  );

  if (!Number.isFinite(timeoutMs) || timeoutMs < 0) {
    return;
  }

  window.setTimeout(() => {
    window.close();
  }, timeoutMs);
});
