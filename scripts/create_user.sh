#!/usr/bin/env bash
set -e

email="$(openssl rand -hex 2)@fireguard.local"
password="$(openssl rand -base64 12)"
/opt/fireguard/bin/fireguard eval "FgHttp.Users.create_user(
  email: \"${email}\",
  password: \"${password}\",
  password_confirmation: \"${password}\"
)"

echo "FireGuard user created! Save this information becasue it will NOT be shown again."
echo "Email: ${email}"
echo "Password: ${password}"
