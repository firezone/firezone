// QRCode generation
var QRCode = require('qrcode')
var canvas = document.getElementById('qr-canvas')
var conf = document.getElementById('wg-conf')

QRCode.toCanvas(canvas, conf.innerHTML, function (error) {
  if (error) console.error(error)
  console.log('success!');
})
