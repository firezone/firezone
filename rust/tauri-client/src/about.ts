import "./tauri_stub.js";

const invoke = window.__TAURI__.tauri.invoke;

const cargoVersionSpan = <HTMLSpanElement>(
  document.getElementById("cargo-version")
);
const gitVersionSpan = <HTMLSpanElement>document.getElementById("git-version");

function get_cargo_version() {
  invoke("get_cargo_version")
    .then((cargoVersion: string) => {
      cargoVersionSpan.innerText = cargoVersion;
    })
    .catch((e: Error) => {
      cargoVersionSpan.innerText = "Unknown";
      console.error(e);
    });
}

function get_git_version() {
  invoke("get_git_version")
    .then((gitVersion: string) => {
      gitVersionSpan.innerText = gitVersion;
    })
    .catch((e: Error) => {
      gitVersionSpan.innerText = "Unknown";
      console.error(e);
    });
}

document.addEventListener("DOMContentLoaded", () => {
  get_cargo_version();
  get_git_version();
});
