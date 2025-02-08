# Define variables.
$PACKAGE_NAME = "firezone-headless-client"
$BINARY_NAME = "$PACKAGE_NAME.exe"
$TOKEN = "n.SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkN2RhN2QxY2QtMTExYy00NGE3LWI1YWMtNDAyN2I5ZDIzMGU1bQAAACtBaUl5XzZwQmstV0xlUkFQenprQ0ZYTnFJWktXQnMyRGR3XzJ2Z0lRdkZnbgYAGUmu74wBYgABUYA.UN3vSLLcAMkHeEh5VHumPOutkuue8JA6wlxM9JxJEPE"
$TOKEN_PATH = "token"

# Build the binary using cargo.
cargo build --manifest-path rust/Cargo.toml -p $PACKAGE_NAME
if ($LASTEXITCODE -ne 0) {
    Write-Error "Cargo build failed."
    exit 1
}

# Move the binary from rust/target/debug to the current directory.
Move-Item "rust/target/debug/$BINARY_NAME" $BINARY_NAME -Force

# -------------------------------------------------------------------
# Test 1: Should fail because there's no token yet.
& ".\$BINARY_NAME" --check standalone
if ($LASTEXITCODE -eq 0) {
    Write-Error "Test 1: Expected failure when no token is provided."
    exit 1
}

# -------------------------------------------------------------------
# Test 2: Pass if we use the environment variable.
$env:FIREZONE_TOKEN = $TOKEN
& ".\$BINARY_NAME" --check standalone
if ($LASTEXITCODE -ne 0) {
    Write-Error "Test 2: Expected success when token is provided via env var."
    exit 1
}
# Clear the environment variable after use.
Remove-Item Env:FIREZONE_TOKEN

# -------------------------------------------------------------------
# Test 3: Fails because passing tokens as CLI args is not allowed.
try {
    & ".\$BINARY_NAME" --check --token $TOKEN standalone
} catch {
    # Suppress the exception so the script can continue.
    Write-Verbose "Caught exception: $_"
}

if ($LASTEXITCODE -eq 0) {
    Write-Error "Test 3: Expected failure when token is passed as a CLI argument."
    exit 1
} else {
    Write-Host "Test 3 passed: Non-zero exit code detected."
}

# -------------------------------------------------------------------
# Create the token file (similar to 'touch').
New-Item -Path $TOKEN_PATH -ItemType File -Force | Out-Null

# Write the token to the file without adding a newline.
[System.IO.File]::WriteAllText($TOKEN_PATH, $TOKEN)

# -------------------------------------------------------------------
# Test 4: Fails because the token is not in the default path.
& ".\$BINARY_NAME" --check standalone
if ($LASTEXITCODE -eq 0) {
    Write-Error "Test 4: Expected failure when token file is in the wrong location."
    exit 1
}

# -------------------------------------------------------------------
# Test 5: Pass if we tell it where to look using the --token-path argument.
& ".\$BINARY_NAME" --check --token-path $TOKEN_PATH standalone
if ($LASTEXITCODE -ne 0) {
    Write-Error "Test 5: Expected success when specifying the token file location."
    exit 1
}

# -------------------------------------------------------------------
# Move the token file to the default path.
$defaultTokenDir = "$env:PROGRAMDATA\dev.firezone.client"
New-Item -ItemType Directory -Path $defaultTokenDir -Force | Out-Null
Move-Item -Path $TOKEN_PATH -Destination "$defaultTokenDir\token.txt" -Force

# Show the contents of the default token directory.
Get-ChildItem -Path $defaultTokenDir

# -------------------------------------------------------------------
# Test 6: Now the binary should pass using the token in the default path.
& ".\$BINARY_NAME" --check standalone
if ($LASTEXITCODE -ne 0) {
    Write-Error "Test 6: Expected success when the token is in the default path."
    exit 1
}

# -------------------------------------------------------------------
# Test 7: Fails because the user is not allowed to read the token
# TODO: Implement this test. Requires implementing the check_token_permissions
# function in rust/headless-client/src/windows.rs

# Redundant exit with success.
exit 0
