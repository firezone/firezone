let account_id_input;
let apply_account_id_btn;

let auth_base_url_input;
let api_url_input;
let log_filter_input;
let reset_advanced_settings_btn;
let apply_advanced_settings_btn;

const querySel = function(id) {
  return document.querySelector(id);
};

const { invoke } = window.__TAURI__.tauri;

// Called when we're saving the account ID to disk. Touching disk is technically async, so the UI related to saving should be locked, but the UI thread must not block.
// Parameters:
// - locked - Boolean, true to lock the UI, false to unlock it.
function lock_account_id_form(locked) {
    // Text inputs
    account_id_input.disabled = locked;

    // Buttons
    if (locked) {
        apply_account_id_btn.textContent = "Applying...";
    }
    else {
        apply_account_id_btn.textContent = "Apply";
    }

    apply_account_id_btn.disabled = locked;
}

function lock_advanced_settings_form(locked) {
    auth_base_url_input.disabled = locked;
    api_url_input.disabled = locked;
    log_filter_input.disabled = locked;

    if (locked) {
        reset_advanced_settings_btn.textContent = "...";
        apply_advanced_settings_btn.textContent = "...";
    }
    else {
        reset_advanced_settings_btn.textContent = "Reset to Defaults";
        apply_advanced_settings_btn.textContent = "Apply";
    }

    reset_advanced_settings_btn.disabled = locked;
    apply_advanced_settings_btn.disabled = locked;
}

async function apply_account_id() {
    lock_account_id_form(true);

    // Invoke Rust
    // TODO: Why doesn't JS' await syntax work here?
    invoke("apply_account_id", {
        "accountId": account_id_input.value
    }).then(() => {
        console.log("JS done sleeping.");
        lock_account_id_form(false);
    });
}

async function apply_advanced_settings() {
    lock_advanced_settings_form(true);

    invoke("apply_advanced_settings", {
        "authBaseUrl": auth_base_url_input.value,
        "apiUrl": api_url_input.value,
        "logFilter": log_filter_input.value,
    }).then(() => {
        lock_advanced_settings_form(false);
    });
}

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
    // Hook up Account tab
    account_id_input = querySel("#account-id-input");
    apply_account_id_btn = querySel("#apply-account-id-btn");

    querySel("#account-id-form").addEventListener("submit", (e) => {
        // TODO: Doesn't this mean there's a small window of time where clicking the button might redirect the browser instead of running the JS?

        e.preventDefault();
        apply_account_id();
    })

    // Hook up Advanced tab
    auth_base_url_input = querySel("#auth-base-url-input");
    api_url_input = querySel("#api-url-input");
    log_filter_input = querySel("#log-filter-input");
    reset_advanced_settings_btn = querySel("#reset-advanced-settings-btn");
    apply_advanced_settings_btn = querySel("#apply-advanced-settings-btn");

    querySel("#advanced-settings-form").addEventListener("submit", (e) => {
        e.preventDefault();
        apply_advanced_settings();
    })

    // TODO: Why doesn't this open the Account tab by default?
    querySel("#tab_account").click();
});
