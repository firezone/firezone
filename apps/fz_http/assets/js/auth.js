// This is a barebones JS file to use for auth screens. If it gets complicated
// consider just using the full app bundle.
import css from "../css/app.scss"

/* Application fonts */
import "@fontsource/fira-sans"
import "@fontsource/open-sans"
import "@fontsource/fira-mono"

import "phoenix_html"

import { FormatTimestamp } from './util.js'

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
