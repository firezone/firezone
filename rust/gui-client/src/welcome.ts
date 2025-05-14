import { invoke } from "@tauri-apps/api/core";
import { listen } from '@tauri-apps/api/event';
import "flowbite"

interface Session {
  account_slug: string,
  actor_name: string,
}

const signInBtn = <HTMLButtonElement>document.getElementById("sign-in");
const signOutBtn = <HTMLButtonElement>document.getElementById("sign-out");

const signedInDiv = <HTMLDivElement>document.getElementById("signed-in");
const signedOutDiv = <HTMLDivElement>document.getElementById("signed-out");

const accountSlugSpan = <HTMLSpanElement>document.getElementById("account_slug");
const actorNameSpan = <HTMLSpanElement>document.getElementById("actor_name");

// Initial state is to assume we are signed out.
signedOutDiv.style.display = "block";
signedInDiv.style.display = "none";

signInBtn.addEventListener("click", async (_e) => {
  console.log("Signing in...");

  await invoke("sign_in");
});
signOutBtn.addEventListener("click", async (_e) => {
  console.log("Signing in...");

  await invoke("sign_out");
});

listen<Session>('signed_in', (e) => {
  let session = e.payload;

  accountSlugSpan.textContent = session.account_slug;
  actorNameSpan.textContent = session.actor_name;
  signedOutDiv.style.display = "none";
  signedInDiv.style.display = "block";
})

listen<void>('signed_out', (_e) => {
  accountSlugSpan.textContent = "";
  actorNameSpan.textContent = "";
  signedOutDiv.style.display = "block";
  signedInDiv.style.display = "none";
})
