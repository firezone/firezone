use core::time::Duration;

/// A monotonic instant captured by the BPF `bpf_ktime_get_ns` helper.
///
/// Equivalent in spirit to [`std::time::Instant`], but usable from XDP/BPF
/// programs where `std` is unavailable. Backed by `CLOCK_MONOTONIC`.
#[derive(Copy, Clone)]
pub struct KernelInstant(u64);

impl KernelInstant {
    #[inline]
    pub fn now() -> Self {
        Self(ktime_get_ns())
    }

    #[inline]
    pub fn duration_since(self, earlier: Self) -> Duration {
        Duration::from_nanos(self.0.saturating_sub(earlier.0))
    }

    #[inline]
    pub fn elapsed(self) -> Duration {
        Self::now().duration_since(self)
    }
}

#[inline]
fn ktime_get_ns() -> u64 {
    // SAFETY: `bpf_ktime_get_ns` is a parameterless BPF kernel helper that
    // cannot fault and is always safe to call from any BPF program context.
    unsafe { aya_ebpf::helpers::bpf_ktime_get_ns() }
}
