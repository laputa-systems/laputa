#[path = "adversarial/filesystem.rs"]
mod filesystem;
#[path = "adversarial/devices.rs"]
mod devices;

#[path = "adversarial/intake.rs"]
mod intake;
#[path = "adversarial/backpressure.rs"]
mod backpressure;

#[path = "adversarial/kernel.rs"]
mod kernel;

#[path = "adversarial/restart.rs"]
mod restart;

use std::path::PathBuf;

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(format!(".work/tmp/adversarial-{}-{name}", std::process::id()));
        for dir in ["dev", "sys", "outside"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        Self { root }
    }

    fn ops(&self) -> mdevd::engine::ops::RealOps {
        mdevd::engine::ops::RealOps::open(&self.root.join("dev"), &self.root.join("sys")).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.root).expect("remove adversarial fixture");
    }
}
