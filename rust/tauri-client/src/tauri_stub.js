// Stub Tauri API for TypeScript. Helpful when developing without Tauri running.
window.__TAURI__ = window.__TAURI__ || {
    tauri: {
        invoke: (_cmd, _args) => {
            return Promise.reject("Tauri API not initialized");
        },
    },
    event: {
        listen: (_cmd, _callback) => {
            console.error("Tauri API not initialized");
        },
    },
};
export {};
