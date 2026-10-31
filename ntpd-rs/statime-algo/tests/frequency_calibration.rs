//! Exercises frequency calibration independently of phase slewing.
use std::{future::{Future, pending}, pin::pin, sync::{Arc, Mutex}, task::{Context, Poll, Wake, Waker}};
use statime_algo::{ClockConfig, ControllerConfig, KalmanController, LinkConfig, StdKalmanStorage, TrackedLinkConfig};
use statime_base::{Clock, ClockError, Controller, Direction, Duration, LeapStatus, Link, Measurement, TAI, Timestamp};

#[derive(Clone, Default)]
struct TestClock(Arc<Mutex<(f64, f64)>>);
fn timestamp(seconds: f64) -> Timestamp<TAI> { Timestamp::UNIX_EPOCH + Duration::from_f64_seconds(seconds) }
impl Clock<TAI> for TestClock {
    fn now(&self) -> Result<Timestamp<TAI>, ClockError> { Ok(timestamp(self.0.lock().unwrap().0)) }
    fn max_frequency(&self) -> Result<f64, ClockError> { Ok(0.0005) }
    fn get_frequency(&self) -> Result<f64, ClockError> { Ok(self.0.lock().unwrap().1) }
    fn set_frequency(&self, value: f64) -> Result<Timestamp<TAI>, ClockError> { let mut state = self.0.lock().unwrap(); state.1 = value; Ok(timestamp(state.0)) }
    fn step_clock(&self, _: Duration) -> Result<Timestamp<TAI>, ClockError> { panic!("unexpected clock step") }
    fn error_estimate_update(&self, _: Duration, _: Duration) -> Result<(), ClockError> { Ok(()) }
    fn leap_update(&self, _: LeapStatus) -> Result<(), ClockError> { Ok(()) }
    fn synchronization_update(&self, _: bool) -> Result<(), ClockError> { Ok(()) }
}
struct Noop;
impl Wake for Noop { fn wake(self: Arc<Self>) {} }

#[test]
fn calibration_excludes_phase_slew_and_requires_observations() {
    let clock = TestClock::default();
    let (controller, id) = KalmanController::<StdKalmanStorage<_>, _>::new(clock.clone(), ClockConfig::default(), ControllerConfig {
        select_offset_uncertainty_window: 1.0, select_link_uncertainty_window: 2.0,
        select_delay_uncertainty_window: 0.5, select_max_window_size: 0.5, minimum_agreeing_sources: 1,
    }).unwrap();
    let controller = Arc::new(controller);
    assert!(controller.frequency_calibration(id).unwrap().is_none());
    let link = KalmanController::create_tracked_link(controller.clone(), id, None, LinkConfig::default(), TrackedLinkConfig::default()).unwrap();
    link.external_data_update(Duration::ZERO, Some(LeapStatus::None), true).unwrap();
    let uncertainty = Duration::from_seconds_nanos(0, 1000);
    for second in 1..=300 {
        let local = { let mut state = clock.0.lock().unwrap(); state.0 += 1.0 + 0.000_02 + state.1; timestamp(state.0) };
        let remote = timestamp(second as f64 + 0.002);
        link.measurement(Measurement { send_timestamp: local, recv_timestamp: remote, uncertainty }, Direction::Forward).unwrap();
        link.measurement(Measurement { send_timestamp: remote, recv_timestamp: local, uncertainty }, Direction::Reverse).unwrap();
        let mut run = pin!(KalmanController::run(controller.clone(), |_| pending()));
        let waker = Waker::from(Arc::new(Noop));
        assert!(matches!(run.as_mut().poll(&mut Context::from_waker(&waker)), Poll::Pending));
    }
    let calibration = controller.frequency_calibration(id).unwrap().expect("learned frequency");
    assert!((calibration.correction() + 0.000_02).abs() < 0.000_005, "{:?}", calibration);
    clock.0.lock().unwrap().0 += 0.002;
    let local = clock.now().unwrap();
    let remote = timestamp(300.002);
    link.measurement(Measurement { send_timestamp: local, recv_timestamp: remote, uncertainty }, Direction::Forward).unwrap();
    link.measurement(Measurement { send_timestamp: remote, recv_timestamp: local, uncertainty }, Direction::Reverse).unwrap();
    let before = controller.frequency_calibration(id).unwrap().unwrap().correction();
    let mut run = pin!(KalmanController::run(controller.clone(), |_| pending()));
    let waker = Waker::from(Arc::new(Noop));
    assert!(matches!(run.as_mut().poll(&mut Context::from_waker(&waker)), Poll::Pending));
    let after = controller.frequency_calibration(id).unwrap().unwrap().correction();
    assert!((clock.get_frequency().unwrap() - after).abs() > 0.000_01, "phase slew must not be saved");
    assert!((after - before).abs() < 1e-10, "phase slew polluted calibration: {before} -> {after}");
}
