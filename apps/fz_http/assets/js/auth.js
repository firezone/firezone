import css from "../css/app.scss"

/* Application fonts */
import "@fontsource/fira-sans"
import "@fontsource/open-sans"
import "@fontsource/fira-mono"

import "phoenix_html"

// Notification dismiss
document.addEventListener('DOMContentLoaded', () => {
  (document.querySelectorAll('.notification .delete') || []).forEach(($delete) => {
    const $notification = $delete.parentNode

    $delete.addEventListener('click', () => {
      $notification.parentNode.removeChild($notification)
    })
  })
})
