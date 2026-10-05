##! XSH module `PKGBUILD` package and build operations.
use pm.env as pm_env
use pm.util as pm_util

## Exported declaration `name`.
export const name = "dwl-minimal"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "0.9"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl", "wlroots0.20", "wayland-libs-server", "libxkbcommon", "libinput"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = [
  "llvm-toolchain",
  "pkgconf",
  "wayland-dev",
  "wayland-protocols",
  "linux-headers",
  "wlroots0.20",
  "pixman-dev",
  "libdrm",
  "mesa",
  "libxkbcommon",
  "libinput",
]

## Exported declaration `mkdeps_target`.
export const mkdeps_target = ["wayland-dev", "wayland-protocols", "pixman-dev"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://codeberg.org/dwl/dwl/archive/vVERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "635c1c352c32f2e69d7acf95053ed6178e8614b51485f221bae78255b0bf3e3d",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [{path: p"usr/bin/dwl", kind: "binary"}]

proc sysroot_path(root: Str, raw: Str) -> Result[Path] {
  let path_value = fp"{raw.trim()}"

  return path_value when fs.exists(path_value)?

  return fp"{root}{raw.trim()}" when root != "" and root != "/" and raw.starts_with("/")

  path_value
}

proc pkg_config_flags(pkg_config: Path, mode: Str, packages: List[Str]) -> Result[List[Str]] {
  let out = run.text $pkg_config $mode @packages ?
  out.words()
}

proc pkg_config_variable(pkg_config: Path, package: Str, variable: Str) -> Result[Str] {
  let out = run.text $pkg_config f"--variable={variable}" $package ?
  out.trim()
}

proc generate_protocol_headers(pkg_config: Path, root: Str, scanner: Path) {
  let protocols = sysroot_path(root, pkg_config_variable(pkg_config, "wayland-protocols", "pkgdatadir")?)?
  run $scanner "enum-header" fp"{protocols}/staging/cursor-shape/cursor-shape-v1.xml" "cursor-shape-v1-protocol.h" ?
  run $scanner "enum-header" fp"{protocols}/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml" "ext-image-copy-capture-v1-protocol.h" ?
  run $scanner "enum-header" fp"{protocols}/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml" "pointer-constraints-unstable-v1-protocol.h" ?
  run $scanner "enum-header" "protocols/wlr-layer-shell-unstable-v1.xml" "wlr-layer-shell-unstable-v1-protocol.h" ?
  run $scanner "server-header" "protocols/wlr-output-power-management-unstable-v1.xml" "wlr-output-power-management-unstable-v1-protocol.h" ?
  run $scanner "server-header" fp"{protocols}/stable/xdg-shell/xdg-shell.xml" "xdg-shell-protocol.h" ?
}

proc patch_startup() {
  let source = p"dwl.c"
  var text = source.read_text()?

  text = replace_required(
    text,
    """static void run(char *startup_cmd);
""",
    """static void run(char *startup_cmd);
static char **startup_argv(char *startup_cmd);
""",
    "the run() prototype",
  )?

  text = replace_required(
    text,
    """void
run(char *startup_cmd)
""",
    """char **
startup_argv(char *startup_cmd)
{
	size_t argc = 0;
	char *p = startup_cmd;
	while (*p) {
		while (*p == ' ' || *p == '	')
			p++;
		if (*p) {
			argc++;
			while (*p && *p != ' ' && *p != '	')
				p++;
		}
	}
	if (!argc)
		die("startup: empty command");

	char **argv = ecalloc(argc + 1, sizeof(*argv));
	p = startup_cmd;
	for (size_t i = 0; i < argc; i++) {
		while (*p == ' ' || *p == '	')
			p++;
		argv[i] = p;
		while (*p && *p != ' ' && *p != '	')
			p++;
		if (*p)
			*p++ = 0;
	}
	return argv;
}

void
run(char *startup_cmd)
""",
    "run()",
  )?

  text = replace_required(
    text,
    """	/* Now that the socket exists and the backend is started, run the startup command */
	if (startup_cmd) {
		int piperw[2];
		if (pipe(piperw) < 0)
			die("startup: pipe:");
		if ((child_pid = fork()) < 0)
			die("startup: fork:");
		if (child_pid == 0) {
			setsid();
			dup2(piperw[0], STDIN_FILENO);
			close(piperw[0]);
			close(piperw[1]);
			execl("/bin/sh", "/bin/sh", "-c", startup_cmd, NULL);
			die("startup: execl:");
		}
		dup2(piperw[1], STDOUT_FILENO);
		close(piperw[1]);
		close(piperw[0]);
	}
""",
    """	/* Now that the socket exists and the backend is started, run the startup command. */
	if (startup_cmd) {
		char **argv = startup_argv(startup_cmd);
		if ((child_pid = fork()) < 0)
			die("startup: fork:");
		if (child_pid == 0) {
			setsid();
			close(STDIN_FILENO);
			execvp(argv[0], argv);
			die("startup: execvp %s failed:", argv[0]);
		}
	}
""",
    "the startup command block",
  )?

  text = replace_required(
    text,
    """else if (c == 'v')
			die("dwl " VERSION);
""",
    """else if (c == 'v') {
			puts("dwl " VERSION);
			return EXIT_SUCCESS;
		}
""",
    "the -v option",
  )?

  fs.write(source, text)
}

## Remove bindings whose launcher is intentionally absent from the minimal
## runtime profile. Keep the keyboard array nonempty and retain foot's direct
## terminal binding.
export pure config_without_unavailable_menu(config: Str) -> Str {
  var lines = [line for line in config.split("\n") if "menucmd" not in line]
  lines.join("\n")
}

pure replace_required(text: Str, old: Str, new: Str, what: Str) -> Result[Str] {
  if old not in text {
    fail f"dwl's sources no longer hold {what}"
  }

  text.replace(old, new)
}

# The runtime has no /bin/sh, so the configuration drops SHCMD and the
# example scroll bindings that use it. dwl skips axis bindings without a
# function, so one empty entry keeps the array nonempty without binding a
# scroll direction.
proc write_config() {
  var config = p"config.def.h".read_text()?

  config = replace_required(
    config,
    """/* helper for spawning shell commands in the pre dwm-5.0 fashion */
#define SHCMD(cmd) { .v = (const char*[]){ "/bin/sh", "-c", cmd, NULL } }

/* commands */
static const char *termcmd[] = { "foot", NULL };
static const char *menucmd[] = { "wmenu-run", NULL };
""",
    """/* commands */
static const char *termcmd[] = { "/usr/bin/foot", NULL };
""",
    "the shell helper and default commands",
  )?

  config = replace_required(
    config,
    """static const Axis axes[] = {
	{ MODKEY, AxisUp,   spawn, SHCMD("volume-up_EXAMPLE") },
	{ MODKEY, AxisDown, spawn, SHCMD("volume-down_EXAMPLE") },
};""",
    """static const Axis axes[] = {
	{ 0 },
};""",
    "the example scroll bindings",
  )?

  config = config_without_unavailable_menu(config)

  fs.write(p"config.h", config)
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let pc = pm_env.pkg_config_context()?
  let pkg_config = pc.pkg_config
  let root = e"LAPUTA_ROOT" ?? "/"
  let build_root = e"XSH_PM_BUILD_ROOT" ?? ""
  let cross_build = pm_util.build_arch()? != pm_util.target_arch()? and build_root != ""

  let native_tools_ld = if cross_build {
    f"{build_root}/usr/lib:{build_root}/usr/lib/llvm23/lib"
  } else {
    pc.ld_library_path
  }

  let scanner = if cross_build { fp"{build_root}/usr/bin/wayland-scanner" } else { process.which("wayland-scanner")? }
  let packages = ["wayland-server", "xkbcommon", "libinput", "wlroots-0.20"]
  patch_startup()
  write_config()

  env ({
    LD_LIBRARY_PATH: native_tools_ld,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    generate_protocol_headers(pkg_config, root, scanner)
    let pkg_cflags = pkg_config_flags(pkg_config, "--cflags", packages)?
    let pkg_libs = pkg_config_flags(pkg_config, "--libs", packages)?

    let cflags = [
      "-I.",
      "-DWLR_USE_UNSTABLE",
      "-D_POSIX_C_SOURCE=200809L",
      f"-DVERSION=\"{ver}\"",
      "-Wall",
      "-Wextra",
      "-Wno-unused-parameter",
      "-Wno-unused-macros",
      "-Wno-missing-braces",
      "-O2",
    ].extend(pkg_cflags)

    run $cc "dwl.c" "-o" "dwl" @cflags @pkg_libs "-lm" ?
  }

  fs.install(p"dwl", fp"{dest}/usr/bin/dwl", 0o755, parents: true, overwrite: true)
}
