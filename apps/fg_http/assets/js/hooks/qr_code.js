const QRCode = require('qrcode')

export function qrEncode() {
  let canvas = document.getElementById('qr-canvas')
  let conf = document.getElementById('wg-conf')

  QRCode.toCanvas(canvas, conf.innerHTML, function (error) {
    if (error) console.error(error)
    console.log('success!');
  })
}
