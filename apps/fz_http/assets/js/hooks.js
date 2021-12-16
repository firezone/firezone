import hljs from "highlight.js"
import {FormatTimestamp} from "./util.js"
import {renderQrCode} from "./qrcode.js"

const highlightCode = function () {
  hljs.highlightAll()
}

const formatTimestamp = function () {
  let t = this.el.dataset.timestamp
  this.el.innerHTML = FormatTimestamp(t)
}

const clipboardCopy = function () {
  let button = this.el
  let data = button.dataset.clipboard
  button.addEventListener("click", () => {
    button.dataset.tooltip = "Copied!"
    navigator.clipboard.writeText(data)
  })
}

let Hooks = {}
Hooks.ClipboardCopy = {
  mounted: clipboardCopy,
  updated: clipboardCopy
}
Hooks.HighlightCode = {
  mounted: highlightCode,
  updated: highlightCode
}
Hooks.QrCode = {
  mounted: renderQrCode,
  updated: renderQrCode
}
Hooks.FormatTimestamp = {
  mounted: formatTimestamp,
  updated: formatTimestamp
}

export default Hooks
