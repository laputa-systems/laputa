use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::{Command, ExitStatus, Output};

/// One step of an `&&` list that runs without a shell.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Step {
    Cd(String),
    Run(Vec<String>),
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Invocation {
    Direct(Vec<Step>),
    Shell,
}

pub(crate) fn invocation(command: &str) -> Invocation {
    let Some(segments) = plain_segments(command) else {
        return Invocation::Shell;
    };
    let mut steps = Vec::new();
    for words in segments {
        match words.first().map(String::as_str) {
            None => return Invocation::Shell,
            Some(":") if words.len() == 1 => {}
            Some("cd") if words.len() == 2 => steps.push(Step::Cd(words[1].clone())),
            Some(first) if needs_shell_as_first_word(first) => return Invocation::Shell,
            Some(_) => steps.push(Step::Run(words)),
        }
    }
    if steps.iter().any(|step| matches!(step, Step::Run(_))) {
        Invocation::Direct(steps)
    } else {
        Invocation::Shell
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ShellPolicy {
    Allow,
    Forbid,
}

impl ShellPolicy {
    pub(crate) fn from_env() -> Self {
        if std::env::var_os("GLUON_SHELL").is_some_and(|value| value == "forbid") {
            Self::Forbid
        } else {
            Self::Allow
        }
    }
}

fn shell_command(command: &str, shell: ShellPolicy) -> Result<Command, String> {
    if shell == ShellPolicy::Forbid {
        return Err(format!("command needs a shell, which GLUON_SHELL=forbid refuses: {command}"));
    }
    let mut process = Command::new("sh");
    process.arg("-c").arg(command);
    Ok(process)
}

fn step_command(words: &[String], cwd: &Option<PathBuf>) -> Command {
    let mut process = Command::new(&words[0]);
    process.args(&words[1..]);
    if let Some(dir) = cwd {
        process.current_dir(dir);
    }
    process
}

fn enter(cwd: &Option<PathBuf>, dir: &str) -> Result<PathBuf, String> {
    let next = match cwd {
        Some(current) => current.join(dir),
        None => PathBuf::from(dir),
    };
    if next.is_dir() {
        Ok(next)
    } else {
        Err(format!("cd: {dir}: no such directory"))
    }
}

fn failure(message: String) -> Output {
    Output { status: ExitStatus::from_raw(1 << 8), stdout: Vec::new(), stderr: format!("{message}\n").into_bytes() }
}

/// Runs `command` and collects its stdout and stderr, executing an `&&`
/// list of plain commands step by step without a shell.
pub(crate) fn output(command: &str, shell: ShellPolicy) -> Result<Output, String> {
    let steps = match invocation(command) {
        Invocation::Direct(steps) => steps,
        Invocation::Shell => return shell_command(command, shell)?.output().map_err(|e| e.to_string()),
    };
    let mut cwd: Option<PathBuf> = None;
    let mut collected = Output { status: ExitStatus::from_raw(0), stdout: Vec::new(), stderr: Vec::new() };
    for step in steps {
        match step {
            Step::Cd(dir) => match enter(&cwd, &dir) {
                Ok(next) => cwd = Some(next),
                Err(message) => return Ok(failure(message)),
            },
            Step::Run(words) => {
                let out = step_command(&words, &cwd).output().map_err(|e| format!("{}: {e}", words[0]))?;
                collected.stdout.extend_from_slice(&out.stdout);
                collected.stderr.extend_from_slice(&out.stderr);
                collected.status = out.status;
                if !out.status.success() {
                    return Ok(collected);
                }
            }
        }
    }
    Ok(collected)
}

/// Like [`output`] with the terminal inherited, for the console pool.
pub(crate) fn status(command: &str, shell: ShellPolicy) -> Result<ExitStatus, String> {
    let steps = match invocation(command) {
        Invocation::Direct(steps) => steps,
        Invocation::Shell => return shell_command(command, shell)?.status().map_err(|e| e.to_string()),
    };
    let mut cwd: Option<PathBuf> = None;
    let mut last = ExitStatus::from_raw(0);
    for step in steps {
        match step {
            Step::Cd(dir) => match enter(&cwd, &dir) {
                Ok(next) => cwd = Some(next),
                Err(message) => {
                    eprintln!("{message}");
                    return Ok(ExitStatus::from_raw(1 << 8));
                }
            },
            Step::Run(words) => {
                last = step_command(&words, &cwd).status().map_err(|e| format!("{}: {e}", words[0]))?;
                if !last.success() {
                    return Ok(last);
                }
            }
        }
    }
    Ok(last)
}

fn needs_shell_as_first_word(word: &str) -> bool {
    matches!(
        word,
        "!" | "{" | "}" | "if" | "then" | "else" | "elif" | "fi" | "for" | "while" | "until" | "do" | "done"
            | "case" | "esac" | "in" | "exec" | "cd" | "export" | "set" | "unset" | "eval" | "." | ":" | "exit"
            | "trap" | "umask" | "ulimit" | "wait" | "read" | "shift" | "return" | "break" | "continue"
            | "alias" | "unalias" | "readonly" | "local" | "times"
    ) || is_assignment(word)
}

fn is_assignment(word: &str) -> bool {
    match word.split_once('=') {
        Some((name, _)) => {
            let mut chars = name.chars();
            chars.next().is_some_and(|c| c == '_' || c.is_ascii_alphabetic())
                && chars.all(|c| c == '_' || c.is_ascii_alphanumeric())
        }
        None => false,
    }
}

fn plain_segments(command: &str) -> Option<Vec<Vec<String>>> {
    let mut segments: Vec<Vec<String>> = Vec::new();
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut quoted_first_word = false;
    let mut chars = command.chars();
    while let Some(c) = chars.next() {
        match c {
            ' ' | '\t' => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            '\'' => {
                in_word = true;
                quoted_first_word |= words.is_empty();
                loop {
                    match chars.next()? {
                        '\'' => break,
                        ch => word.push(ch),
                    }
                }
            }
            '"' => {
                in_word = true;
                quoted_first_word |= words.is_empty();
                loop {
                    match chars.next()? {
                        '"' => break,
                        '\\' => match chars.next()? {
                            ch @ ('$' | '`' | '"' | '\\') => word.push(ch),
                            '\n' => {}
                            ch => {
                                word.push('\\');
                                word.push(ch);
                            }
                        },
                        '$' | '`' => return None,
                        ch => word.push(ch),
                    }
                }
            }
            '\\' => {
                in_word = true;
                quoted_first_word |= words.is_empty();
                match chars.next()? {
                    '\n' => {}
                    ch => word.push(ch),
                }
            }
            '&' if !in_word && chars.clone().next() == Some('&') => {
                chars.next();
                if words.is_empty() {
                    return None;
                }
                segments.push(std::mem::take(&mut words));
                quoted_first_word = false;
            }
            '&' if in_word && chars.clone().next() == Some('&') => {
                chars.next();
                words.push(std::mem::take(&mut word));
                in_word = false;
                segments.push(std::mem::take(&mut words));
                quoted_first_word = false;
            }
            '|' | '&' | ';' | '<' | '>' | '(' | ')' | '$' | '`' | '*' | '?' | '[' | '\n' | '\r' => return None,
            '#' | '~' if !in_word => return None,
            ch => {
                in_word = true;
                word.push(ch);
            }
        }
    }
    if in_word {
        words.push(word);
    }
    if quoted_first_word && words.first().is_some_and(|first| is_assignment(first)) {
        return None;
    }
    if words.is_empty() && !segments.is_empty() {
        return None;
    }
    segments.push(words);
    Some(segments)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(words: &[&str]) -> Step {
        Step::Run(words.iter().map(|w| w.to_string()).collect())
    }

    fn direct(words: &[&str]) -> Invocation {
        Invocation::Direct(vec![run(words)])
    }

    #[test]
    fn plain_quoted_commands_run_without_a_shell() {
        assert_eq!(invocation("cc -c 'a b.c' -o out.o"), direct(&["cc", "-c", "a b.c", "-o", "out.o"]));
        assert_eq!(invocation(r#"cc "-DNAME=\"x y\"" -c in.c"#), direct(&["cc", "-DNAME=\"x y\"", "-c", "in.c"]));
        assert_eq!(invocation(r"cc -DA=1\ 2 x.c"), direct(&["cc", "-DA=1 2", "x.c"]));
        assert_eq!(invocation("tool ''"), direct(&["tool", ""]));
        assert_eq!(invocation("ar csrD lib.a a.o#b"), direct(&["ar", "csrD", "lib.a", "a.o#b"]));
        assert_eq!(invocation(r#"cc -Wl,-rpath,"\$ORIGIN/../lib" x.o"#), direct(&["cc", "-Wl,-rpath,$ORIGIN/../lib", "x.o"]));
    }

    #[test]
    fn cmake_and_lists_run_step_by_step() {
        assert_eq!(
            invocation("cd /b/loader && /b/loader/asm_offset GAS"),
            Invocation::Direct(vec![Step::Cd("/b/loader".into()), run(&["/b/loader/asm_offset", "GAS"])])
        );
        assert_eq!(invocation(": && cc -o app a.o && :"), direct(&["cc", "-o", "app", "a.o"]));
        assert_eq!(invocation("a&&b"), Invocation::Direct(vec![run(&["a"]), run(&["b"])]));
    }

    #[test]
    fn shell_syntax_falls_back_to_the_shell() {
        for command in [
            "rm -f out && ar rcs out in && echo $x",
            "cmd > out",
            "a | b",
            "a & b",
            "a || b",
            "cmd; other",
            "echo $HOME",
            "ls *.c",
            "cd dir",
            "cd",
            "VAR=1 cmd",
            "&& cmd",
            "cmd &&",
            ": && :",
            "'unterminated",
            "",
        ] {
            assert_eq!(invocation(command), Invocation::Shell, "{command}");
        }
    }

    #[test]
    fn steps_change_directory_and_stop_at_the_first_failure() {
        let dir = std::env::temp_dir().join(format!("gluon-steps-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        let command = format!("cd {} && cd sub && /bin/pwd", dir.display());
        let out = output(&command, ShellPolicy::Forbid).unwrap();
        assert!(out.status.success());
        assert_eq!(String::from_utf8(out.stdout).unwrap().trim(), dir.join("sub").canonicalize().unwrap().to_string_lossy());
        let out = output("false && /bin/echo unreached", ShellPolicy::Forbid).unwrap();
        assert!(!out.status.success());
        assert!(out.stdout.is_empty());
        let out = output(&format!("cd {}/missing && true", dir.display()), ShellPolicy::Forbid).unwrap();
        assert!(!out.status.success());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_forbidden_shell_refuses_shell_syntax() {
        assert!(output("true", ShellPolicy::Forbid).unwrap().status.success());
        assert!(output("true | true", ShellPolicy::Allow).unwrap().status.success());
        assert!(output("true | true", ShellPolicy::Forbid).unwrap_err().contains("GLUON_SHELL=forbid"));
    }
}
