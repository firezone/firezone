const QRCode = require('qrcode')
import { fzCrypto } from "./crypto.js"

// 1. Generate keypair
// 2. Create device
// 2. Replace config PrivateKey sentinel with PrivateKey
// 3. Set code el innerHTML to new config
// 4. render QR code
// 5. render download button
const createDeviceAndRenderConfig = function () {
  let kp = fzCrypto.generateKeyPair()
  let params = {
    public_key: kp.publicKey,
    user_id: this.el.dataset.userId
  }

  this.pushEventTo(this.el, "create_device", params, (reply, ref) => {
    let config = reply.config.replace("REPLACE_ME", kp.privateKey)
    let placeholder = document.getElementById("generating-config")
    placeholder.classList.add("is-hidden")
    renderDownloadButton(config)
    renderQR(config)
    renderConfig(config)
  })
}

const renderDownloadButton = function (config) {
  let button = document.getElementById("download-config")
  button.setAttribute("href", "data:text/plain;charset=utf-8," + encodeURIComponent(config))
  button.setAttribute("download", window.location.hostname + ".conf")
  button.classList.remove("is-hidden")
}

const renderConfig = function (config) {
  let code = document.getElementById("wg-conf")
  let container = document.getElementById("wg-conf-container")
  code.innerHTML = config
  container.classList.remove("is-hidden")
}

const renderQR = function (config) {
  let canvas = document.getElementById("qr-canvas")
  if (canvas) {
    QRCode.toCanvas(canvas, config, {
      errorCorrectionLevel: "H",
      margin: 0,
      width: 200,
      height: 200
    }, function (error) {
      if (error) alert("QRCode Encode Error: " + error)
    })
  }
}

export { createDeviceAndRenderConfig }
