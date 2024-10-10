var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
import "./tauri_stub.js";
const invoke = window.__TAURI__.tauri.invoke;
const signInBtn = (document.getElementById("sign-in"));
function sign_in() {
    return __awaiter(this, void 0, void 0, function* () {
        console.log("Signing in...");
        invoke("sign_in")
            .then(() => { })
            .catch((e) => {
            console.error(e);
        });
    });
}
signInBtn.addEventListener("click", (e) => sign_in());
