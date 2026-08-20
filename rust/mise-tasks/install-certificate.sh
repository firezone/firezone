#!/usr/bin/env bash
#MISE description="Install the test X.509 client certificate into this machine's keystore"
set -euo pipefail

# The PKCS#11 path writes out a token PIN and a token holding the private key.
umask 077

CERT_ALIAS="${CERT_ALIAS:-firezone-client}"
P12_PASSWORD="${P12_PASSWORD:-firezone}"
P12_PATH="${P12_PATH:-${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509/${CERT_ALIAS}.p12}"

# The Linux Client addresses a PKCS#11 token by an RFC 7512 URI, whose `token` and `object`
# attributes are these two labels. The private key is found by the CKA_ID it shares with the
# certificate, so both objects are written with the same one.
TOKEN_LABEL="Firezone"
OBJECT_LABEL="device-trust"
OBJECT_ID="01"

# SoftHSM keeps the token in a directory of its own, and refuses a PIN shorter than four
# characters. Nothing here guards anything: the token holds a throwaway test key.
PKCS11_PIN="123456"

softhsm_module() {
    local candidate

    if [ -n "${SOFTHSM2_MODULE:-}" ]; then
        printf '%s\n' "$SOFTHSM2_MODULE"
        return 0
    fi

    for candidate in \
        /usr/lib/softhsm/libsofthsm2.so \
        /usr/lib64/softhsm/libsofthsm2.so \
        /usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so \
        /usr/lib/aarch64-linux-gnu/softhsm/libsofthsm2.so \
        /usr/local/lib/softhsm/libsofthsm2.so; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

install_linux() {
    local module token_dir configuration pin_file work

    command -v softhsm2-util >/dev/null && command -v pkcs11-tool >/dev/null || {
        echo "error: softhsm2-util and pkcs11-tool are required (Debian: apt install softhsm2 opensc)" >&2
        exit 1
    }

    module="$(softhsm_module)" || {
        echo "error: no SoftHSM PKCS#11 module found; set SOFTHSM2_MODULE to its path" >&2
        exit 1
    }

    token_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/softhsm"
    configuration="${token_dir}/softhsm2.conf"
    pin_file="${token_dir}/pin"

    mkdir -p "${token_dir}/tokens"
    cat >"$configuration" <<EOF
directories.tokendir = ${token_dir}/tokens
objectstore.backend = file
log.level = ERROR
EOF
    printf '%s\n' "$PKCS11_PIN" >"$pin_file"

    # The token store is this directory rather than the system-wide one, so every process that
    # touches the token needs to be told where it is, including the Client itself.
    export SOFTHSM2_CONF="$configuration"

    work="$(mktemp -d)"
    # shellcheck disable=SC2064 # `work` is expanded now on purpose; the trap outlives the variable.
    trap "rm -rf '${work}'" EXIT

    echo "==> Initialising the ${TOKEN_LABEL} token in ${token_dir}..."
    # Recreated from scratch so that re-running leaves exactly one identity on the token.
    softhsm2-util --delete-token --token "$TOKEN_LABEL" >/dev/null 2>&1 || true
    softhsm2-util --init-token --free --label "$TOKEN_LABEL" \
        --so-pin "$PKCS11_PIN" --pin "$PKCS11_PIN" >/dev/null

    # SoftHSM imports keys from PKCS#8 only, and OpenSSL writes bag attributes ahead of the key
    # when it unpacks a PKCS#12, so the key goes through `pkcs8` to come out on its own.
    openssl pkcs12 -in "$P12_PATH" -passin "pass:${P12_PASSWORD}" -nocerts -nodes |
        openssl pkcs8 -topk8 -nocrypt -out "${work}/key.pem"
    openssl pkcs12 -in "$P12_PATH" -passin "pass:${P12_PASSWORD}" -clcerts -nokeys |
        openssl x509 -outform der -out "${work}/leaf.der"

    echo "==> Importing the key and certificate..."
    softhsm2-util --import "${work}/key.pem" --token "$TOKEN_LABEL" \
        --label "$OBJECT_LABEL" --id "$OBJECT_ID" --pin "$PKCS11_PIN" >/dev/null
    # softhsm2-util imports key pairs only, so the certificate object is written separately.
    pkcs11-tool --module "$module" --token-label "$TOKEN_LABEL" --login --pin "$PKCS11_PIN" \
        --write-object "${work}/leaf.der" --type cert \
        --label "$OBJECT_LABEL" --id "$OBJECT_ID" >/dev/null

    echo
    echo "==> On the token:"
    pkcs11-tool --module "$module" --token-label "$TOKEN_LABEL" --login --pin "$PKCS11_PIN" \
        --list-objects | sed 's/^/    /'

    echo
    echo "Point the Client at it, in the shell you run it from:"
    echo
    echo "    export SOFTHSM2_CONF='${configuration}'"
    echo "    export FIREZONE_PKCS11_URI='pkcs11:token=${TOKEN_LABEL};object=${OBJECT_LABEL}?module-path=${module}&pin-source=file:${pin_file}'"
    echo
    echo "Then 'firezone-headless-client x509' prints what it makes of the token. The packaged"
    echo "Tunnel service reads both variables from /etc/default/firezone-client-tunnel instead."
}

install_windows() {
    local script work p12_windows

    # Windows PowerShell rather than pwsh: the PKI module that provides Import-PfxCertificate
    # ships with it.
    command -v powershell.exe >/dev/null || {
        echo "error: powershell.exe is not on PATH" >&2
        exit 1
    }

    command -v cygpath >/dev/null || {
        echo "error: cygpath is required to translate paths; run this from Git Bash" >&2
        exit 1
    }

    p12_windows="$(cygpath -w "$P12_PATH")"

    work="$(mktemp -d)"
    # shellcheck disable=SC2064 # `work` is expanded now on purpose; the trap outlives the variable.
    trap "rm -rf '${work}'" EXIT

    script="${work}/import.ps1"
    cat >"$script" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'

$password = ConvertTo-SecureString -String $env:P12_PASSWORD -AsPlainText -Force
$imported = @(Import-PfxCertificate -FilePath $env:P12_WINDOWS_PATH -CertStoreLocation 'Cert:\CurrentUser\My' -Password $password)

# The file carries the issuing CA alongside the client certificate, and both land in the store.
$certificate = $imported | Where-Object { $_.HasPrivateKey } | Select-Object -First 1

if (-not $certificate) {
    throw 'No certificate with a private key was imported.'
}

Write-Output ('Imported ' + $certificate.Subject)
Write-Output ('Thumbprint ' + $certificate.Thumbprint)

# The Client signs through CNG and cannot use a key held by a legacy cryptographic service
# provider, which is where PFXImportCertStore puts an RSA key that names no provider of its own.
$provider = certutil -user -store My $certificate.Thumbprint |
    Select-String -Pattern 'Provider =' |
    Select-Object -First 1

if ($provider) {
    Write-Output $provider.Line.Trim()
}

if (-not $provider -or $provider.Line -notmatch 'Key Storage Provider') {
    Write-Warning 'The private key is not held by a CNG key storage provider, so the Client cannot sign with it.'
    Write-Warning 'Delete it from Cert:\CurrentUser\My and import it again with certutil instead:'
    Write-Warning ('  certutil -f -user -p ' + $env:P12_PASSWORD + ' -csp "Microsoft Software Key Storage Provider" -importpfx My ' + $env:P12_WINDOWS_PATH)
}
POWERSHELL

    echo "==> Importing ${P12_PATH} into Cert:\\CurrentUser\\My..."

    # MSYS rewrites arguments that look like paths, which would mangle the script path.
    MSYS2_ARG_CONV_EXCL='*' \
        P12_WINDOWS_PATH="$p12_windows" \
        P12_PASSWORD="$P12_PASSWORD" \
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$(cygpath -w "$script")"

    echo
    echo "'firezone-client-tunnel.exe x509' prints what the Client makes of the store."
    echo
    echo "That store belongs to your account. The installed Tunnel service runs as LocalSystem and"
    echo "will not see it; give the service its own copy from an elevated PowerShell:"
    echo
    echo "    Import-PfxCertificate -FilePath '${p12_windows}' -CertStoreLocation Cert:\\LocalMachine\\My -Password (ConvertTo-SecureString -String '${P12_PASSWORD}' -AsPlainText -Force)"
}

if [ ! -f "$P12_PATH" ]; then
    echo "error: ${P12_PATH} does not exist; run 'mise run //:certificate' first" >&2
    exit 1
fi

case "$(uname -s)" in
Linux) install_linux ;;
MINGW* | MSYS* | CYGWIN*) install_windows ;;
Darwin)
    echo "error: on macOS, run 'mise run //swift/apple:install-certificate' instead" >&2
    exit 1
    ;;
*)
    echo "error: no keystore is supported on $(uname -s)" >&2
    exit 1
    ;;
esac
