import hljs from "highlight.js"
import {FormatTimestamp,PasswordStrength} from "./util.js"
import {renderConfig} from "./wg_conf.js"
import {fzCrypto} from "./crypto.js"

const highlightCode = function () {
  hljs.highlightAll()
}

const formatTimestamp = function () {
  let t = this.el.dataset.timestamp
  this.el.innerHTML = FormatTimestamp(t)
}

const passwordStrength = function () {
  const field = this.el
  const fieldClasses = "password input "
  const progress = document.getElementById(field.dataset.target)
  const reset = function () {
    field.className = fieldClasses
    progress.className = "is-hidden"
    progress.setAttribute("value", "0")
    progress.innerHTML = "0%"
  }
  field.addEventListener("input", () => {
    if (field.value === "") return reset()
    const score = PasswordStrength(field.value)
    switch (score) {
      case 0:
      case 1:
        field.className = fieldClasses + "is-danger"
        progress.className = "progress is-small is-danger"
        progress.setAttribute("value", "33")
        progress.innerHTML = "33%"
        break
      case 2:
      case 3:
        field.className = fieldClasses + "is-warning"
        progress.className = "progress is-small is-warning"
        progress.setAttribute("value", "67")
        progress.innerHTML = "67%"
        break
      case 4:
        field.className = fieldClasses + "is-success"
        progress.className = "progress is-small is-success"
        progress.setAttribute("value", "100")
        progress.innerHTML = "100%"
        break
      default:
        reset()
    }
  })
}

const generateKeyPair = function () {
  let kp = fzCrypto.generateKeyPair()
  this.el.value = kp.publicKey

  // XXX: Verify
  sessionStorage.setItem(kp.publicKey, kp.privateKey)
}

const clipboardCopy = function () {
  let button = this.el
  let data = button.dataset.clipboard
  button.addEventListener("click", () => {
    button.dataset.tooltip = "Copied!"
    navigator.clipboard.writeText(data)
  })
}

let Hooks = {}
Hooks.ClipboardCopy = {
  mounted: clipboardCopy,
  updated: clipboardCopy
}
Hooks.HighlightCode = {
  mounted: highlightCode,
  updated: highlightCode
}
Hooks.FormatTimestamp = {
  mounted: formatTimestamp,
  updated: formatTimestamp
}
Hooks.PasswordStrength = {
  mounted: passwordStrength,
  updated: passwordStrength
}
Hooks.RenderConfig = {
  mounted: renderConfig,
  updated: renderConfig
}
Hooks.GenerateKeyPair = {
  mounted: generateKeyPair
}

export default Hooks
