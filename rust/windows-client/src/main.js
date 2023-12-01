const { invoke } = window.__TAURI__.tauri;

const querySel = function(id) {
  return document.querySelector(id);
};

let apply_account_id_btn;
let apply_account_id_btn_2;

let greetInputEl;
let greetMsgEl;

async function greet() {
  // Learn more about Tauri commands at https://tauri.app/v1/guides/features/command
  greetMsgEl.textContent = await invoke("greet", { name: greetInputEl.value });
}

// Called when we're saving settings to disk. Touching disk is technically async, so the UI related to saving should be locked, but the UI thread must not block.
// Parameters:
// - locked - Boolean, true to lock the UI, false to unlock it.
function lock_settings_inputs(locked) {
  // Buttons
  if (locked) {
    apply_account_id_btn.textContent = "Applying...";
    apply_account_id_btn_2.textContent = "Applying...";
  }
  else {
    apply_account_id_btn.textContent = "Apply";
    apply_account_id_btn_2.textContent = "Apply";
  }

  apply_account_id_btn.disabled = locked;
  apply_account_id_btn_2.disabled = locked;

  // Text inputs
  querySel("#account-id-input").disabled = locked;
}

async function apply_account_id() {
  lock_settings_inputs(true);

  // Pretend that the hard disk is slow and we need a couple seconds to commit to disk
  // TODO: Actually call Rust
  await new Promise(r => setTimeout(r, 2000));

  lock_settings_inputs(false);
}

window.addEventListener("DOMContentLoaded", () => {
  apply_account_id_btn = querySel("#apply-account-id-btn");
  apply_account_id_btn_2 = querySel("#apply-account-id-btn-2");

  querySel("#account-id-form").addEventListener("submit", (e) => {
    // TODO: Doesn't this mean there's a small window of time where clicking the button might redirect the browser instead of running the JS?

    e.preventDefault();
    apply_account_id();
  })

  greetInputEl = querySel("#greet-input");
  greetMsgEl = querySel("#greet-msg");
  querySel("#greet-form").addEventListener("submit", (e) => {
    e.preventDefault();
    greet();
  });
});
