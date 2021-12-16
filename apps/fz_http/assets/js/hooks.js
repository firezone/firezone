import hljs from "highlight.js"
import {FormatTimestamp} from "./util.js"
import {renderQrCode} from "./qrcode.js"

const toggleDropdown = function () {
  const button = ctx.el
  const dropdown = document.getElementById(button.dataset.target)

  document.addEventListener("click", e => {
    let ancestor = e.target

    do {
      if (ancestor == button || ancestor == dropdown) return
      ancestor = ancestor.parentNode
    } while(ancestor)

    dropdown.classList.remove("is-active")
  })

  button.addEventListener("click", e => {
    dropdown.classList.add("is-active")
  })
}

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
