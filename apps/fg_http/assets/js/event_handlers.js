document.addEventListener('DOMContentLoaded', () => {
  (document.querySelectorAll('.notification .delete') || []).forEach(($d) => {
    const $notification = $d.parentNode

    $d.addEventListener('click', () => {
      $notification.parentNode.removeChild($notification)
    })
  })
})
