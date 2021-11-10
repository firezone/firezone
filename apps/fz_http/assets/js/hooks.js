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

let Hooks = {}
Hooks.QrCode = {
  mounted: renderQrCode,
  updated: renderQrCode
}
Hooks.FormatTimestamp = {
  mounted: formatTimestamp,
  updated: formatTimestamp
}

export default Hooks
