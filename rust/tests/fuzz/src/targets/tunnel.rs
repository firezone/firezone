//! Exercises the connlib tunnel state machine with coverage-guided fuzzing.

pub fn test(data: &[u8]) {
    simulation::tunnel::run(data, *crate::START_TIME);
}
