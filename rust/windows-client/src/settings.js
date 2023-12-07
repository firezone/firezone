let auth_base_url_input;
let api_url_input;
let log_filter_input;
let reset_advanced_settings_btn;
let apply_advanced_settings_btn;
let export_logs_btn;
let clear_logs_btn;

const querySel = function(id) {
  return document.querySelector(id);
};

const { invoke } = window.__TAURI__.tauri;

// Lock the UI when we're saving to disk, since disk writes are technically async.
// Parameters:
// - locked - Boolean, true to lock the UI, false to unlock it.
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

function lock_logs_form(locked) {
    export_logs_btn.disabled = locked;
    clear_logs_btn.disabled = locked;
}

async function apply_advanced_settings() {
    lock_advanced_settings_form(true);

    // Invoke Rust
    // TODO: Why doesn't JS' await syntax work here?
    invoke("apply_advanced_settings", {
        "settings": {
            "auth_base_url": auth_base_url_input.value,
            "api_url": api_url_input.value,
            "log_filter": log_filter_input.value
        }
    })
    .then(() => {
        lock_advanced_settings_form(false);
    })
    .catch((e) => {
        console.error(e);
        lock_advanced_settings_form(false);
    });
}

async function get_advanced_settings() {
    lock_advanced_settings_form(true);

    invoke("get_advanced_settings")
    .then((settings) => {
        auth_base_url_input.value = settings["auth_base_url"];
        api_url_input.value = settings["api_url"];
        log_filter_input.value = settings["log_filter"];
        lock_advanced_settings_form(false);
    })
    .catch((e) => {
        console.error(e);
        lock_advanced_settings_form(false);
    });
}

async function export_logs() {
    lock_logs_form(true);

    invoke("export_logs")
    .then(() => {
        lock_logs_form(false);
    })
    .catch((e) => {
        console.error(e);
        lock_logs_form(false);
    });
}

async function clear_logs() {
    lock_logs_form(true);

    invoke("clear_logs")
    .then(() => {
        lock_logs_form(false);
    })
    .catch((e) => {
        console.error(e);
        lock_logs_form(false);
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
    // Advanced tab
    auth_base_url_input = querySel("#auth-base-url-input");
    api_url_input = querySel("#api-url-input");
    log_filter_input = querySel("#log-filter-input");
    reset_advanced_settings_btn = querySel("#reset-advanced-settings-btn");
    apply_advanced_settings_btn = querySel("#apply-advanced-settings-btn");

    querySel("#advanced-settings-form").addEventListener("submit", (e) => {
        e.preventDefault();
        apply_advanced_settings();
    });

    // Logs tab
    export_logs_btn = querySel("#export-logs-btn");
    clear_logs_btn = querySel("#clear-logs-btn");

    export_logs_btn.addEventListener("click", (e) => {
        export_logs();
    });
    clear_logs_btn.addEventListener("click", (e) => {
        clear_logs();
    });

    // TODO: Why doesn't this open the Advanced tab by default?
    querySel("#tab_advanced").click();

    get_advanced_settings().await;
});
