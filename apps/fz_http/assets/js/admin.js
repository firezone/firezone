// We need to import the CSS so that webpack will load it.
// The MiniCssExtractPlugin is used to separate it out into
// its own CSS file.
import css from "../css/app.scss"

/* Application fonts */
import "@fontsource/fira-sans"
import "@fontsource/open-sans"
import "@fontsource/fira-mono"

// webpack automatically bundles all modules in your
// entry points. Those entry points can be configured
// in "webpack.config.js".
//
// Import dependencies
//
import "phoenix_html"
import {Socket, Presence} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import Hooks from "./hooks.js"
import {FormatTimestamp} from "./util.js"
import "./event_listeners.js"

// User Socket
const userToken = document
  .querySelector("meta[name='user-token']")
  .getAttribute("content")
const userSocket = new Socket("/socket", {
  params: {
    token: userToken
  }
})

// Notifications
const channelToken = document
  .querySelector("meta[name='channel-token']")
  .getAttribute("content")
const notificationChannel =
  userSocket.channel("notification:session", {
    token: channelToken,
    user_agent: window.navigator.userAgent
  })

// Presence
const presence = new Presence(notificationChannel)

// LiveView setup
const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content")
const liveSocket = new LiveSocket(
  "/live",
  Socket,
  {
    hooks: Hooks,
    params: {
      _csrf_token: csrfToken
    }
  }
)

const toggleConnectStatus = function (info) {
  let success = document.getElementById("web-ui-connect-success")
  let error = document.getElementById("web-ui-connect-error")
  if (userSocket.isConnected()) {
    success.classList.remove("is-hidden")
    error.classList.add("is-hidden")
  } else {
    success.classList.add("is-hidden")
    error.classList.remove("is-hidden")
  }
}

userSocket.onError(toggleConnectStatus)
userSocket.onOpen(toggleConnectStatus)
userSocket.onClose(toggleConnectStatus)

/* XXX: Refactor this into a LiveView. */
const sessionConnect = function (pres) {
  let tbody = document.getElementById("sessions-table-body")
  let rows = ""

  pres.list((user_id, {metas: metas}) => {
    if (tbody) {
      metas.forEach(meta =>
        rows +=
          `<tr>
            <td>${FormatTimestamp(meta.online_at)}</td>
            <td>${FormatTimestamp(meta.last_signed_in_at)}</td>
            <td>${meta.remote_ip}</td>
            <td>${meta.user_agent}</td>
          </tr>`
      )
    }
  })

  if (tbody && rows.length > 0) {
    tbody.innerHTML = rows
  }
}

// uncomment to connect if there are any LiveViews on the page
liveSocket.connect()
userSocket.connect()

// function to receive session updates
presence.onSync(() => sessionConnect(presence))

notificationChannel.join()
  // .receive("ok", ({messages}) => console.log("catching up", messages))
  // .receive("error", ({reason}) => console.log("error", reason))
  // .receive("timeout", () => console.log("Networking issue. Still waiting..."))

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)

window.liveSocket = liveSocket
