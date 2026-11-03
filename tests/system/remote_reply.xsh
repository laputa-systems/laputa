##! The client side of the remote administration protocol: how a reply from a machine we do
##! not trust is turned into data and errors.
use system.remote

const HOSTILE = "\u{1b}[2J\u{1b}]0;owned\u{7}line\nbreak\u{d}return\u{0}end"

proc run_result(exit_code: Int, stdout: Str, stderr: Str) -> remote.ExecResult {
  {
    exit_code: exit_code,
    signal: "",
    missing: false,
    stdout: bytes.from_text(stdout),
    stderr: bytes.from_text(stderr),
    certainty: "submitted",
  }
}

proc has_control(text: Str) -> Bool {
  text.delete("\u{1b}\u{7}\u{d}\u{0}") != text
}

test test_guest_stderr_is_stripped_of_control_characters_in_a_failure {
  match remote.remote_decode_reply(run_result(3, "", HOSTILE)) {
    Err(remote.RemoteError.Failed {message, ..}) => {
      assert ! has_control(message)
      assert "line" in message
    }
    other => assert false, "expected a failure"
  }
}

test test_a_refusal_message_and_kind_are_stripped_of_control_characters {
  let line = json.encode({protocol: remote.REMOTE_PROTOCOL, ok: false, error: {kind: HOSTILE, message: HOSTILE}})?
  match remote.remote_decode_reply(run_result(0, line + "\n", "")) {
    Err(remote.RemoteError.Refused {kind, message, ..}) => {
      assert ! has_control(kind)
      assert ! has_control(message)
    }
    other => assert false, "expected a refusal"
  }
}
