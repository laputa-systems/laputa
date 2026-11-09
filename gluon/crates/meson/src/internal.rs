use std::fs::File;
use std::path::Path;
use std::process::{Command, Stdio};

/// The `meson --internal` helpers generated build edges run, so that an
/// edge needing capture, feed, an environment, a copy or a fresh archive
/// stays a plain argument list instead of shell syntax.
pub fn run(args: &[String]) -> i32 {
    let result = match args.split_first() {
        Some((name, rest)) if name == "exe" => exe(rest),
        Some((name, rest)) if name == "copy" => copy(rest),
        Some((name, rest)) if name == "static-link" => static_link(rest),
        Some((name, _)) => Err(format!("unknown internal command '{name}'")),
        None => Err("meson --internal requires a command".to_string()),
    };
    match result {
        Ok(code) => code,
        Err(message) => {
            eprintln!("meson --internal: {message}");
            1
        }
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct ExeRequest {
    pub capture: Option<String>,
    pub feed: Option<String>,
    pub env: Vec<(String, String)>,
    pub argv: Vec<String>,
}

pub fn parse_exe(args: &[String]) -> Result<ExeRequest, String> {
    let mut request = ExeRequest::default();
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        let value = || args.get(index + 1).cloned().ok_or_else(|| format!("{flag} requires a value"));
        match flag {
            "--" => {
                request.argv = args[index + 1..].to_vec();
                break;
            }
            "--capture" => request.capture = Some(value()?),
            "--feed" => request.feed = Some(value()?),
            "--env" => {
                let pair = value()?;
                let (key, val) = pair.split_once('=').ok_or_else(|| format!("--env needs KEY=VALUE, got '{pair}'"))?;
                request.env.push((key.to_string(), val.to_string()));
            }
            other => return Err(format!("unexpected argument '{other}' before --")),
        }
        index += 2;
    }
    if request.argv.is_empty() {
        return Err("exe requires a command after --".to_string());
    }
    Ok(request)
}

fn exe(args: &[String]) -> Result<i32, String> {
    let request = parse_exe(args)?;
    let mut command = Command::new(&request.argv[0]);
    command.args(&request.argv[1..]).envs(request.env.iter().map(|(k, v)| (k, v)));
    if let Some(feed) = &request.feed {
        command.stdin(File::open(feed).map_err(|e| format!("cannot open {feed}: {e}"))?);
    }
    if request.capture.is_some() {
        command.stdout(Stdio::piped());
    }
    let output = command.spawn().and_then(|child| child.wait_with_output()).map_err(|e| format!("cannot run {}: {e}", request.argv[0]))?;
    if let Some(capture) = &request.capture {
        let unchanged = std::fs::read(capture).is_ok_and(|existing| existing == output.stdout);
        if !unchanged {
            std::fs::write(capture, &output.stdout).map_err(|e| format!("cannot write {capture}: {e}"))?;
        }
    }
    Ok(output.status.code().unwrap_or(1))
}

fn copy(args: &[String]) -> Result<i32, String> {
    let [source, dest] = args else {
        return Err("copy requires SOURCE and DEST".to_string());
    };
    if let Some(parent) = Path::new(dest).parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent).map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    }
    std::fs::copy(source, dest).map_err(|e| format!("cannot copy {source} to {dest}: {e}"))?;
    Ok(0)
}

fn static_link(args: &[String]) -> Result<i32, String> {
    let (archive, argv) = match args {
        [archive, separator, argv @ ..] if separator == "--" && !argv.is_empty() => (archive, argv),
        _ => return Err("static-link requires ARCHIVE -- ARCHIVER ARGS...".to_string()),
    };
    match std::fs::remove_file(archive) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(format!("cannot remove {archive}: {e}")),
    }
    let status = Command::new(&argv[0]).args(&argv[1..]).status().map_err(|e| format!("cannot run {}: {e}", argv[0]))?;
    Ok(status.code().unwrap_or(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn exe_reads_capture_feed_and_environment_before_the_command() {
        let request = parse_exe(&words(&["--capture", "out.h", "--feed", "in.txt", "--env", "A=1=2", "--", "gen", "-x"])).unwrap();
        assert_eq!(
            request,
            ExeRequest {
                capture: Some("out.h".into()),
                feed: Some("in.txt".into()),
                env: vec![("A".into(), "1=2".into())],
                argv: words(&["gen", "-x"]),
            }
        );
        assert!(parse_exe(&words(&["--capture", "out.h"])).is_err());
        assert!(parse_exe(&words(&["--env", "NOEQUALS", "--", "gen"])).is_err());
    }

    #[test]
    fn helpers_copy_capture_and_replace_an_archive() {
        let dir = std::env::temp_dir().join(format!("gluon-internal-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = |name: &str| dir.join(name).to_string_lossy().into_owned();
        std::fs::write(path("in.txt"), "fed\n").unwrap();

        assert_eq!(run(&words(&["copy", &path("in.txt"), &path("sub/copied.txt")])), 0);
        assert_eq!(std::fs::read_to_string(path("sub/copied.txt")).unwrap(), "fed\n");

        assert_eq!(run(&words(&["exe", "--feed", &path("in.txt"), "--capture", &path("captured.txt"), "--", "/bin/cat"])), 0);
        assert_eq!(std::fs::read_to_string(path("captured.txt")).unwrap(), "fed\n");

        std::fs::write(path("lib.a"), "stale").unwrap();
        assert_eq!(run(&words(&["static-link", &path("lib.a"), "--", "/bin/true"])), 0);
        assert!(!Path::new(&path("lib.a")).exists());

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
