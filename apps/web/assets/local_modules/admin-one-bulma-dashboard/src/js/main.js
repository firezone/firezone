
/* Aside: submenus toggle */
Array.from(document.getElementsByClassName('menu is-menu-main')).forEach(el => {
  Array.from(el.getElementsByClassName('has-dropdown-icon')).forEach(elA => {
    elA.addEventListener('click', e => {
      const dropdownIcon = e.currentTarget
          .getElementsByClassName('dropdown-icon')[0]
          .getElementsByClassName('mdi')[0]

      e.currentTarget.parentNode.classList.toggle('is-active')
      dropdownIcon.classList.toggle('mdi-plus')
      dropdownIcon.classList.toggle('mdi-minus')
    })
  })
})

/* Aside Mobile toggle */
Array.from(document.getElementsByClassName('jb-aside-mobile-toggle')).forEach(el => {
  el.addEventListener('click', e => {
    const dropdownIcon = e.currentTarget
        .getElementsByClassName('icon')[0]
        .getElementsByClassName('mdi')[0]

    document.documentElement.classList.toggle('has-aside-mobile-expanded')
    dropdownIcon.classList.toggle('mdi-forwardburger')
    dropdownIcon.classList.toggle('mdi-backburger')
  })
})

/* NavBar menu mobile toggle */
Array.from(document.getElementsByClassName('jb-navbar-menu-toggle')).forEach(el => {
  el.addEventListener('click', e => {
    const dropdownIcon = e.currentTarget
        .getElementsByClassName('icon')[0]
        .getElementsByClassName('mdi')[0]

    document.getElementById(e.currentTarget.getAttribute('data-target')).classList.toggle('is-active')
    dropdownIcon.classList.toggle('mdi-dots-vertical')
    dropdownIcon.classList.toggle('mdi-close')
  })
})

/* Modal: open */
Array.from(document.getElementsByClassName('jb-modal')).forEach(el => {
  el.addEventListener('click', e => {
    const modalTarget = e.currentTarget.getAttribute('data-target')

    document.getElementById(modalTarget).classList.add('is-active')
    document.documentElement.classList.add('is-clipped')
  })
});

/* Modal: close */
Array.from(document.getElementsByClassName('jb-modal-close')).forEach(el => {
  el.addEventListener('click', e => {
    e.currentTarget.closest('.modal').classList.remove('is-active')
    document.documentElement.classList.remove('is-clipped')
  })
})

/* Notification dismiss */
Array.from(document.getElementsByClassName('jb-notification-dismiss')).forEach(el => {
  el.addEventListener('click', e => {
    e.currentTarget.closest('.notification').classList.add('is-hidden')
  })
})
