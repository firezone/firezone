import { box } from "tweetnacl/nacl-fast"
import { encodeBase64 } from "tweetnacl-util"

let fzCrypto = {
  generateKeyPair () {
    let kp = box.keyPair()
    return {
      privateKey: encodeBase64(kp.secretKey),
      publicKey: encodeBase64(kp.publicKey)
    }
  }
}

export { fzCrypto }
