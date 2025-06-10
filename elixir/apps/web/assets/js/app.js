// Supports weights 200-900
import '@fontsource-variable/source-sans-3';

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";

// Flowbite's Phoenix LiveView integration
import "flowbite/dist/flowbite.phoenix.js";

// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import Hooks from "./hooks";
import "./event_listeners";

// Read CSRF token from the meta tag and use it in the LiveSocket params
let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: {
    _csrf_token: csrfToken,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    locale: Intl.NumberFormat().resolvedOptions().locale,
  },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
  // Enable server log streaming to client.
  // Disable with reloader.disableServerLogs()
  reloader.enableServerLogs();
  window.liveReloader = reloader;
});
