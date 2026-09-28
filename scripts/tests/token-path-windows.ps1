# Define variables.
$PACKAGE_NAME = "firezone-headless-client"
$BINARY_NAME = "$PACKAGE_NAME.exe"
$TOKEN = "n.SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkN2RhN2QxY2QtMTExYy00NGE3LWI1YWMtNDAyN2I5ZDIzMGU1bQAAACtBaUl5XzZwQmstV0xlUkFQenprQ0ZYTnFJWktXQnMyRGR3XzJ2Z0lRdkZnbgYAGUmu74wBYgABUYA.UN3vSLLcAMkHeEh5VHumPOutkuue8JA6wlxM9JxJEPE"
$TOKEN_PATH = "token"

# Restrict the file to SYSTEM and BUILTIN\Administrators.
function Set-TokenAcl($Path) {
    icacls $Path /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to restrict ACL of $Path."
        exit 1
    }
}

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
Set-TokenAcl $TOKEN_PATH

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
$defaultTokenPath = "$defaultTokenDir\token.txt"
New-Item -ItemType Directory -Path $defaultTokenDir -Force | Out-Null
Move-Item -Path $TOKEN_PATH -Destination $defaultTokenPath -Force

# A move across volumes may not preserve the ACL.
Set-TokenAcl $defaultTokenPath

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
# Test 7: Fails because BUILTIN\Users are allowed to read the token.
icacls $defaultTokenPath /grant "*S-1-5-32-545:R" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to grant BUILTIN\Users read access to $defaultTokenPath."
    exit 1
}

& ".\$BINARY_NAME" --check standalone
if ($LASTEXITCODE -eq 0) {
    Write-Error "Test 7: Expected failure when the token file is readable by users."
    exit 1
}

# Redundant exit with success.
exit 0
