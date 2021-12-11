import moment from "moment"

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

const formatTimestamp = function () {
  let timestamp = this.el.dataset.timestamp
  this.el.innerHTML = moment(timestamp).format("dddd, MMMM Do YYYY, h:mm:ss a z")
}

/* XXX: Sad we have to write custom JS for this. Keep an eye on
 * https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.JS.html
 * in case a toggleClass function is implemented. The toggle()
 * function listed there automatically adds display: none which is not
 * what we want
 */
const toggleDropdown = function () {
  const button = this.el
  const dropdown = document.getElementById(button.dataset.target)

  document.addEventListener("click", e => {
    let ancestor = e.target

    do {
      if (ancestor == button) {
        return
      }

      ancestor = ancestor.parentNode
    } while(ancestor)

    dropdown.classList.remove("is-active")
  })
  button.addEventListener("click", e => {
    dropdown.classList.toggle("is-active")
  })
}

let Hooks = {}
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
