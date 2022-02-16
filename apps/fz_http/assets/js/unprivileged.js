// JS bundle for user layout
import css from "../css/app.scss"

/* Application fonts */
import "@fontsource/fira-sans"
import "@fontsource/open-sans"
import "@fontsource/fira-mono"

import "phoenix_html"
import "./event_listeners.js"
import { FormatTimestamp } from './util.js'
import { fzCrypto } from "./crypto.js"

window.fzCrypto = fzCrypto
