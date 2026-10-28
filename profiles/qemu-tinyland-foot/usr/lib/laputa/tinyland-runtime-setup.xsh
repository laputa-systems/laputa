#!/bin/xsh
##! Unprivileged runtime directory for the qemu-tinyland-foot proof.
##! There is no working chown in the image, so laputa creates its own
##! directory inside the world-writable /run/user prepared by the proof.
p"/run/user/1000".mkdir()
p"/run/user/1000".chmod(0o700)
