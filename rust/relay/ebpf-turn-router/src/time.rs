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
        // SAFETY: `bpf_ktime_get_ns` is a parameterless BPF kernel helper that
        // cannot fault and is always safe to call from any BPF program context.
        Self(unsafe { aya_ebpf::helpers::bpf_ktime_get_ns() })
    }

    /// Like [`KernelInstant::now`] but only as precise as the scheduler tick, which makes it much cheaper.
    #[inline]
    pub fn now_coarse() -> Self {
        // SAFETY: `bpf_ktime_get_coarse_ns` is a parameterless BPF kernel helper that
        // cannot fault and is always safe to call from any BPF program context.
        Self(unsafe { aya_ebpf::helpers::bpf_ktime_get_coarse_ns() })
    }

    #[inline]
    pub fn as_nanos(self) -> u64 {
        self.0
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
