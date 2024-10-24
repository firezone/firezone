import { invoke } from "@tauri-apps/api/core";

// Custom types
interface Settings {
  auth_base_url: string;
  api_url: string;
  log_filter: string;
}

interface FileCount {
  files: number;
  bytes: number;
}

// DOM elements
const form = <HTMLFormElement>document.getElementById("advanced-settings-form");
const authBaseUrlInput = <HTMLInputElement>(
  document.getElementById("auth-base-url-input")
);
const apiUrlInput = <HTMLInputElement>document.getElementById("api-url-input");
const logFilterInput = <HTMLInputElement>(
  document.getElementById("log-filter-input")
);
const logCountOutput = <HTMLParagraphElement>(
  document.getElementById("log-count-output")
);
const resetAdvancedSettingsBtn = <HTMLButtonElement>(
  document.getElementById("reset-advanced-settings-btn")
);
const applyAdvancedSettingsBtn = <HTMLButtonElement>(
  document.getElementById("apply-advanced-settings-btn")
);
const exportLogsBtn = <HTMLButtonElement>(
  document.getElementById("export-logs-btn")
);
const clearLogsBtn = <HTMLButtonElement>(
  document.getElementById("clear-logs-btn")
);
const logsTabBtn = <HTMLButtonElement>document.getElementById("logs-tab");

// Rust bridge functions

// Lock the UI when we're saving to disk, since disk writes are technically async.
function lockAdvancedSettingsForm() {
  authBaseUrlInput.disabled = true;
  apiUrlInput.disabled = true;
  logFilterInput.disabled = true;
  resetAdvancedSettingsBtn.disabled = true;
  applyAdvancedSettingsBtn.disabled = true;

  resetAdvancedSettingsBtn.textContent = "Updating...";
  applyAdvancedSettingsBtn.textContent = "Updating...";
}

function unlockAdvancedSettingsForm() {
  authBaseUrlInput.disabled = false;
  apiUrlInput.disabled = false;
  logFilterInput.disabled = false;
  resetAdvancedSettingsBtn.disabled = false;
  applyAdvancedSettingsBtn.disabled = false;

  resetAdvancedSettingsBtn.textContent = "Reset to Defaults";
  applyAdvancedSettingsBtn.textContent = "Apply";
}

function lockLogsForm() {
  exportLogsBtn.disabled = true;
  clearLogsBtn.disabled = true;
}

function unlockLogsForm() {
  exportLogsBtn.disabled = false;
  clearLogsBtn.disabled = false;
}

async function applyAdvancedSettings() {
  console.log("Applying advanced settings");
  lockAdvancedSettingsForm();

  try {
    await invoke("apply_advanced_settings", {
      settings: {
        auth_base_url: authBaseUrlInput.value,
        api_url: apiUrlInput.value,
        log_filter: logFilterInput.value,
      },
    });
  } catch(e) {
    console.error(e);
  } finally {
    unlockAdvancedSettingsForm();
  }
}

async function resetAdvancedSettings() {
  console.log("Resetting advanced settings");
  lockAdvancedSettingsForm();

  try {
    let settings = await invoke("reset_advanced_settings") as Settings;
    authBaseUrlInput.value = settings.auth_base_url;
    apiUrlInput.value = settings.api_url;
    logFilterInput.value = settings.log_filter;
  } catch(e) {
    console.error(e);
  } finally {
    unlockAdvancedSettingsForm();
  }
}

async function getAdvancedSettings() {
  console.log("Getting advanced settings");
  lockAdvancedSettingsForm();

  try {
    let settings = await invoke("get_advanced_settings") as Settings;
    authBaseUrlInput.value = settings.auth_base_url;
    apiUrlInput.value = settings.api_url;
    logFilterInput.value = settings.log_filter;
  } catch(e) {
    console.error(e);
  } finally {
    unlockAdvancedSettingsForm();
  }
}

async function exportLogs() {
  console.log("Exporting logs");
  lockLogsForm();

  try {
    await invoke("export_logs");
  } catch(e) {
      console.error(e);
  } finally {
    unlockLogsForm();
  }
}

async function clearLogs() {
  console.log("Clearing logs");
  lockLogsForm();

  try {
    await invoke("clear_logs");
  } catch(e) {
    console.error(e);
  } finally {
    countLogs();
    unlockLogsForm();
  };
}

async function countLogs() {
  try {
    let fileCount = await invoke("count_logs") as FileCount;
    console.log(fileCount);
    const megabytes = Math.round(fileCount.bytes / 100000) / 10;
    logCountOutput.innerText = `${fileCount.files} files, ${megabytes} MB`;
  } catch(e) {
    let error = e as Error;
    console.error(e);
    logCountOutput.innerText = `Error counting logs: ${error.message}`;
  };
}

// Setup event listeners
form.addEventListener("submit", (e) => {
  e.preventDefault();
  applyAdvancedSettings();
});
resetAdvancedSettingsBtn.addEventListener("click", (_e) => {
  resetAdvancedSettings();
});
exportLogsBtn.addEventListener("click", (_e) => {
  exportLogs();
});
clearLogsBtn.addEventListener("click", (_e) => {
  clearLogs();
});
logsTabBtn.addEventListener("click", (_e) => {
  countLogs();
});

// Load settings
getAdvancedSettings();
