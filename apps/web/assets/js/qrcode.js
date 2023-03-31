const QRCode = require('qrcode')

const qrError = function (el, error) {
  console.error(error)
  el.parentNode.removeChild(el)
}

const renderQR = function (data, canvas, width) {
  canvas ||= this.el
  data ||= canvas.dataset.qrdata
  width ||= canvas.dataset.size || 375
  if (canvas) {
    QRCode.toCanvas(canvas, data, {
      errorCorrectionLevel: "L",
      margin: 0,
      width: +width
    }, function (error) {
      if (error) qrError(canvas, error)
    })
  }
}

export { renderQR }
