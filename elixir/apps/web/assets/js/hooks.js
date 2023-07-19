import StatusPage from "../vendor/status_page"

let Hooks = {}

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
