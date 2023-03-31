import {FormatTimestamp} from "./util.js"

// Notification dismiss
document.addEventListener('DOMContentLoaded', () => {
  (document.querySelectorAll('.notification .delete') || []).forEach(($delete) => {
    const $notification = $delete.parentNode

    $delete.addEventListener('click', () => {
      $notification.parentNode.removeChild($notification)
    })
  })
})

document.addEventListener('DOMContentLoaded', () => {
  (document.querySelectorAll('[data-timestamp]') || []).forEach(($span) => {
    $span.innerHTML = FormatTimestamp($span.dataset.timestamp)
  })
})

document.addEventListener("firezone:clipcopy", (event) => {
  if ("clipboard" in navigator) {
    const text = event.target.textContent
    navigator.clipboard.writeText(text)
    const dispatcher = event.detail.dispatcher
    const span = dispatcher.getElementsByTagName("span")[0]
    const icon = dispatcher.getElementsByTagName("i")[0]

    span.classList.add("has-text-success")
    icon.classList.replace("mdi-content-copy", "mdi-check-bold")

    setTimeout(() => {
      span.classList.remove("has-text-success")
      icon.classList.replace("mdi-check-bold", "mdi-content-copy")
    }, 1000)
  } else {
    alert("Sorry, your browser does not support clipboard copy.")
  }
})
