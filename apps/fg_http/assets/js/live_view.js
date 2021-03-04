import {Socket} from "phoenix"
import LiveSocket from "phoenix_live_view"
import Hooks from "./hooks/hooks.js"

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

// uncomment to connect if there are any LiveViews on the page
// liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
window.liveSocket = liveSocket
