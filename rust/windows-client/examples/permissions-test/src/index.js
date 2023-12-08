let start_tunnel_btn;
let stop_tunnel_btn;

const querySel = function(id) {
  return document.querySelector(id);
};

const { invoke } = window.__TAURI__.tauri;

window.addEventListener("DOMContentLoaded", () => {
    start_tunnel_btn = querySel("#start-tunnel-btn");
    stop_tunnel_btn = querySel("#stop-tunnel-btn");

    start_tunnel_btn.addEventListener("click", (e) => {
        invoke("start_tunnel_cmd");
    });
    stop_tunnel_btn.addEventListener("click", (e) => {
        invoke("stop_tunnel_cmd");
    });
});
