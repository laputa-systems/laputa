##! PM proof operations and shared package-manager policy.
use elfdeps
use local
use pm.util as pm_util
use types

type ArtifactProofDto = {
  format: Str,
  package_id: Str,
  artifact_key: Str,
  proof_key: Str,
  proof_sha256: Str,
  payload_sha256: Str,
}

## Exported PM declaration `ProofError`.
export error ProofError = Failed(kind: Str, message: Str)

## Exported PM declaration `ensure`.
export proc ensure(condition: Bool, kind: Str, message: Str) [error] {
  guard condition else {
    return Err(ProofError.Failed(kind:, message:))
  }
}

## Exported PM declaration `package_metadata`.
export proc package_metadata(root: Path, name: Str) [fs, error] {
  let db = fp"{root}/var/lib/xsh-pm/packages/{name}/metadata.json"
  ensure(fs.exists(db)?, f"proof-{name}", f"missing package metadata: {db}")?
}

## The installed package's recipe `ver`, so a proof can check that the
## binary it runs reports the version the recipe pins.
export proc package_version(root: Path, name: Str) [fs, error] -> Result[Str, Error] {
  let db = fp"{root}/var/lib/xsh-pm/packages/{name}/metadata.json"
  json.read(db)?.require(Record)?.get("ver")?.require(Str)
}

proc package_dependency_map(root: Path) [fs, error] -> Result[Map[List[Str]]] {
  var package_deps: Map[List[Str]] = {}
  let packages_db = fp"{root}/var/lib/xsh-pm/packages"

  return package_deps unless fs.exists(packages_db)?

  for entry in fs.children(packages_db) |> where .kind == "dir" {
    let metadata_path = fp"{entry.path}/metadata.json"

    if fs.exists(metadata_path)? {
      let metadata = json.read(metadata_path)?.require(Record)?
      var deps: List[Str] = []

      if "deps" in metadata {
        deps = metadata.get("deps")?.require(List[Str])?
      }

      package_deps[entry.name] = deps
    }
  }

  package_deps
}

## Exported PM declaration `verify_package_elf_dependencies`.
export proc verify_package_elf_dependencies(root: Path, name: Str) [fs, error] {
  let providers = elfdeps.collect_library_providers(root)?
  let package_deps = package_dependency_map(root)?
  let allowed = elfdeps.runtime_dependency_closure(package_deps.get(name) ?? [], package_deps)
  let manifest = local.load_manifest(fp"{root}/var/lib/xsh-pm/packages/{name}")?
  var failures = []

  for rel_path in manifest {
    let path_value = fp"{root}/{rel_path}"

    if path_value.exists()? {
      failures += elfdeps.installed_file_elf_dependency_failures(name, allowed, rel_path, path_value, providers)?
    }
  }

  if failures.len() > 0 {
    let first = failures[0]

    if first.provider == "" {
      return Err(ProofError.Failed(kind: f"proof-{name}", message: f"{first.file} needs {first.soname} by its build-time path"))
    }

    return Err(
      ProofError.Failed(
        kind: f"proof-{name}",
        message: f"{first.file} needs {first.soname} from {first.provider} without a runtime dependency",
      ),
    )
  }
}

## Exported PM declaration `elf_machine_name`.
export pure elf_machine_name(arch: Str) -> Str {
  return "AArch64" when arch == "aarch64"

  return "X86-64" when arch == "x86_64"

  arch
}

## Exported PM declaration `readelf_tool`.
export proc readelf_tool() [fs, process, env, error] -> Result[Path, Error] {
  let host_readelf = /usr/bin/readelf
  let host_llvm_readelf = /usr/bin/llvm-readelf

  return host_readelf when fs.exists(host_readelf)?

  return host_llvm_readelf when fs.exists(host_llvm_readelf)?

  if let Ok(tool) = process.which("readelf") {
    return tool
  }

  process.which("llvm-readelf")?
}

## Exported PM declaration `target_elf`.
export proc target_elf(root: Path, rel: Path, name: Str) [fs, process, env, error] {
  let path_value = fp"{root}/{rel}"
  ensure(fs.exists(path_value)?, f"proof-{name}", f"missing ELF: {path_value}")?
  let readelf = readelf_tool()?
  let header = run.text $readelf "-h" $path_value ?
  let arch = pm_util.target_arch()?
  ensure(elf_machine_name(arch) in header, f"proof-{name}", f"{rel} is not {arch}")?
}

proc proof_xsh_runner() [fs, process, env, error] -> Result[Path] {
  let configured = (e"XSH_HOST" ?? "").trim()

  if configured != "" {
    let selected = fp"{configured}"

    return selected when fs.exists(selected)?
  }

  return /bin/xsh when fs.exists(/bin/xsh)?

  process.which("xsh")?
}

## Runs one package proof against an already composed mutable proof work root.
## Callers must seed the explicit executor substrate before invoking this boundary.
export proc run_artifact_proof(root: Path, pkg: types.Package) [fs, process, env, error] -> Result[Unit, Error] {
  let script = fp"{pkg.dir}/proof.xsh"

  if ! fs.exists(script)? {
    return Err(types.PmError.PackageContract(f"{pkg.name} is missing proof.xsh"))
  }

  package_metadata(root, pkg.name)?
  verify_package_elf_dependencies(root, pkg.name)?
  let xsh = proof_xsh_runner()?

  # Preserve a nonzero proof Status as data at this boundary. Returning an Err
  # from inside the effect block and then applying `?` would bypass a parallel
  # executor worker's typed completion marker on the published runner.
  var proof_ok = false
  var proof_exited = false
  var proof_exit_code = 0

  env ({
    LAPUTA_ROOT: root.display(),
    PATH: f"{root}/bin:{root}/usr/bin:{e"PATH" ?? ""}",
    XSH_MODULE_PATH: e"XSH_MODULE_PATH" ?? "",
    XSH_PM_PROOF_ROOT: root.display(),
    XSH_PM_PROOF_HOST_PATH: e"PATH" ?? "",
    SHELL: fp"{root}/bin/xshi",
  }) {
    let status = process.run(process.command_argv(xsh, [xsh, script, "--", root]))?
    proof_ok = status.ok
    proof_exited = status.exited()

    if proof_exited {
      proof_exit_code = status.exit_code()?
    }
  }?

  if ! proof_ok {
    if proof_exited {
      return Err(types.PmError.ExtensionFailed(f"package proof for {pkg.name} exited with status {proof_exit_code}"))
    }

    return Err(types.PmError.ExtensionFailed(f"package proof for {pkg.name} was signaled"))
  }
}

## Writes the deterministic proof receipt that binds a proof input to one exact payload artifact.
## `payload_sha256` is the payload digest the caller already holds (staged or Store receipt).
export proc write_artifact_receipt(path_value: Path, node: types.PlanNode, payload_sha256: Str) [fs, error] {
  fs.mkdir(path_value.parent)?
  fs.write(
    path_value,
    json.encode({
      format: "laputa-package-proof-3",
      package_id: node.package_id,
      artifact_key: node.artifact_key,
      proof_key: node.proof_key,
      proof_sha256: node.proof_sha256,
      payload_sha256,
    })? + "\n",
  )?
}

## Verifies an immutable proof receipt against the exact node and payload digest it attests.
export proc verify_artifact_receipt(path_value: Path, node: types.PlanNode, payload_sha256: Str) [fs, error] {
  let value = json.read(path_value)?.require(ArtifactProofDto)?

  if value.format != "laputa-package-proof-3" {
    return Err(types.PmError.PackageContract(f"unsupported package proof format {value.format}"))
  }

  if value.package_id != node.package_id or value.artifact_key != node.artifact_key or value.proof_key != node.proof_key or value.proof_sha256 != node.proof_sha256 {
    return Err(types.PmError.PackageContract(f"proof receipt {path_value} does not match {node.package_id}"))
  }

  if value.payload_sha256 != payload_sha256 {
    return Err(
      types.PmError.PackageContract(f"proof receipt {path_value} payload hash does not match {node.package_id}"),
    )
  }
}

# A small C driver for interactive proofs: XSH has no pseudoterminal API, and
# terminal programs (less, tmux) behave differently without a tty.
# `ptydrive ROWS COLS TIMEOUT_MS [EXPECT SEND]... -- ARGV...` starts ARGV on a
# fresh pty of that size; each step waits until the output since the previous
# step contains EXPECT, then writes SEND. It copies all output to stdout and
# exits 0 only if every EXPECT arrived and the child exited 0 (2 on timeout).
const pty_driver_source = """/* ptydrive: see pm/proof.xsh. */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static char buf[1 << 20];
static size_t len, mark;

static int pump(int fd, int wait_ms) {
	struct pollfd p = {fd, POLLIN, 0};
	if (poll(&p, 1, wait_ms) <= 0) return 0;
	ssize_t n = read(fd, buf + len, sizeof(buf) - 1 - len);
	if (n <= 0) return -1;
	fwrite(buf + len, 1, (size_t)n, stdout);
	len += (size_t)n;
	buf[len] = 0;
	return 1;
}

int main(int argc, char **argv) {
	int sep = 0;
	for (int i = 4; i < argc; i++) if (strcmp(argv[i], "--") == 0) { sep = i; break; }
	if (argc < 6 || sep == 0 || (sep - 4) % 2 != 0) {
		fprintf(stderr, "usage: ptydrive ROWS COLS TIMEOUT_MS [EXPECT SEND]... -- ARGV...\\n");
		return 64;
	}
	struct winsize ws = {(unsigned short)atoi(argv[1]), (unsigned short)atoi(argv[2]), 0, 0};
	long deadline = now_ms() + atol(argv[3]);
	int fd;
	pid_t pid = forkpty(&fd, NULL, NULL, &ws);
	if (pid < 0) { perror("forkpty"); return 1; }
	if (pid == 0) {
		execv(argv[sep + 1], argv + sep + 1);
		perror("execv");
		_exit(127);
	}
	for (int i = 4; i < sep; i += 2) {
		while (memmem(buf + mark, len - mark, argv[i], strlen(argv[i])) == NULL) {
			if (now_ms() > deadline || pump(fd, 50) < 0) {
				fflush(stdout);
				fprintf(stderr, "ptydrive: did not see %s\\n", argv[i]);
				kill(pid, SIGKILL);
				return 2;
			}
		}
		mark = len;
		if (write(fd, argv[i + 1], strlen(argv[i + 1])) < 0) { perror("write"); return 1; }
	}
	int status;
	for (;;) {
		pid_t r = waitpid(pid, &status, WNOHANG);
		if (r == pid) break;
		if (now_ms() > deadline) {
			fflush(stdout);
			fprintf(stderr, "ptydrive: child did not exit\\n");
			kill(pid, SIGKILL);
			return 2;
		}
		if (pump(fd, 50) < 0) usleep(10000);
	}
	while (pump(fd, 0) > 0) {}
	fflush(stdout);
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 3;
}
"""

## Compiles the pseudoterminal driver into `dir` with the proof host's `cc`
## and returns its path. The driver runs on the build host, so only native
## proofs use it.
export proc pty_driver(dir: Path) [fs, process, env, error] -> Result[Path, Error] {
  let cc = process.which("cc")?
  let source = fp"{dir}/ptydrive.c"
  let binary = fp"{dir}/ptydrive"
  fs.write(source, pty_driver_source)?
  run $cc "-O2" $source "-o" $binary ?
  binary
}
