const PAGE_SIZE_STORAGE_KEY = "liveTablePageSize";
const VALID_PAGE_SIZES = new Set(["10", "25", "50"]);

export function getPageSizePreference() {
  const value = localStorage.getItem(PAGE_SIZE_STORAGE_KEY);
  return VALID_PAGE_SIZES.has(value) ? value : null;
}

function setPageSizePreference(value) {
  if (!VALID_PAGE_SIZES.has(value)) return;
  localStorage.setItem(PAGE_SIZE_STORAGE_KEY, value);
}

export const PageSizePreference = {
  mounted() {
    this.select = this.el.querySelector("select[name='page_size']");
    if (!this.select) return;

    this._onChange = (event) => {
      setPageSizePreference(event.target.value);
    };

    this.select.addEventListener("change", this._onChange);

    const tableId = this.el.dataset.tableId;
    if (!tableId) return;

    const params = new URLSearchParams(window.location.search);
    const explicitPageSize =
      params.get(`${tableId}_page_size`) || params.get(`${tableId}_limit`);

    if (VALID_PAGE_SIZES.has(explicitPageSize)) {
      setPageSizePreference(explicitPageSize);
      return;
    }

    const preferredPageSize = getPageSizePreference();

    if (preferredPageSize && preferredPageSize !== this.select.value) {
      this.pushEvent("change_limit", {
        table_id: tableId,
        page_size: preferredPageSize,
      });

      return;
    }

    setPageSizePreference(this.select.value);
  },

  destroyed() {
    if (this.select && this._onChange) {
      this.select.removeEventListener("change", this._onChange);
    }
  },
};
