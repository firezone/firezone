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
