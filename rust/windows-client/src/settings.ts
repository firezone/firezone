// Purpose: TypeScript file for the settings page.
//
// Ensure this file is loaded with the "defer" attribute on the script tag because we don't
// bother waiting for the DOM to load.

// Stub Tauri API for TypeScript
export {};
declare global {
  interface Window {
    __TAURI__: {
      tauri: {
        invoke: (cmd: string, args?: any) => Promise<any>;
      };
      event: {
        listen: (cmd: string, callback: (event: TauriEvent) => void) => void;
      };
    };
  }
}

// Custom types
interface Settings {
  auth_base_url: string;
  api_url: string;
  log_filter: string;
}

interface TauriEvent {
  type: string;
  payload: any;
}

interface FileCountProgress {
  files: number;
  bytes: number;
}

// Tauri API
const { invoke } = window.__TAURI__.tauri;
const { listen } = window.__TAURI__.event;

// DOM elements
const form = <HTMLFormElement>document.getElementById("advanced-settings-form");
const auth_base_url_input = <HTMLInputElement>(
  document.getElementById("auth-base-url-input")
);
const api_url_input = <HTMLInputElement>(
  document.getElementById("api-url-input")
);
const log_count_output = <HTMLParagraphElement>(
  document.getElementById("log-count-output")
);
const log_filter_input = <HTMLInputElement>(
  document.getElementById("log-filter-input")
);
const reset_advanced_settings_btn = <HTMLButtonElement>(
  document.getElementById("reset-advanced-settings-btn")
);
const apply_advanced_settings_btn = <HTMLButtonElement>(
  document.getElementById("apply-advanced-settings-btn")
);
const export_logs_btn = <HTMLButtonElement>(
  document.getElementById("export-logs-btn")
);
const clear_logs_btn = <HTMLButtonElement>(
  document.getElementById("clear-logs-btn")
);

// Setup event listeners
form.addEventListener("submit", (e) => {
  e.preventDefault();
  apply_advanced_settings();
});
export_logs_btn.addEventListener("click", (e) => {
  export_logs();
});
clear_logs_btn.addEventListener("click", (e) => {
  clear_logs();
});

listen("file_count_progress", (event: TauriEvent) => {
  const pl = <FileCountProgress>event.payload;

  let s = "Calculating...";
  if (!!pl) {
    const megabytes = Math.round(pl.bytes / 100000) / 10;
    s = `${pl.files} files, ${megabytes} MB`;
  }

  log_count_output.innerText = s;
});

// Rust bridge functions

// Lock the UI when we're saving to disk, since disk writes are technically async.
// Parameters:
// - locked - Boolean, true to lock the UI, false to unlock it.
function lock_advanced_settings_form(locked: boolean) {
  auth_base_url_input.disabled = locked;
  api_url_input.disabled = locked;
  log_filter_input.disabled = locked;

  if (locked) {
    reset_advanced_settings_btn.textContent = "...";
    apply_advanced_settings_btn.textContent = "...";
  } else {
    reset_advanced_settings_btn.textContent = "Reset to Defaults";
    apply_advanced_settings_btn.textContent = "Apply";
  }

  reset_advanced_settings_btn.disabled = locked;
  apply_advanced_settings_btn.disabled = locked;
}

function lock_logs_form(locked: boolean) {
  export_logs_btn.disabled = locked;
  clear_logs_btn.disabled = locked;
}

async function apply_advanced_settings() {
  lock_advanced_settings_form(true);

  // Invoke Rust
  // TODO: Why doesn't JS' await syntax work here?
  invoke("apply_advanced_settings", {
    settings: {
      auth_base_url: auth_base_url_input.value,
      api_url: api_url_input.value,
      log_filter: log_filter_input.value,
    },
  })
    .then(() => {
      lock_advanced_settings_form(false);
    })
    .catch((e: Error) => {
      console.error(e);
      lock_advanced_settings_form(false);
    });
}

async function get_advanced_settings(): Promise<void> {
  lock_advanced_settings_form(true);

  invoke("get_advanced_settings")
    .then((settings: Settings) => {
      auth_base_url_input.value = settings.auth_base_url;
      api_url_input.value = settings.api_url;
      log_filter_input.value = settings.log_filter;
      lock_advanced_settings_form(false);
    })
    .catch((e: Error) => {
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
    .catch((e: Error) => {
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
    .catch((e: Error) => {
      console.error(e);
      lock_logs_form(false);
    });
}

function openTab(tabName: string) {
  let tabcontent = document.getElementsByClassName("tabcontent");
  for (let i = 0; i < tabcontent.length; i++) {
    tabcontent[i].className = tabcontent[i].className + " collapse";
  }

  let tablinks = document.getElementById("tablinks")!.children;

  for (let i = 0; i < tablinks.length; i++) {
    tablinks[i].classList.remove("active");
  }

  document.getElementById(tabName)!.classList.remove("collapse");

  invoke("start_stop_log_counting", { enable: tabName == "tab_logs" })
    .then(() => {
      // Good
    })
    .catch((e: Error) => {
      console.error(e);
    });
}

// Load settings
get_advanced_settings();
