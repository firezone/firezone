import "./tauri_stub.js";
const invoke = window.__TAURI__.tauri.invoke;
const cargoVersionSpan = (document.getElementById("cargo-version"));
const gitVersionSpan = document.getElementById("git-version");
function get_cargo_version() {
    invoke("get_cargo_version")
        .then((cargoVersion) => {
        cargoVersionSpan.innerText = cargoVersion;
    })
        .catch((e) => {
        cargoVersionSpan.innerText = "Unknown";
        console.error(e);
    });
}
function get_git_version() {
    invoke("get_git_version")
        .then((gitVersion) => {
        gitVersionSpan.innerText = gitVersion;
    })
        .catch((e) => {
        gitVersionSpan.innerText = "Unknown";
        console.error(e);
    });
}
document.addEventListener("DOMContentLoaded", () => {
    get_cargo_version();
    get_git_version();
});
