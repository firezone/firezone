# macOS policy examples

`all-keys.mobileconfig` demonstrates Firezone's managed preference keys.

`firezone-intune-vpn-scep.template.mobileconfig` demonstrates the complete
Apple profile shape required for a certificate-backed Firezone packet tunnel.
It includes the system-extension fields that aren't exposed by Intune's built-in
macOS Custom VPN editor:

- `VPN.ProviderBundleIdentifier`
- `VPN.ProviderDesignatedRequirement`
- `VPN.ProviderType`

The certificate payload and VPN payload must remain in the same configuration
profile. `VPN.PayloadCertificateUUID` must equal the certificate payload's
`PayloadUUID`.

On macOS, the SCEP payload must also set `AllowAllAppsAccess` to `true`. Apple
requires this for a third-party VPN provider to use the managed private key
without presenting a keychain authorization dialog. A system extension can't
present that dialog, so a certificate issued without this setting can be read
but fails when the TLS handshake attempts to sign with its private key. Changing
the setting requires the SCEP identity to be reissued; it doesn't repair the ACL
on an existing private key.

## Intune Cloud PKI limitation

Do not upload the template unchanged. Intune creates a signed, encrypted,
device-specific SCEP challenge when it generates a built-in SCEP or VPN policy.
It doesn't perform that generation or merge a built-in SCEP policy into an
uploaded Custom `.mobileconfig`. Copying a challenge from an installed profile
is not a deployment solution: the challenge is device-specific and expires.

Consequently, a static Intune Custom profile can't both request an Intune Cloud
PKI identity and bind it to the VPN. The template is directly usable only when
the deploying MDM or CA can populate a valid SCEP payload for each target device,
or when the SCEP payload is replaced with another supported identity payload
such as a per-device PKCS#12 payload.

For Intune Cloud PKI, the production choices are:

1. Have Microsoft add the three system-extension provider fields to its macOS
   VPN policy generator. This lets Intune continue generating and embedding its
   dynamic SCEP payload.
2. Use an MDM/profile-generation path capable of constructing the complete
   combined profile per device.
3. Add a client-side compatibility path that copies the identity reference from
   Intune's managed configuration into a runnable Firezone configuration. This
   avoids recreating the SCEP enrollment but requires client behavior beyond the
   Apple profile itself.

Validate any rendered profile before uploading it:

```sh
plutil -lint path/to/profile.mobileconfig
```
