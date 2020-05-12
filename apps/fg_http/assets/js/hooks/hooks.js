import { qrEncode } from "./qr_code.js"

let Hooks = {}

Hooks.QrEncode = {
  updated() {
    qrEncode()
  }
}

export default Hooks
