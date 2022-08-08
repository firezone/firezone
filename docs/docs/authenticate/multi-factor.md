---
title: Multi-Factor Authentication
sidebar_position: 2
---

Multi-factor authentication (MFA) can be added directly through Firezone
or by adding an additional factor directly through your identity provider.

## TOTP-based MFA through Firezone

Firezone currently supports using a time-based one time password
(TOTP) as an additional factor.

Admins can visit `/settings/account` in the admin portal to generate a
QR code to be scanned by your authenticator app.

Unprivileged users can visit the **My Account** page after logging into
the user portal.

## MFA through your Identity Provider

MFA can be configured through your identity provider if you have an existing
integration for SSO. Consult your provider's documentation to enforce an
additional factor. We have included links to a few common providers below:

* [Okta](https://help.okta.com/en-us/Content/Topics/Security/mfa/mfa-home.htm)
* [Azure AD](https://docs.microsoft.com/en-us/azure/active-directory/authentication/concept-mfa-howitworks)
* [Google](https://support.google.com/a/answer/175197)
* [Onelogin](https://www.onelogin.com/getting-started/free-trial-plan/add-mfa)
