const QRCode = require('qrcode')

const renderQR = function (data, canvas, width) {
  canvas ||= this.el
  data ||= canvas.dataset.qrdata
  width ||= canvas.dataset.size || 300
  if (canvas) {
    QRCode.toCanvas(canvas, data, {
      errorCorrectionLevel: "H",
      margin: 0,
      width: +width
    }, function (error) {
      if (error) alert("QRCode Encode Error: " + error)
    })
  }
}

export { renderQR }
