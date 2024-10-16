import { invoke } from "@tauri-apps/api/core";

const signInBtn = <HTMLButtonElement>(
  document.getElementById("sign-in")
);

async function sign_in() {
  console.log("Signing in...");
  invoke("sign_in")
    .then(() => {})
    .catch((e: Error) => {
      console.error(e);
    });
}

signInBtn.addEventListener("click", (_e) => sign_in());
