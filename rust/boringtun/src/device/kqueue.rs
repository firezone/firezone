// Copyright (c) 2019 Cloudflare, Inc. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

use super::Error;
use libc::*;
use parking_lot::Mutex;
use std::io;
use std::ops::Deref;
use std::os::unix::io::RawFd;
use std::ptr::{null, null_mut};
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
    events: Mutex<Vec<Option<Box<Event<H>>>>>, // Events with a file descriptor
    custom: Mutex<Vec<Option<Box<Event<H>>>>>, // Other events (i.e. timers & notifiers)
    signals: Mutex<Vec<Option<Box<Event<H>>>>>, // Signal handlers
    kqueue: RawFd,                             // The OS kqueue
}

/// A type that hold a reference to a triggered Event
/// While an EventGuard exists for a given Event, it will not be triggered by any other thread
/// Once the EventGuard goes out of scope, the underlying Event will be re-enabled
pub struct EventGuard<'a, H> {
    kqueue: RawFd,
    event: &'a Event<H>,
    poll: &'a EventPoll<H>,
}

/// A reference to a single event in an EventPoll
pub struct EventRef {
    trigger: RawFd,
}

#[derive(PartialEq)]
enum EventKind {
    FD,
    Notifier,
    Signal,
    Timer,
}

// A single event
struct Event<H> {
    event: kevent, // The kqueue event description
    handler: H,    // The associated data
    kind: EventKind,
}

impl<H> Drop for EventPoll<H> {
    fn drop(&mut self) {
        unsafe { close(self.kqueue) };
    }
}

unsafe impl<H> Send for EventPoll<H> {}
unsafe impl<H> Sync for EventPoll<H> {}

impl<H: Send + Sync> EventPoll<H> {
    /// Create a new event registry
    pub fn new() -> Result<EventPoll<H>, Error> {
        let kqueue = match unsafe { kqueue() } {
            -1 => return Err(Error::EventQueue(io::Error::last_os_error())),
            kqueue => kqueue,
        };

        Ok(EventPoll {
            events: Mutex::new(vec![]),
            custom: Mutex::new(vec![]),
            signals: Mutex::new(vec![]),
            kqueue,
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
        let flags = EV_ENABLE | EV_DISPATCH;

        let ev = Event {
            event: kevent {
                ident: trigger as _,
                filter: EVFILT_READ,
                flags,
                fflags: 0,
                data: 0,
                udata: null_mut(),
            },
            handler,
            kind: EventKind::FD,
        };

        self.register_event(ev)
    }

    pub fn new_periodic_event(&self, handler: H, period: Duration) -> Result<EventRef, Error> {
        // The periodic event in BSD uses EVFILT_TIMER
        let ev = Event {
            event: kevent {
                ident: 0,
                filter: EVFILT_TIMER,
                flags: EV_ENABLE | EV_DISPATCH,
                fflags: NOTE_NSECONDS,
                data: period
                    .as_secs()
                    .checked_mul(1_000_000_000)
                    .unwrap()
                    .checked_add(u64::from(period.subsec_nanos()))
                    .unwrap() as _,
                udata: null_mut(),
            },
            handler,
            kind: EventKind::Timer,
        };

        self.register_event(ev)
    }

    pub fn new_notifier(&self, handler: H) -> Result<EventRef, Error> {
        // The notifier in BSD uses EVFILT_USER for notifications.
        let ev = Event {
            event: kevent {
                ident: 0,
                filter: EVFILT_USER,
                flags: EV_ENABLE,
                fflags: 0,
                data: 0,
                udata: null_mut(),
            },
            handler,
            kind: EventKind::Notifier,
        };

        self.register_event(ev)
    }

    /// Add and enable a new signal handler
    pub fn new_signal_event(&self, signal: c_int, handler: H) -> Result<EventRef, Error> {
        let ev = Event {
            event: kevent {
                ident: signal as _,
                filter: EVFILT_SIGNAL,
                flags: EV_ENABLE | EV_DISPATCH,
                fflags: 0,
                data: 0,
                udata: null_mut(),
            },
            handler,
            kind: EventKind::Signal,
        };

        self.register_event(ev)
    }

    /// Wait until one of the registered events becomes triggered. Once an event
    /// is triggered, a single caller thread gets the handler for that event.
    /// In case a notifier is triggered, all waiting threads will receive the same
    /// handler.
    pub fn wait(&'_ self) -> WaitResult<'_, H> {
        let mut event = kevent {
            ident: 0,
            filter: 0,
            flags: 0,
            fflags: 0,
            data: 0,
            udata: null_mut(),
        };

        if unsafe { kevent(self.kqueue, null(), 0, &mut event, 1, null()) } == -1 {
            return WaitResult::Error(io::Error::last_os_error().to_string());
        }

        let event_data = unsafe { (event.udata as *mut Event<H>).as_ref().unwrap() };

        let guard = EventGuard {
            kqueue: self.kqueue,
            event: event_data,
            poll: self,
        };

        if event.flags & EV_EOF != 0 {
            WaitResult::EoF(guard)
        } else {
            WaitResult::Ok(guard)
        }
    }

    // Register an event with this poll.
    fn register_event(&self, ev: Event<H>) -> Result<EventRef, Error> {
        let mut events = match ev.kind {
            EventKind::FD => self.events.lock(),
            EventKind::Timer | EventKind::Notifier => self.custom.lock(),
            EventKind::Signal => self.signals.lock(),
        };

        let (trigger, index) = match ev.kind {
            EventKind::FD | EventKind::Signal => (ev.event.ident as RawFd, ev.event.ident as usize),
            EventKind::Timer | EventKind::Notifier => (-(events.len() as RawFd) - 1, events.len()), // Custom events get negative identifiers, hopefully we will never have more than 2^31 events of each type
        };

        // Expand events vector if needed
        while events.len() <= index {
            // Resize the vector to be able to fit the new index
            // We trust the OS to allocate file descriptors in a sane order
            events.push(None); // resize doesn't work because Clone is not satisfied
        }

        let mut ev = Box::new(ev);
        // The inner event points back to the wrapper
        ev.event.ident = trigger as _;
        ev.event.udata = ev.as_mut() as *mut Event<H> as _;

        let mut kev = ev.event;
        kev.flags |= EV_ADD;

        if unsafe { kevent(self.kqueue, &kev, 1, null_mut(), 0, null()) } == -1 {
            return Err(Error::EventQueue(io::Error::last_os_error()));
        }

        if let Some(mut event) = events[index].take() {
            // Properly remove any previous event first
            event.event.flags = EV_DELETE;
            unsafe { kevent(self.kqueue, &event.event, 1, null_mut(), 0, null()) };
        }

        if ev.kind == EventKind::Signal {
            // Mask the signal if successfully added to kqueue
            unsafe { signal(trigger, SIG_IGN) };
        }

        events[index] = Some(ev);

        Ok(EventRef { trigger })
    }

    pub fn trigger_notification(&self, notification_event: &EventRef) {
        let events = self.custom.lock();
        let ev_index = -notification_event.trigger - 1; // Custom events have negative index from -1

        let event_ref = &(*events)[ev_index as usize];
        let event_data = event_ref.as_ref().expect("Expected an event");

        if event_data.kind != EventKind::Notifier {
            panic!("Can only trigger a notification event");
        }

        let mut kev = event_data.event;
        kev.fflags = NOTE_TRIGGER;

        unsafe { kevent(self.kqueue, &kev, 1, null_mut(), 0, null()) };
    }

    pub fn stop_notification(&self, notification_event: &EventRef) {
        let events = self.custom.lock();
        let ev_index = -notification_event.trigger - 1; // Custom events have negative index from -1

        let event_ref = &(*events)[ev_index as usize];
        let event_data = event_ref.as_ref().expect("Expected an event");

        if event_data.kind != EventKind::Notifier {
            panic!("Can only stop a notification event");
        }

        let mut kev = event_data.event;
        kev.flags = EV_DISABLE;
        kev.fflags = 0;

        unsafe { kevent(self.kqueue, &kev, 1, null_mut(), 0, null()) };
    }
}

impl<H> EventPoll<H> {
    // This function is only safe to call when the event loop is not running
    pub unsafe fn clear_event_by_fd(&self, index: RawFd) {
        let (mut events, index) = if index >= 0 {
            (self.events.lock(), index as usize)
        } else {
            (self.custom.lock(), (-index - 1) as usize)
        };

        if let Some(mut event) = events[index].take() {
            // Properly remove any previous event first
            event.event.flags = EV_DELETE;
            kevent(self.kqueue, &event.event, 1, null_mut(), 0, null());
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
        unsafe {
            // Re-enable the event once EventGuard goes out of scope
            kevent(self.kqueue, &self.event.event, 1, null_mut(), 0, null());
        }
    }
}

impl<'a, H> EventGuard<'a, H> {
    /// Cancel and remove the event represented by this guard
    pub fn cancel(self) {
        unsafe { self.poll.clear_event_by_fd(self.event.event.ident as RawFd) };
        std::mem::forget(self); // Don't call the regular drop that would enable the event
    }

    /// Stub: only used for Linux-specific features.
    pub fn fd(&self) -> i32 {
        -1
    }
}
