import hljs from "highlight.js"
import {FormatTimestamp} from "./util.js"

const QRCode = require('qrcode')

const renderQrCode = function () {
  let canvas = document.getElementById('qr-canvas')
  let conf = document.getElementById('wg-conf')

  if (canvas && conf) {
    QRCode.toCanvas(canvas, conf.innerHTML, {
      errorCorrectionLevel: 'H',
      margin: 0,
      width: 200,
      height: 200

    }, function (error) {
      if (error) alert('QRCode Encode Error: ' + error)
    })
  }
}

/* XXX: Sad we have to write custom JS for this. Keep an eye on
 * https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.JS.html
 * in case a toggleClass function is implemented. The toggle()
 * function listed there automatically adds display: none which is not
 * what we want in this case.
 */
const toggleDropdown = function () {
  const button = this.el
  const dropdown = document.getElementById(button.dataset.target)

  document.addEventListener("click", e => {
    let ancestor = e.target

    do {
      if (ancestor == button) return
      ancestor = ancestor.parentNode
    } while(ancestor)

    dropdown.classList.remove("is-active")
  })
  button.addEventListener("click", e => {
    dropdown.classList.toggle("is-active")
  })
}

const highlightCode = function () {
  hljs.highlightAll()
}

const formatTimestamp = function () {
  let t = this.el.dataset.timestamp
  this.el.innerHTML = FormatTimestamp(t)
}

let Hooks = {}
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
Hooks.ToggleDropdown = {
  mounted: toggleDropdown,
  updated: toggleDropdown
}

export default Hooks
