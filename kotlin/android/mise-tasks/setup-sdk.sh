#!/usr/bin/env bash
#MISE description="Install the Android command-line tools and platform-tools into the SDK"
set -euo pipefail

# `kotlin/android/mise.toml` resolves ANDROID_HOME and puts the SDK's tool directories on PATH; this
# task fills those directories in.
#
# The command-line tools cannot be a mise `[tools]` entry: `avdmanager` derives the SDK root from its
# own location rather than from ANDROID_HOME, so it only finds system images when it sits at
# `$ANDROID_HOME/cmdline-tools/<version>/bin`. Installing them there keeps every SDK tool agreeing on
# which SDK it is looking at.
: "${ANDROID_HOME:?run this through mise so ANDROID_HOME is set}"
: "${ANDROID_CMD_TOOLS_VERSION:?run this through mise so ANDROID_CMD_TOOLS_VERSION is set}"

CMD_TOOLS_DIR="$ANDROID_HOME/cmdline-tools/latest"
SDKMANAGER="$CMD_TOOLS_DIR/bin/sdkmanager"

case "$(uname -s)" in
Linux)
    CMD_TOOLS_PLATFORM="linux"
    ;;
Darwin)
    CMD_TOOLS_PLATFORM="mac"
    ;;
*)
    echo "Unsupported platform: $(uname -s). Install the Android command-line tools manually." >&2
    exit 1
    ;;
esac

if [ ! -x "$SDKMANAGER" ]; then
    echo "==> Installing Android command-line tools ${ANDROID_CMD_TOOLS_VERSION} into ${ANDROID_HOME}..."
    mkdir -p "$ANDROID_HOME/cmdline-tools"

    tools_zip="$(mktemp)"
    curl -fsSL -o "$tools_zip" \
        "https://dl.google.com/android/repository/commandlinetools-${CMD_TOOLS_PLATFORM}-${ANDROID_CMD_TOOLS_VERSION}_latest.zip"

    # The zip unpacks as a directory called `cmdline-tools`, so it is staged next to its destination
    # and moved into place rather than unpacked over it.
    staging="$(mktemp -d)"
    unzip -qo "$tools_zip" -d "$staging"
    rm -rf "$CMD_TOOLS_DIR"
    mv "$staging/cmdline-tools" "$CMD_TOOLS_DIR"
    rm -rf "$tools_zip" "$staging"
fi

if ! "$SDKMANAGER" --version >/dev/null 2>&1; then
    echo "${SDKMANAGER} is not runnable; check that a JDK is installed." >&2
    exit 1
fi

if [ ! -x "$ANDROID_HOME/platform-tools/adb" ]; then
    echo "==> Accepting Android SDK licenses..."
    # `yes | sdkmanager` exits non-zero via SIGPIPE once sdkmanager closes stdin.
    yes 2>/dev/null | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true

    echo "==> Installing platform-tools..."
    "$SDKMANAGER" --sdk_root="$ANDROID_HOME" "platform-tools" >/dev/null
fi
