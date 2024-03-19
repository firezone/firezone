import "./tauri_stub.js";

const invoke = window.__TAURI__.tauri.invoke;

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

signInBtn.addEventListener("click", (e) => sign_in());
