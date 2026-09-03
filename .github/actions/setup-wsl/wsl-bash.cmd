@echo off
:: Runs a step's script inside WSL as root, so that steps can use
:: `shell: wsl-bash {0}`. The script is handed over as an environment variable
:: rather than as an argument, both because `WSLENV`'s `/p` flag translates the
:: Windows path the runner passes into the WSL one, and because an argument
:: does not survive `wsl.exe`. The runner writes the file with CRLF line
:: endings, which bash would otherwise read as part of each command.
set "WSL_BASH_SCRIPT=%~1"
set "WSLENV=WSL_BASH_SCRIPT/p"
wsl.exe -u root -- bash -c "sed -i 's/\r$//' \"$WSL_BASH_SCRIPT\"; exec bash -euo pipefail \"$WSL_BASH_SCRIPT\""
