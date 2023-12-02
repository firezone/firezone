import StatusPage from "../vendor/status_page"
import { initTabs } from "flowbite";

let Hooks = {}

// Copy to clipboard

Hooks.Tabs = {
  mounted() {
    initTabs();
  },

  updated() {
    initTabs();
  }
}

Hooks.Refocus = {
  mounted() {
    this.el.addEventListener("click", (ev) => {
      ev.preventDefault();
      let target_id = ev.currentTarget.getAttribute("data-refocus");
      let el = document.getElementById(target_id);
      if (document.activeElement === el) return;
      el.focus();
    });
  }
}

Hooks.Copy = {
  mounted() {
    this.el.addEventListener("click", (ev) => {
      ev.preventDefault();

      let inner_html = ev.currentTarget.querySelector("[data-copy]").innerHTML.trim();
      let doc = new DOMParser().parseFromString(inner_html, "text/html");
      let text = doc.documentElement.textContent;

      let content = ev.currentTarget.querySelector("[data-content]")
      let icon_cl = ev.currentTarget.querySelector("[data-icon]").classList

      navigator.clipboard.writeText(text).then(() => {
        icon_cl.add("hero-clipboard-document-check");
        icon_cl.add("text-green-500");
        icon_cl.remove("hero-clipboard-document");
        if (content) { content.innerHTML = "Copied" }
      });

      setTimeout(() => {
        icon_cl.remove("hero-clipboard-document-check");
        icon_cl.remove("text-green-500");
        icon_cl.add("hero-clipboard-document");
        if (content) { content.innerHTML = "Copy" }
      }, 2000);
    });
  },
}


// Update status indicator when sidebar is mounted or updated
let statusIndicatorClassNames = {
  none: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-300",
  minor: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-300",
  major: "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-300",
  critical: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-300",
}

const statusUpdater = function () {
  const self = this
  const sp = new StatusPage.page({ page: "firezone" })

  sp.summary({
    success: function (data) {
      self.el.innerHTML = `
        <span class="text-xs font-medium mr-2 px-2.5 py-0.5 rounded ${statusIndicatorClassNames[data.status.indicator]}">
          ${data.status.description}
        </span>
      `
    },
    error: function (data) {
      console.error("An error occurred while fetching status page data")
      self.el.innerHTML = `<span class="${statusIndicatorClassNames.minor}">Unable to fetch status</span>`
    },
  })
}

Hooks.StatusPage = {
  mounted: statusUpdater,
  updated: statusUpdater,
}

export default Hooks
