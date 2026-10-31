#!/bin/xsh
##! Ghostty reader for the qemu-tinyland-ghostty proof: visual marker, then
##! the injected line, then a parked read. Runs as laputa inside Ghostty.
let account = user.lookup("laputa")?
let runtime = fp"/run/user/{account.uid}"
fp"{runtime}/laputa-ghostty-read-ready".write(env.get("LAPUTA_SESSION_ID")?)?
print "\x1b[48;2;255;0;255m     LAPUTA_TINYLAND_GHOSTTY_VISUAL     \x1b[0m"
io.flush_stdout()?
let input = io.stdin_text()?
fp"{runtime}/laputa-ghostty-input.txt".write(input)?
let _ = io.stdin_text()?
