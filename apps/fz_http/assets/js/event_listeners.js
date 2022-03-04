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
