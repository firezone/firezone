const QRCode = require('qrcode')

const alertPrivateKeyError = function () {
}

// 1. Load generated keypair from previous step
// 2. Replace config PrivateKey sentinel with PrivateKey
// 3. Set code el innerHTML to new config
// 4. render QR code
// 5. render download button
const renderConfig = function () {
  const publicKey = this.el.dataset.publicKey
  const deviceName = this.el.dataset.deviceName
  if (publicKey) {
    const privateKey = sessionStorage.getItem(publicKey)

    // XXX: Clear all private keys
    sessionStorage.removeItem(publicKey)
    const placeholder = document.getElementById("generating-config")

    if (privateKey) {
      const templateConfig = atob(this.el.dataset.config)
      const config = templateConfig.replace("REPLACE_ME", privateKey)

      renderDownloadButton(config, deviceName)
      renderQR(config)
      renderTunnel(config)

      placeholder.classList.add("is-hidden")
    } else {
      placeholder.innerHTML =
        `<p>
          Error generating configuration. Could not load private key from
          sessionStorage. Close window and try again. If the issue persists,
          please contact support@firezone.dev.
        </p>`
    }
  }
}

const renderDownloadButton = function (config, deviceName) {
  let button = document.getElementById("download-config")
  button.setAttribute("href", "data:text/plain;charset=utf-8," + encodeURIComponent(config))
  button.setAttribute("download", deviceName + ".conf")
  button.classList.remove("is-hidden")
}

const renderTunnel = function (config) {
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

export { renderConfig }
