#!/bin/xsh
##! Foot reader for the qemu-tinyland-foot proof: visual marker, then the
##! injected line, then a parked read. Runs as laputa inside foot.
p"/run/user/1000/laputa-foot-read-ready".write("ready\n")?
print "\x1b[48;2;255;0;255m     LAPUTA_TINYLAND_FOOT_VISUAL     \x1b[0m"
io.flush_stdout()?
let input = io.stdin_text()?
p"/run/user/1000/laputa-foot-input.txt".write(input)?
let _ = io.stdin_text()?
