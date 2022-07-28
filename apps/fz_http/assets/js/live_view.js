// Encapsulates LiveView initialization
import Hooks from "./hooks.js"
import {Socket, Presence} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {FormatTimestamp} from "./util.js"

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
const notificationSessionChannel =
  userSocket.channel("notification:session", {
    token: channelToken,
    user_agent: window.navigator.userAgent
  })
const notificationErrorChannel =
  userSocket.channel("notification:error", {
    token: channelToken
  })

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
  if (success && error) {
    if (userSocket.isConnected()) {
      success.classList.remove("is-hidden")
      error.classList.add("is-hidden")
    } else {
      success.classList.add("is-hidden")
      error.classList.remove("is-hidden")
    }
  }
}

userSocket.onError(toggleConnectStatus)
userSocket.onOpen(toggleConnectStatus)
userSocket.onClose(toggleConnectStatus)

// uncomment to connect if there are any LiveViews on the page
liveSocket.connect()
userSocket.connect()

notificationSessionChannel.join()
notificationErrorChannel.join()
  // .receive("ok", ({messages}) => console.log("catching up", messages))
  // .receive("error", ({reason}) => console.log("error", reason))
  // .receive("timeout", () => console.log("Networking issue. Still waiting..."))

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)

window.liveSocket = liveSocket
