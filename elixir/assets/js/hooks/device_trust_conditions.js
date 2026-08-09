/* Attestation is strong x509 device identity, so it supersedes the manual
 * verification an administrator does by hand. Turning it on shows verification
 * as satisfied and takes it out of the operator's hands. A disabled checkbox is
 * not submitted, so the saved policy carries the attestation condition alone
 * rather than both. */
export const DeviceTrustConditions = {
  mounted() {
    this.attested = this.el.querySelector("[data-device-trust='attested']");
    this.verified = this.el.querySelector("[data-device-trust='verified']");

    if (!this.attested || !this.verified) return;

    this.wasChecked = this.verified.checked;

    this.syncVerified = () => {
      if (this.attested.checked) {
        this.verified.checked = true;
        this.verified.disabled = true;
      } else {
        this.verified.disabled = false;
        this.verified.checked = this.wasChecked;
      }
    };

    this.rememberVerified = () => {
      if (!this.verified.disabled) this.wasChecked = this.verified.checked;
    };

    this.attested.addEventListener("change", this.syncVerified);
    this.verified.addEventListener("change", this.rememberVerified);

    this.syncVerified();
  },

  destroyed() {
    this.attested?.removeEventListener("change", this.syncVerified);
    this.verified?.removeEventListener("change", this.rememberVerified);
  },
};
