#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-linux-client
TOKEN_PATH="token.txt"

docker compose exec client cat firezone-linux-client > "$BINARY_NAME"
chmod u+x "$BINARY_NAME"
sudo chown root:root "$BINARY_NAME"
sudo mv "$BINARY_NAME" "/usr/bin/$BINARY_NAME"

# Check should fail because there's no token yet
sudo "$BINARY_NAME" standalone --check && exit 1

touch "$TOKEN_PATH"
chmod 600 "$TOKEN_PATH"
echo "n.SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkN2RhN2QxY2QtMTExYy00NGE3LWI1YWMtNDAyN2I5ZDIzMGU1bQAAACtBaUl5XzZwQmstV0xlUkFQenprQ0ZYTnFJWktXQnMyRGR3XzJ2Z0lRdkZnbgYAGUmu74wBYgABUYA.UN3vSLLcAMkHeEh5VHumPOutkuue8JA6wlxM9JxJEPE" | sudo tee "$TOKEN_PATH" > /dev/null

# Check should fail because the token is not in the default path
sudo "$BINARY_NAME" --check standalone && exit 1

# Check should pass if we tell it where to look
sudo "$BINARY_NAME" --check --token-path "$TOKEN_PATH" standalone

# Move the token to the default path
sudo mkdir /etc/dev.firezone.client
sudo mv "$TOKEN_PATH" /etc/dev.firezone.client/token.txt

# Check should now pass with the default path
sudo "$BINARY_NAME" --check standalone

# Redundant, but helps if the last command has an `&& exit 1`
exit 0
