use mdevd::publish::{publish, Output, Sinks};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

#[test]
fn adversarial_full_output_pipe_closes_without_retry() {
    let mut fds = [-1; 2];
    // SAFETY: fds is valid output storage for two owned descriptors.
    assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) }, 0);
    // SAFETY: pipe2 returned distinct open descriptors.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    let mut capacity = 0;
    let chunk = [b'x'; 4096];
    loop {
        // SAFETY: write is open and chunk remains live during the call.
        let size = unsafe { libc::write(write.as_raw_fd(), chunk.as_ptr().cast(), chunk.len()) };
        if size == -1 {
            assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
            break;
        }
        assert!(size > 0);
        capacity += size as usize;
    }
    let mut sinks = Sinks { output: Some(Output::new(write)), rebroadcast: None };
    let mut warnings = Vec::new();
    publish(b"add@/x\0ACTION=add\0", &mut sinks, &mut warnings);
    assert_eq!(warnings.len(), 1);
    assert!(!sinks.output.as_ref().unwrap().live());
    let mut reader = std::fs::File::from(read);
    let mut drained = vec![0; capacity];
    reader.read_exact(&mut drained).unwrap();
    assert_eq!(drained, vec![b'x'; capacity]);
    match reader.read(&mut [0]) {
        Ok(size) => assert_eq!(size, 0),
        Err(error) => assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock),
    }
    warnings.clear();
    for _ in 0..100 { publish(b"change@/x\0ACTION=change\0", &mut sinks, &mut warnings); }
    assert!(warnings.is_empty());
}
