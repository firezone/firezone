# Mirror of `download.sh` for the Windows headless Client: fetch a
# deterministic 10 MB payload from the HTTP test server behind the seeded
# CIDR resource (`10.20.0.0/16`) and verify its checksum.
#
# Expects the Linux half of the topology
# (scripts/compose/windows-client-test.yml) to be up inside WSL2 and the
# Client to be connected already; see
# .github/workflows/_windows_integration_tests.yml.

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# Abort only if the transfer stalls (speed stays below 100 KiB/s for 10s)
# rather than on a fixed deadline: a slow-but-progressing download on a busy
# runner is fine, a hung tunnel is not. The connect timeout is more generous
# than in `download.sh` because this first packet also sets up the connection
# to the gateway.
curl.exe --fail --connect-timeout 30 --speed-limit 102400 --speed-time 10 --output download.file "http://10.20.0.100/bytes?num=10000000"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Download through the tunnel failed"
    exit 1
}

$knownChecksum = "f5e02aa71e67f41d79023a128ca35bad86cf7b6656967bfe0884b3a3c4325eaf"
$computedChecksum = (Get-FileHash -Algorithm SHA256 download.file).Hash.ToLower()
if ($computedChecksum -ne $knownChecksum) {
    Write-Error "Checksum of downloaded file does not match: $computedChecksum"
    exit 1
}

Write-Host "Download through the tunnel succeeded"
