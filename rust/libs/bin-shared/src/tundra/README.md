Experimental: Firezone can use the Tundra driver instead of Wintun on Windows (x64 and ARM64). Tundra
exchanges IP packets through two rings shared with the driver, with segmentation offloads (TSO/USO
from the OS, RSC/GSO towards it) using the same `virtio_net_hdr` semantics as Linux TUN devices.

On this branch Tundra is the default. Set `FIREZONE_TUN_DRIVER=wintun` on the tunnel service to go
back to Wintun. If Tundra fails to start, Firezone logs the error and falls back to Wintun.

The driver packages in `bin/amd64` and `bin/arm64` are **test-signed** and come from the `tundra-x64` and
`tundra-arm64` artifacts of tundra CI run 36824593979 (firezone/tundra@f5c0972, driver version 0.1.0.15).
Firezone embeds the one matching the architecture it is built for. SHA256:

    amd64/tundra.sys  3b21effb5d48985887a52ca9f14b306c6a0243f1363141dd963669521f9226d2
    amd64/tundra.inf  272e39dc6a9ac4437cf532f414b3a4543e2ab43c8ec5a511f99b5904b4f6436a
    amd64/tundra.cat  36c836815de985d2b27b15d4e32f6727c4928db42034a05083466789394ee9ee
    arm64/tundra.sys  970dc05a6a436271100d62068c93310059a820acf620733cac9f4230b2a4bbb5
    arm64/tundra.inf  d1d957e29953158a5f4af6b92d1e34492d16825a27f728abaa3c1533d8d215e2
    arm64/tundra.cat  e98f887980cf4fa831cc550557473b22afefb64ca2b2e2c97919b51e3c3296af

The ARM64 driver is cross-compiled and passes the same static analysis, but hasn't run on ARM64 hardware yet.

## Machine setup (once)

Test-signed drivers only load with test signing enabled, which requires Secure Boot to be off.
Suspend BitLocker first so you won't be asked for the recovery key:

```powershell
# elevated
Suspend-BitLocker -MountPoint C: -RebootCount 2   # if BitLocker is on
bcdedit /set testsigning on                       # then disable Secure Boot in firmware if it fails, and reboot
bin\<arch>\install-dev.ps1                         # amd64 or arm64; trusts tundra-test.cer, adds the package
```

`install-dev.ps1` imports `tundra-test.cer` from its directory into `LocalMachine\Root` and `LocalMachine\TrustedPublisher`.
It also adds the package to the driver store. Firezone does that itself on startup anyway.
