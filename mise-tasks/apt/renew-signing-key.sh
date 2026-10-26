#!/usr/bin/env bash
#MISE description="Extend the expiry of the APT repository signing key and republish it"
#USAGE flag "--key <key>" required=#true help="Armoured secret key of the APT repository"
#USAGE flag "--expire <expire>" help="New expiry, counted from now [default: 2y]"
set -euo pipefail

REPO="firezone/firezone"
SECRET="APT_REPOSITORY_GPG_KEY"
EMAIL="packages@firezone.dev"
EXPIRE="${usage_expire:-2y}"

for tool in gpg gpgconf gh; do
    command -v "$tool" >/dev/null || {
        echo "error: $tool is not installed" >&2
        exit 1
    }
done

# The secret key passes through a throwaway keyring, so nobody else on the machine may read it.
umask 077
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME

cleanup() {
    gpgconf --kill gpg-agent
    rm -rf "$GNUPGHOME"
}

trap cleanup EXIT

gpg --batch --import "${usage_key:?}"
FINGERPRINT=$(gpg --list-secret-keys --with-colons "$EMAIL" | awk -F: '$1 == "fpr" { print $10; exit }')

echo "==> Extending expiry of ${FINGERPRINT} by ${EXPIRE}..."
gpg --quick-set-expire "$FINGERPRINT" "$EXPIRE"
gpg --list-keys "$FINGERPRINT"

echo "==> Updating the ${SECRET} secret..."
gpg --armor --export-secret-keys "$FINGERPRINT" | gh secret set "$SECRET" --repo "$REPO"

echo "==> Publishing the public key..."
gh workflow run _apt.yml --repo "$REPO" --ref main

echo
echo "Clients only see the new expiry once they download the key again:"
echo
echo "  wget -qO- https://artifacts.firezone.dev/apt/key.gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/firezone.gpg"
