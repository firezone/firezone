import { invoke } from "@tauri-apps/api/core";
import "flowbite"

const signInBtn = <HTMLButtonElement>document.getElementById("sign-in");

signInBtn.addEventListener("click", async (_e) => {
  console.log("Signing in...");

  await invoke("sign_in");
});
