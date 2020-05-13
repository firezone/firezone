import { qrEncode } from "./qr_code.js"

let Hooks = {}

Hooks.QrEncode = {
  mounted() {
    qrEncode()
  },
  updated() {
    qrEncode()
  }
}

export default Hooks
