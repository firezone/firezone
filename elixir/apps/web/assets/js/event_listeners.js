// Helper for copying text to the clipboard in a Phoenix-idiomatic way.
window.addEventListener("phx:copy", (event) => {
  let text = event.target.dataset.copy;
  navigator.clipboard.writeText(text).then(() => {
    // noop
  });
});
