// Copyright (c) 2019 Cloudflare, Inc. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

use super::Error;
use libc::*;
use parking_lot::Mutex;
use std::io;
use std::ops::Deref;
use std::os::unix::io::RawFd;
use std::ptr::null_mut;
use std::time::Duration;

/// A return type for the EventPoll::wait() function
pub enum WaitResult<'a, H> {
    /// Event triggered normally
    Ok(EventGuard<'a, H>),
    /// Event triggered due to End of File conditions
    EoF(EventGuard<'a, H>),
    /// There was an error
    Error(String),
}

/// Implements a registry of pollable events
pub struct EventPoll<H: Sized> {
    events: Mutex<Vec<Option<Box<Event<H>>>>>,
    epoll: RawFd, // The OS epoll
}

/// A type that hold a reference to a triggered Event
/// While an EventGuard exists for a given Event, it will not be triggered by any other thread
/// Once the EventGuard goes out of scope, the underlying Event will be re-enabled
pub struct EventGuard<'a, H> {
    epoll: RawFd,
    event: &'a mut Event<H>,
    poll: &'a EventPoll<H>,
}

/// A reference to a single event in an EventPoll
pub struct EventRef {
    trigger: RawFd,
}

struct Event<H> {
    event: epoll_event, // The epoll event description
    fd: RawFd,          // The associated fd
    handler: H,         // The associated data
    notifier: bool,     // Is a notification event
    needs_read: bool,   // This event needs to be read to be cleared
}

impl<H> Drop for EventPoll<H> {
    fn drop(&mut self) {
        unsafe { close(self.epoll) };
    }
}

impl<H: Sync + Send> EventPoll<H> {
    /// Create a new event registry
    pub fn new() -> Result<EventPoll<H>, Error> {
        let epoll = match unsafe { epoll_create(1) } {
            -1 => return Err(Error::EventQueue(io::Error::last_os_error())),
            epoll => epoll,
        };

        Ok(EventPoll {
            events: Mutex::new(vec![]),
            epoll,
        })
    }

    /// Add and enable a new event with the factory.
    /// The event is triggered when a Read operation on the provided trigger becomes available
    /// If the trigger fd is closed, the event won't be triggered anymore, but it's data won't be
    /// automatically released.
    /// The safe way to delete an event, is using the cancel method of an EventGuard.
    /// If the same trigger is used with multiple events in the same EventPoll, the last added
    /// event overrides all previous events. In case the same trigger is used with multiple polls,
    /// each event will be triggered independently.
    /// The event will keep triggering until a Read operation is no longer possible on the trigger.
    /// When triggered, one of the threads waiting on the poll will receive the handler via an
    /// appropriate EventGuard. It is guaranteed that only a single thread can have a reference to
    /// the handler at any given time.
    pub fn new_event(&self, trigger: RawFd, handler: H) -> Result<EventRef, Error> {
        // Create an event descriptor
        let flags = EPOLLIN | EPOLLONESHOT;
        let ev = Event {
            event: epoll_event {
                events: flags as _,
                u64: 0,
            },
            fd: trigger,
            handler,
            notifier: false,
            needs_read: false,
        };

        self.register_event(ev)
    }

    /// Add and enable a new write event with the factory.
    /// The event is triggered when a Write operation on the provided trigger becomes possible
    /// For TCP sockets it means that the socket was succesfully connected
    #[allow(dead_code)]
    pub fn new_write_event(&self, trigger: RawFd, handler: H) -> Result<EventRef, Error> {
        // Create an event descriptor
        let flags = EPOLLOUT | EPOLLET | EPOLLONESHOT;
        let ev = Event {
            event: epoll_event {
                events: flags as _,
                u64: 0,
            },
            fd: trigger,
            handler,
            notifier: false,
            needs_read: false,
        };

        self.register_event(ev)
    }

    /// Add and enable a new timed event with the factory.
    /// The even will be triggered for the first time after period time, and henceforth triggered
    /// every period time. Period is counted from the moment the appropriate EventGuard is released.
    pub fn new_periodic_event(&self, handler: H, period: Duration) -> Result<EventRef, Error> {
        // The periodic event on Linux uses the timerfd
        let tfd = match unsafe { timerfd_create(CLOCK_BOOTTIME, TFD_NONBLOCK) } {
            -1 => match unsafe { timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK) } {
                // A fallback for kernels < 3.15
                -1 => return Err(Error::Timer(io::Error::last_os_error())),
                efd => efd,
            },
            efd => efd,
        };

        let ts = timespec {
            tv_sec: period.as_secs() as _,
            tv_nsec: i64::from(period.subsec_nanos()) as _,
        };

        let spec = itimerspec {
            it_value: ts,
            it_interval: ts,
        };

        if unsafe { timerfd_settime(tfd, 0, &spec, std::ptr::null_mut()) } == -1 {
            unsafe { close(tfd) };
            return Err(Error::Timer(io::Error::last_os_error()));
        }

        let ev = Event {
            event: epoll_event {
                events: (EPOLLIN | EPOLLONESHOT) as _,
                u64: 0,
            },
            fd: tfd,
            handler,
            notifier: false,
            needs_read: true,
        };

        self.register_event(ev)
    }

    /// Add and enable a new notification event with the factory.
    /// The event can only be triggered manually, using the trigger_notification method.
    /// The event will remain in a triggered state until the stop_notification method is
    /// called. Both methods should only be called with the producing EventPoll.
    pub fn new_notifier(&self, handler: H) -> Result<EventRef, Error> {
        // The notifier on Linux uses the eventfd for notifications.
        // The way it works is when a non zero value is written into the eventfd it will trigger
        // the EPOLLIN event. Since we don't enable ONESHOT it will keep triggering until
        // canceled.
        // When we want to stop the event, we read something once from the file descriptor.
        let efd = match unsafe { eventfd(0, EFD_NONBLOCK) } {
            -1 => return Err(Error::EventQueue(io::Error::last_os_error())),
            efd => efd,
        };

        let ev = Event {
            event: epoll_event {
                events: (EPOLLIN) as _,
                u64: 0,
            },
            fd: efd,
            handler,
            notifier: true,
            needs_read: false,
        };

        self.register_event(ev)
    }

    /// Add and enable a new signal handler
    pub fn new_signal_event(&self, signal: c_int, handler: H) -> Result<EventRef, Error> {
        let sfd = match unsafe {
            let mut sigset = std::mem::zeroed();
            sigemptyset(&mut sigset);
            sigaddset(&mut sigset, signal);
            sigprocmask(SIG_BLOCK, &sigset, null_mut());
            signalfd(-1, &sigset, SFD_NONBLOCK)
        } {
            -1 => return Err(Error::EventQueue(io::Error::last_os_error())),
            sfd => sfd,
        };

        let ev = Event {
            event: epoll_event {
                events: (EPOLLIN | EPOLLONESHOT) as _,
                u64: 0,
            },
            fd: sfd,
            handler,
            notifier: false,
            needs_read: true,
        };

        self.register_event(ev)
    }

    /// Wait until one of the registered events becomes triggered. Once an event
    /// is triggered, a single caller thread gets the handler for that event.
    /// In case a notifier is triggered, all waiting threads will receive the same
    /// handler.
    pub fn wait(&self) -> WaitResult<'_, H> {
        let mut event = epoll_event { events: 0, u64: 0 };
        match unsafe { epoll_wait(self.epoll, &mut event, 1, -1) } {
            -1 => return WaitResult::Error(io::Error::last_os_error().to_string()),
            1 => {}
            _ => return WaitResult::Error("unexpected number of events returned".to_string()),
        }

        let event_data = unsafe { (event.u64 as *mut Event<H>).as_mut().unwrap() };

        let guard = EventGuard {
            epoll: self.epoll,
            event: event_data,
            poll: self,
        };

        if event.events & EPOLLHUP as u32 != 0 {
            // End of file flag
            WaitResult::EoF(guard)
        } else {
            WaitResult::Ok(guard)
        }
    }

    // Register an event with this poll.
    fn register_event(&self, ev: Event<H>) -> Result<EventRef, Error> {
        // To register an event we
        // * Create a reference to self in the inner event
        // * Store the Event in the events vector
        // * Dispose of a previous Event under same fd if any
        // * Add the Event to epoll
        let trigger = ev.fd;
        let mut ev = Box::new(ev);
        // The inner event points back to the wrapper
        ev.event.u64 = ev.as_mut() as *mut Event<H> as _;
        let mut event_desc = ev.event;
        // Now add the pointer to the events vector, this is a place from which we can drop the event
        self.insert_at(trigger as _, ev);
        // Add the event to epoll
        if unsafe { epoll_ctl(self.epoll, EPOLL_CTL_ADD, trigger, &mut event_desc) } == -1 {
            return Err(Error::EventQueue(io::Error::last_os_error()));
        }

        Ok(EventRef { trigger })
    }

    // Insert an event into the events vector
    fn insert_at(&self, index: usize, data: Box<Event<H>>) {
        let mut events = self.events.lock();
        while events.len() <= index {
            // Resize the vector to be able to fit the new index
            // We trust the OS to allocate file descriptors in a sane order
            events.push(None); // resize doesn't work because Clone is not satisfied
        }

        if events[index].take().is_some() {
            // Properly remove the previous event first
            unsafe {
                epoll_ctl(self.epoll, EPOLL_CTL_DEL, index as _, null_mut());
            };
        }

        events[index] = Some(data);
    }

    /// Trigger a notification
    pub fn trigger_notification(&self, notification_event: &EventRef) {
        let events = self.events.lock();

        let event_ref = &(*events)[notification_event.trigger as usize];
        let event_data = event_ref.as_ref().expect("Expected an event");

        if !event_data.notifier {
            panic!("Can only trigger a notification event");
        }

        // Write some data to the eventfd to trigger an EPOLLIN event
        unsafe {
            write(
                notification_event.trigger,
                &(std::u64::MAX - 1).to_ne_bytes()[0] as *const u8 as _,
                8,
            )
        };
    }

    /// Stop a notification
    pub fn stop_notification(&self, notification_event: &EventRef) {
        let events = self.events.lock();

        let event_ref = &(*events)[notification_event.trigger as usize];
        let event_data = event_ref.as_ref().expect("Expected an event");

        if !event_data.notifier {
            panic!("Can only trigger a notification event");
        }

        let mut buf = [0u8; 8];
        unsafe {
            read(
                notification_event.trigger,
                buf.as_mut_ptr() as _,
                buf.len() as _,
            )
        };
    }
}

impl<H> EventPoll<H> {
    /// Disable and remove the event and associated handler, using the fd that
    /// was used to register it.
    ///
    /// # Safety
    ///
    /// This function is only safe to call when the event loop is not running,
    /// otherwise the memory of the handler may get freed while in use.
    pub unsafe fn clear_event_by_fd(&self, index: RawFd) {
        let mut events = self.events.lock();
        assert!(index >= 0);
        if events[index as usize].take().is_some() {
            epoll_ctl(self.epoll, EPOLL_CTL_DEL, index, null_mut());
        }
    }
}

impl<'a, H> Deref for EventGuard<'a, H> {
    type Target = H;
    fn deref(&self) -> &H {
        &self.event.handler
    }
}

impl<'a, H> Drop for EventGuard<'a, H> {
    fn drop(&mut self) {
        if self.event.needs_read {
            // Must read from the event to reset it before we enable it
            let mut buf: [std::mem::MaybeUninit<u8>; 256] =
                unsafe { std::mem::MaybeUninit::uninit().assume_init() };
            while unsafe { read(self.event.fd, buf.as_mut_ptr() as _, buf.len() as _) } != -1 {}
        }

        unsafe {
            epoll_ctl(
                self.epoll,
                EPOLL_CTL_MOD,
                self.event.fd,
                &mut self.event.event,
            );
        }
    }
}

impl<'a, H> EventGuard<'a, H> {
    /// Get a mutable reference to the stored value
    #[allow(dead_code)]
    pub fn get_mut(&mut self) -> &mut H {
        &mut self.event.handler
    }

    /// Cancel and remove the event referenced by this guard
    pub fn cancel(self) {
        unsafe { self.poll.clear_event_by_fd(self.event.fd) };
        std::mem::forget(self); // Don't call the regular drop that would enable the event
    }

    pub fn fd(&self) -> i32 {
        self.event.fd
    }

    /// Change the event flags to enable or disable notifying when the fd is writable
    pub fn notify_writable(&mut self, enabled: bool) {
        let flags = if enabled {
            EPOLLOUT | EPOLLIN | EPOLLET | EPOLLONESHOT
        } else {
            EPOLLIN | EPOLLONESHOT
        };
        self.event.event.events = flags as _;
    }
}

pub fn block_signal(signal: c_int) -> Result<sigset_t, String> {
    unsafe {
        let mut sigset = std::mem::zeroed();
        sigemptyset(&mut sigset);
        if sigaddset(&mut sigset, signal) == -1 {
            return Err(io::Error::last_os_error().to_string());
        }
        if sigprocmask(SIG_BLOCK, &sigset, null_mut()) == -1 {
            return Err(io::Error::last_os_error().to_string());
        }
        Ok(sigset)
    }
}
