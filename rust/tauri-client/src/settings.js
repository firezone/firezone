var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
// Purpose: TypeScript file for the settings page.
import "./tauri_stub.js";
const invoke = window.__TAURI__.tauri.invoke;
const listen = window.__TAURI__.event.listen;
// DOM elements
const form = document.getElementById("advanced-settings-form");
const authBaseUrlInput = (document.getElementById("auth-base-url-input"));
const apiUrlInput = document.getElementById("api-url-input");
const logFilterInput = (document.getElementById("log-filter-input"));
const logCountOutput = (document.getElementById("log-count-output"));
const resetAdvancedSettingsBtn = (document.getElementById("reset-advanced-settings-btn"));
const applyAdvancedSettingsBtn = (document.getElementById("apply-advanced-settings-btn"));
const exportLogsBtn = (document.getElementById("export-logs-btn"));
const clearLogsBtn = (document.getElementById("clear-logs-btn"));
const logsTabBtn = document.getElementById("logs-tab");
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
function applyAdvancedSettings() {
    return __awaiter(this, void 0, void 0, function* () {
        console.log("Applying advanced settings");
        lockAdvancedSettingsForm();
        invoke("apply_advanced_settings", {
            settings: {
                auth_base_url: authBaseUrlInput.value,
                api_url: apiUrlInput.value,
                log_filter: logFilterInput.value,
            },
        })
            .catch((e) => {
            console.error(e);
        })
            .finally(() => {
            unlockAdvancedSettingsForm();
        });
    });
}
function resetAdvancedSettings() {
    return __awaiter(this, void 0, void 0, function* () {
        console.log("Resetting advanced settings");
        lockAdvancedSettingsForm();
        invoke("reset_advanced_settings")
            .then((settings) => {
            authBaseUrlInput.value = settings.auth_base_url;
            apiUrlInput.value = settings.api_url;
            logFilterInput.value = settings.log_filter;
        })
            .catch((e) => {
            console.error(e);
        })
            .finally(() => {
            unlockAdvancedSettingsForm();
        });
    });
}
function getAdvancedSettings() {
    return __awaiter(this, void 0, void 0, function* () {
        console.log("Getting advanced settings");
        lockAdvancedSettingsForm();
        invoke("get_advanced_settings")
            .then((settings) => {
            authBaseUrlInput.value = settings.auth_base_url;
            apiUrlInput.value = settings.api_url;
            logFilterInput.value = settings.log_filter;
        })
            .catch((e) => {
            console.error(e);
        })
            .finally(() => {
            unlockAdvancedSettingsForm();
        });
    });
}
function exportLogs() {
    return __awaiter(this, void 0, void 0, function* () {
        console.log("Exporting logs");
        lockLogsForm();
        invoke("export_logs")
            .catch((e) => {
            console.error(e);
        })
            .finally(() => {
            unlockLogsForm();
        });
    });
}
function clearLogs() {
    return __awaiter(this, void 0, void 0, function* () {
        console.log("Clearing logs");
        lockLogsForm();
        invoke("clear_logs")
            .catch((e) => {
            console.error(e);
        })
            .finally(() => {
            countLogs();
            unlockLogsForm();
        });
    });
}
function countLogs() {
    return __awaiter(this, void 0, void 0, function* () {
        invoke("count_logs")
            .then((fileCount) => {
            console.log(fileCount);
            const megabytes = Math.round(fileCount.bytes / 100000) / 10;
            logCountOutput.innerText = `${fileCount.files} files, ${megabytes} MB`;
        })
            .catch((e) => {
            console.error(e);
            logCountOutput.innerText = `Error counting logs: ${e.message}`;
        });
    });
}
// Setup event listeners
form.addEventListener("submit", (e) => {
    e.preventDefault();
    applyAdvancedSettings();
});
resetAdvancedSettingsBtn.addEventListener("click", (e) => {
    resetAdvancedSettings();
});
exportLogsBtn.addEventListener("click", (e) => {
    exportLogs();
});
clearLogsBtn.addEventListener("click", (e) => {
    clearLogs();
});
logsTabBtn.addEventListener("click", (e) => {
    countLogs();
});
// Load settings
getAdvancedSettings();
