import { invoke } from "@tauri-apps/api/core";
import "flowbite"

const cargoVersionSpan = <HTMLSpanElement>(
  document.getElementById("cargo-version")
);
const gitVersionSpan = <HTMLSpanElement>document.getElementById("git-version");

function get_cargo_version() {
  try {
    invoke("get_cargo_version").then((cargoVersion: unknown) => {
      cargoVersionSpan.innerText = cargoVersion as string;
    });
  } catch (e) {
    cargoVersionSpan.innerText = "Unknown";
    console.error(e);
  }
}

function get_git_version() {
  try {
    invoke("get_git_version").then((gitVersion: unknown) => {
      gitVersionSpan.innerText = gitVersion as string;
    });
  } catch (e) {
    gitVersionSpan.innerText = "Unknown";
    console.error(e);
  }
}

document.addEventListener("DOMContentLoaded", () => {
  get_cargo_version();
  get_git_version();
});
