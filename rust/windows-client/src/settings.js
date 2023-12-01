function openTab(evt, tabName) {
    let tabcontent = document.getElementsByClassName("tabcontent");
    for (let i = 0; i < tabcontent.length; i++) {
    tabcontent[i].style.display = "none";
    }

    let tablinks = document.getElementsByClassName("tablinks");
    for (let i = 0; i < tablinks.length; i++) {
    // TODO: There's a better way to change classes on an element
    tablinks[i].className = tablinks[i].className.replace(" active", "");
    }

    document.getElementById(tabName).style.display = "block";
    // TODO: There's a better way to do this
    evt.currentTarget.className += " active";
}

window.addEventListener("DOMContentLoaded", () => {
    // TODO: Figure out why this default tab doesn't work, or rewrite it
    document.getElementById("tab_account").click();
});
