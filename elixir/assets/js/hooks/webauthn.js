const b64urlToBuf = (str) =>
  Uint8Array.from(atob(str.replace(/-/g, "+").replace(/_/g, "/")), (c) =>
    c.charCodeAt(0)
  );

const bufToB64url = (buf) =>
  btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

export const WebAuthnRegister = {
  mounted() {
    if (!window.PublicKeyCredential) {
      this.pushEvent("registration_failed", { error: "unsupported" });
      return;
    }

    this.el.addEventListener("click", async () => {
      try {
        const credential = await navigator.credentials.create({
          publicKey: {
            challenge: b64urlToBuf(this.el.dataset.challenge),
            rp: {
              id: this.el.dataset.rpId,
              name: this.el.dataset.rpName,
            },
            user: {
              id: b64urlToBuf(this.el.dataset.userId),
              name: this.el.dataset.userName,
              displayName: this.el.dataset.userName,
            },
            pubKeyCredParams: [
              { type: "public-key", alg: -7 },
              { type: "public-key", alg: -257 },
            ],
            authenticatorSelection: {
              residentKey: "preferred",
              userVerification: "required",
            },
            attestation: "none",
            timeout: 120000,
          },
        });

        this.pushEvent("verify_registration", {
          attestation_object: bufToB64url(
            credential.response.attestationObject
          ),
          client_data_json: bufToB64url(credential.response.clientDataJSON),
          raw_id: bufToB64url(credential.rawId),
        });
      } catch (err) {
        this.pushEvent("registration_failed", { error: err.name });
      }
    });
  },
};

export const WebAuthnAuthenticate = {
  mounted() {
    if (!window.PublicKeyCredential) {
      this.pushEvent("webauthn_error", { error: "unsupported" });
      return;
    }

    this.el.addEventListener("click", async () => {
      try {
        const credential = await navigator.credentials.get({
          publicKey: {
            challenge: b64urlToBuf(this.el.dataset.challenge),
            allowCredentials: [
              {
                type: "public-key",
                id: b64urlToBuf(this.el.dataset.credentialId),
              },
            ],
            rpId: this.el.dataset.rpId,
            userVerification: "required",
            timeout: 120000,
          },
        });

        const form = document.getElementById(this.el.dataset.formId);
        const setField = (name, value) => {
          form.querySelector(`input[name="${name}"]`).value = value;
        };

        setField("credential_id", bufToB64url(credential.rawId));
        setField(
          "authenticator_data",
          bufToB64url(credential.response.authenticatorData)
        );
        setField("signature", bufToB64url(credential.response.signature));
        setField(
          "client_data_json",
          bufToB64url(credential.response.clientDataJSON)
        );

        this.el.setAttribute("disabled", "disabled");
        form.submit();
      } catch (err) {
        this.pushEvent("webauthn_error", { error: err.name });
      }
    });
  },
};
