use std::process::Command;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Invocation {
    Direct(Vec<String>),
    Shell,
}

pub(crate) fn invocation(command: &str) -> Invocation {
    match plain_words(command) {
        Some(words) if !words.is_empty() && !needs_shell_as_first_word(&words[0]) => Invocation::Direct(words),
        _ => Invocation::Shell,
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

pub(crate) fn process(command: &str, shell: ShellPolicy) -> Result<Command, String> {
    match invocation(command) {
        Invocation::Direct(words) => {
            let mut process = Command::new(&words[0]);
            process.args(&words[1..]);
            Ok(process)
        }
        Invocation::Shell if shell == ShellPolicy::Forbid => {
            Err(format!("command needs a shell, which GLUON_SHELL=forbid refuses: {command}"))
        }
        Invocation::Shell => {
            let mut process = Command::new("sh");
            process.arg("-c").arg(command);
            Ok(process)
        }
    }
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

fn plain_words(command: &str) -> Option<Vec<String>> {
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
    Some(words)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn direct(words: &[&str]) -> Invocation {
        Invocation::Direct(words.iter().map(|w| w.to_string()).collect())
    }

    #[test]
    fn plain_quoted_commands_run_without_a_shell() {
        assert_eq!(invocation("cc -c 'a b.c' -o out.o"), direct(&["cc", "-c", "a b.c", "-o", "out.o"]));
        assert_eq!(invocation(r#"cc "-DNAME=\"x y\"" -c in.c"#), direct(&["cc", "-DNAME=\"x y\"", "-c", "in.c"]));
        assert_eq!(invocation(r"cc -DA=1\ 2 x.c"), direct(&["cc", "-DA=1 2", "x.c"]));
        assert_eq!(invocation("tool ''"), direct(&["tool", ""]));
        assert_eq!(invocation("ar csrD lib.a a.o#b"), direct(&["ar", "csrD", "lib.a", "a.o#b"]));
        assert_eq!(invocation("cc -Wl,--version-script=foo.map"), direct(&["cc", "-Wl,--version-script=foo.map"]));
    }

    #[test]
    fn shell_syntax_falls_back_to_the_shell() {
        for command in [
            "rm -f out && ar rcs out in",
            "cmd > out",
            "cmd < in",
            "a | b",
            "cmd; other",
            "echo $HOME",
            r#"echo "$HOME""#,
            "echo `date`",
            "ls *.c",
            "cd dir",
            "VAR=1 cmd",
            "cmd # comment",
            "ls ~/x",
            "'unterminated",
            "",
            "   ",
        ] {
            assert_eq!(invocation(command), Invocation::Shell, "{command}");
        }
    }

    #[test]
    fn a_forbidden_shell_refuses_shell_syntax() {
        assert!(process("cc -c a.c", ShellPolicy::Forbid).is_ok());
        assert!(process("rm -f out && ar rcs out in", ShellPolicy::Allow).is_ok());
        let refused = process("rm -f out && ar rcs out in", ShellPolicy::Forbid);
        assert!(refused.unwrap_err().contains("GLUON_SHELL=forbid"));
    }
}
