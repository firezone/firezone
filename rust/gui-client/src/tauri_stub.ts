// Stub Tauri API for TypeScript. Helpful when developing without Tauri running.

interface TauriEvent {
  type: string;
  payload: any;
}

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
window.__TAURI__ = window.__TAURI__ || {
  tauri: {
    invoke: (_cmd: string, _args?: any) => {
      return Promise.reject("Tauri API not initialized");
    },
  },
  event: {
    listen: (_cmd: string, _callback: (event: TauriEvent) => void) => {
      console.error("Tauri API not initialized");
    },
  },
};
