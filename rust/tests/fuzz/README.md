# Fuzzing

Run with:

```
CARGO_PROFILE_RELEASE_LTO=false rustup run nightly cargo fuzz run --fuzz-dir tests/fuzz ip_packet_getters
```
