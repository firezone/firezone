const QRCode = require('qrcode')

export function qrEncode() {
  let canvas = document.getElementById('qr-canvas')
  let conf = document.getElementById('wg-conf')

  QRCode.toCanvas(canvas, conf.innerHTML, {
    errorCorrectionLevel: 'H',
    margin: 0,
    width: 156,
    height: 156

  }, function (error) {
    if (error) alert('QRCode Encode Error: ' + error)
  })
}
