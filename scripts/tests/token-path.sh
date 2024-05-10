#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-headless-client
TOKEN="n.SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkN2RhN2QxY2QtMTExYy00NGE3LWI1YWMtNDAyN2I5ZDIzMGU1bQAAACtBaUl5XzZwQmstV0xlUkFQenprQ0ZYTnFJWktXQnMyRGR3XzJ2Z0lRdkZnbgYAGUmu74wBYgABUYA.UN3vSLLcAMkHeEh5VHumPOutkuue8JA6wlxM9JxJEPE"
TOKEN_PATH="token"

cd rust || exit 1
cargo build -p "$BINARY_NAME"
cd ..

sudo cp "rust/target/debug/$BINARY_NAME" "/usr/bin/$BINARY_NAME"

# Fails because there's no token yet
sudo "$BINARY_NAME" --check standalone && exit 1

# Pass if we use the env var
sudo FIREZONE_TOKEN="$TOKEN" "$BINARY_NAME" --check standalone

# Fails because passing tokens as CLI args is not allowed anymore
sudo "$BINARY_NAME" --check --token "$TOKEN" standalone && exit 1

touch "$TOKEN_PATH"
chmod 600 "$TOKEN_PATH"
sudo chown root:root "$TOKEN_PATH"
echo "$TOKEN" | sudo tee "$TOKEN_PATH" > /dev/null

# Fails because the token is not in the default path
sudo "$BINARY_NAME" --check standalone && exit 1

# Passes if we tell it where to look
sudo "$BINARY_NAME" --check --token-path "$TOKEN_PATH" standalone

# Move the token to the default path
sudo mkdir /etc/dev.firezone.client
sudo mv "$TOKEN_PATH" /etc/dev.firezone.client/token

# Now passes with the default path
sudo "$BINARY_NAME" --check standalone

# Redundant, but helps if the last command has an `&& exit 1`
exit 0
