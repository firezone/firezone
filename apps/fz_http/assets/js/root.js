// This is a barebones JS file to use for auth screens.
import css from "../css/app.scss"

/* Application fonts */
import "@fontsource/fira-sans"
import "@fontsource/open-sans"
import "@fontsource/fira-mono"

import "phoenix_html"
import Hooks from "./hooks.js"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import "./event_listeners.js"


// Basic LiveView setup
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

liveSocket.connect()
window.liveSocket = liveSocket
