const QRCode = require('qrcode')

const renderQrCode = () => {
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

let Hooks = {}
Hooks.QrCode = {
  mounted: renderQrCode,
  updated: renderQrCode
}

export default Hooks
