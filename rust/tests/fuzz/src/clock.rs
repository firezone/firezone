use std::time::Instant;

cfg_select! {
    target_os = "linux" => {
        use std::cell::Cell;

        thread_local! {
            static FIXED_CLOCK: Cell<bool> = const { Cell::new(false) };
        }

        /// Constructs a clock anchor with identical seconds and nanoseconds across processes.
        pub fn start_time() -> Instant {
            // Instant comparisons take different branches for equal seconds and unequal
            // seconds, even when relative deadlines are identical. Override only this
            // construction so simulation coverage is stable and replay timing stays real.
            FIXED_CLOCK.with(|fixed| {
                fixed.set(true);
                let start = Instant::now();
                fixed.set(false);

                start
            })
        }

        /// # Safety
        ///
        /// `time` must be null or valid for writing one `libc::timespec`.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn clock_gettime(
            clock: libc::clockid_t,
            time: *mut libc::timespec,
        ) -> libc::c_int {
            if clock == libc::CLOCK_MONOTONIC
                && !time.is_null()
                && FIXED_CLOCK.try_with(Cell::get).unwrap_or(false)
            {
                // SAFETY: The caller supplies a writable pointer, checked non-null above.
                unsafe {
                    time.write(libc::timespec {
                        tv_sec: 1_700_000,
                        tv_nsec: 0,
                    });
                }

                return 0;
            }

            // SAFETY: The syscall receives the unchanged clock ID and output pointer.
            unsafe { libc::syscall(libc::SYS_clock_gettime, clock, time) as libc::c_int }
        }
    }
    _ => {
        pub fn start_time() -> Instant {
            Instant::now()
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[test]
    fn anchors_are_fixed_and_the_wall_clock_keeps_advancing() {
        let before = Instant::now();
        let first = start_time();
        let second = start_time();
        let after = Instant::now();

        assert_eq!(first, second);
        assert!(after > before);
    }
}
