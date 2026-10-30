use aya_ebpf::maps::PerCpuArray;

/// Updates the current CPU's value at `index` of `map` in place.
///
/// `PerCpuArray::get` only hands out shared references and `PerCpuArray::set` is a helper call,
/// which is comparatively expensive on every packet.
#[inline(always)]
pub fn update<T, R>(map: &PerCpuArray<T>, index: u32, f: impl FnOnce(&mut T) -> R) -> Option<R> {
    let value = map.get_ptr_mut(index)?;

    // SAFETY: Each CPU has its own value and eBPF programs run to completion without being
    // preempted, so nothing else references the current CPU's value while we hold it.
    Some(f(unsafe { &mut *value }))
}

/// Increments the current CPU's counter at `index` of `map`.
#[inline(always)]
pub fn increment(map: &PerCpuArray<u64>, index: u32) {
    update(map, index, |count| *count += 1);
}
