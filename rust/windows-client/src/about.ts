import "./tauri_stub.js";

const invoke = window.__TAURI__.tauri.invoke;

const cargoVersionSpan = <HTMLSpanElement>(
  document.getElementById("cargo-version")
);
const gitShaSpan = <HTMLSpanElement>document.getElementById("git-sha");

async function get_cargo_version() {
  invoke("get_cargo_version")
    .then((cargoVersion: string) => {
      cargoVersionSpan.innerText = cargoVersion;
    })
    .catch((e: Error) => {
      cargoVersionSpan.innerText = "Unknown";
      console.error(e);
    });
}

async function get_git_sha() {
  invoke("get_git_sha")
    .then((gitSha: string) => {
      gitShaSpan.innerText = gitSha;
    })
    .catch((e: Error) => {
      gitShaSpan.innerText = "Unknown";
      console.error(e);
    });
}

document.addEventListener("DOMContentLoaded", () => {
  get_cargo_version();
  get_git_sha();
});
