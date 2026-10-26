let arguments = [
  "/bin/xsh",
  "/inputs/laputa/guest/self-hosting-linker.xsh",
  "--",
  "-shared",
  "-fPIC",
  "-nodefaultlibs",
  "-L/seed/rust/lib/rustlib/x86_64-unknown-linux-musl/lib",
  "/cohort/packages/cohort-c/files/hello.c",
  "-lgcc_s",
  "-lc",
]
let positive = process.command_argv(/bin/xsh, arguments.extend(["-o", "/scratch/linker-probe.so"]), env: {TMPDIR: "/scratch"})
let success = linux.run_in_namespaces(positive, root: /declared, cwd: /declared, uid: 65534, gid: 65534, drop_groups: true)?
assert success.exited_with(0)
let comment = /declared/scratch/linker-comment
let inspect = process.command_argv(
  /usr/bin/readelf,
  ["readelf", "-p", ".comment", "/scratch/linker-probe.so"],
  stdout: comment,
)
let inspection = linux.run_in_namespaces(inspect, root: /declared, cwd: /declared, uid: 65534, gid: 65534, drop_groups: true)?
assert inspection.ok
assert "mold" in comment.read_text()?
let negative = process.command_argv(/bin/xsh, arguments.extend(["-lself_hosting_missing", "-o", "/scratch/linker-negative.so"]), env: {TMPDIR: "/scratch"}, stderr: /declared/scratch/linker-stderr)
let failure = linux.run_in_namespaces(negative, root: /declared, cwd: /declared, uid: 65534, gid: 65534, drop_groups: true)?
assert failure.exited_with(1)
assert "self_hosting_missing" in p"/declared/scratch/linker-stderr".read_text()?
print "declared shared-library linker contract passed"
