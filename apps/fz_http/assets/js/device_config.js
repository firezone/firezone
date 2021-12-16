import css from "../css/app.scss"

 /* Application fonts */
 import "@fontsource/fira-sans"
 import "@fontsource/open-sans"
 import "@fontsource/fira-mono"

 import "phoenix_html"

import {renderQrCode} from "./qrcode.js"

window.addEventListener('DOMContentLoaded', () => {
  renderQrCode()
})
