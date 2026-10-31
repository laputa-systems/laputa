//! Exercises clock stepping for offsets in both directions.
use std::{future::{Future, pending}, pin::pin, sync::{Arc, Mutex}, task::{Context, Poll, Wake, Waker}};

use statime_algo::{ClockConfig, ControllerConfig, KalmanController, LinkConfig, StdKalmanStorage, TrackedLinkConfig};
use statime_base::{Clock, ClockError, Controller, Direction, Duration, LeapStatus, Link, Measurement, TAI, Timestamp};

#[derive(Clone, Default)]
struct TestClock {
    steps: Arc<Mutex<Vec<f64>>>,
    synchronized: Arc<Mutex<Vec<bool>>>,
}

impl Clock<TAI> for TestClock {
    fn now(&self) -> Result<Timestamp<TAI>, ClockError> { Ok(Timestamp::UNIX_EPOCH) }
    fn max_frequency(&self) -> Result<f64, ClockError> { Ok(0.0005) }
    fn get_frequency(&self) -> Result<f64, ClockError> { Ok(0.0) }
    fn set_frequency(&self, _: f64) -> Result<Timestamp<TAI>, ClockError> { self.now() }
    fn step_clock(&self, step: Duration) -> Result<Timestamp<TAI>, ClockError> {
        self.steps.lock().unwrap().push(step.as_seconds());
        self.now()
    }
    fn error_estimate_update(&self, _: Duration, _: Duration) -> Result<(), ClockError> { Ok(()) }
    fn leap_update(&self, _: LeapStatus) -> Result<(), ClockError> { Ok(()) }
    fn synchronization_update(&self, value: bool) -> Result<(), ClockError> {
        self.synchronized.lock().unwrap().push(value);
        Ok(())
    }
}

struct Noop;
impl Wake for Noop { fn wake(self: Arc<Self>) {} }

fn steer(remote_offset: i64) -> (f64, Vec<f64>, Vec<bool>) {
    let clock = TestClock::default();
    let (controller, clock_id) = KalmanController::<StdKalmanStorage<_>, _>::new(
        clock.clone(), ClockConfig::default(), ControllerConfig {
            select_offset_uncertainty_window: 1.0,
            select_link_uncertainty_window: 2.0,
            select_delay_uncertainty_window: 0.5,
            select_max_window_size: 0.5,
            minimum_agreeing_sources: 1,
        },
    ).unwrap();
    let controller = Arc::new(controller);
    let link = KalmanController::create_tracked_link(
        controller.clone(), clock_id, None, LinkConfig::default(), TrackedLinkConfig::default(),
    ).unwrap();
    link.external_data_update(Duration::ZERO, Some(LeapStatus::None), true).unwrap();
    let local = Timestamp::UNIX_EPOCH;
    let remote = local + Duration::from_seconds_nanos(remote_offset, 0);
    let uncertainty = Duration::from_seconds_nanos(0, 1_000_000);
    for _ in 0..10 {
        link.measurement(Measurement { send_timestamp: local, recv_timestamp: remote, uncertainty }, Direction::Forward).unwrap();
        link.measurement(Measurement { send_timestamp: remote, recv_timestamp: local, uncertainty }, Direction::Reverse).unwrap();
    }
    let offset = controller.clock_offset(clock_id).unwrap();
    let mut run = pin!(KalmanController::run(controller.clone(), |_| pending()));
    let waker = Waker::from(Arc::new(Noop));
    assert!(matches!(run.as_mut().poll(&mut Context::from_waker(&waker)), Poll::Pending));
    let steps = clock.steps.lock().unwrap().clone();
    let synchronized = clock.synchronized.lock().unwrap().clone();
    (offset.value, steps, synchronized)
}

#[test]
fn large_offsets_step_in_both_directions() {
    for remote_offset in [-20, 20] {
        let (offset, steps, _) = steer(remote_offset);
        assert!(offset.abs() > 10.0, "offset was not established: {offset}");
        assert_eq!(steps.len(), 1, "no step for remote offset {remote_offset}, estimate {offset}");
        assert!((steps[0] - remote_offset as f64).abs() < 0.01, "wrong step: {}", steps[0]);
    }
}

#[test]
fn offsets_outside_synchronization_bound_are_not_synchronized() {
    for remote_offset in [-5, 5] {
        let (offset, steps, synchronized) = steer(remote_offset);
        assert!(offset.abs() > 1.0, "offset was not established: {offset}");
        assert!(steps.is_empty());
        assert_eq!(synchronized, [false], "wrong synchronization status for offset {offset}");
    }
}
