// Coordinates a date-range filter that lets the user enter the bounds in
// either UTC or browser-local time. Canonical values are kept in hidden
// inputs as naive UTC ISO strings (matching the server's `parse_datetime`
// no-offset-means-UTC convention) and displayed in the user-facing
// `<input type="datetime-local">` shifted into whichever mode is active.
//
// The UTC/Local pill itself is a hidden radio group with styled labels,
// so toggling it fires a native form change and goes through phx-change
// without any JS dispatch. This hook only handles the display↔canonical
// value conversion.
export const DatetimeRangeFilter = {
  mounted() {
    this.bounds = ["from", "to"].map((slot) => ({
      slot,
      canonical: this.el.querySelector(`[data-canonical="${slot}"]`),
      display: this.el.querySelector(`[data-display="${slot}"]`),
    }));

    this.renderDisplay();
    this.bindDisplayInputs();
  },

  updated() {
    this.renderDisplay();
  },

  mode() {
    const checked = this.el.querySelector(
      'input[type="radio"][name$="[mode]"]:checked'
    );
    return checked?.value === "local" ? "local" : "utc";
  },

  renderDisplay() {
    const mode = this.mode();
    for (const { canonical, display } of this.bounds) {
      if (!canonical || !display) continue;
      const canonicalValue = canonical.value || "";
      display.value =
        mode === "local"
          ? utcNaiveToLocalNaive(canonicalValue)
          : canonicalValue;
    }
  },

  bindDisplayInputs() {
    for (const { canonical, display } of this.bounds) {
      if (!canonical || !display) continue;
      display.addEventListener("change", () => {
        const next =
          this.mode() === "local"
            ? localNaiveToUtcNaive(display.value)
            : display.value;
        if (canonical.value === next) return;
        canonical.value = next;
        canonical.dispatchEvent(new Event("change", { bubbles: true }));
      });
    }
  },
};

// "2026-05-26T12:00:00" (interpreted as UTC) -> "2026-05-26T05:00:00" in
// the user's local zone. Returns "" for empty input.
function utcNaiveToLocalNaive(value) {
  if (!value) return "";
  const date = new Date(value + "Z");
  if (Number.isNaN(date.getTime())) return value;
  return formatLocalNaive(date);
}

// "2026-05-26T05:00:00" (interpreted as local) -> "2026-05-26T12:00:00" UTC.
// Returns "" for empty input.
function localNaiveToUtcNaive(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return formatUtcNaive(date);
}

function formatLocalNaive(date) {
  const yy = date.getFullYear();
  const mm = pad(date.getMonth() + 1);
  const dd = pad(date.getDate());
  const HH = pad(date.getHours());
  const MM = pad(date.getMinutes());
  const SS = pad(date.getSeconds());
  return `${yy}-${mm}-${dd}T${HH}:${MM}:${SS}`;
}

function formatUtcNaive(date) {
  const yy = date.getUTCFullYear();
  const mm = pad(date.getUTCMonth() + 1);
  const dd = pad(date.getUTCDate());
  const HH = pad(date.getUTCHours());
  const MM = pad(date.getUTCMinutes());
  const SS = pad(date.getUTCSeconds());
  return `${yy}-${mm}-${dd}T${HH}:${MM}:${SS}`;
}

function pad(n) {
  return String(n).padStart(2, "0");
}
