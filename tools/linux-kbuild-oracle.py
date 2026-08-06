#!/usr/bin/env python3
"""Compare the semantic object/archive graph emitted by upstream Kbuild and XSH."""

import argparse
from collections import Counter
import hashlib
import json
import re
import shlex
import sys
import posixpath
from pathlib import Path


ORACLE_FORMAT = "linux-kbuild-oracle-v11"


def normalize_path(value: str) -> str:
    value = value.strip().strip("'\"").rstrip(";,)")
    for prefix in ("/src/", "/out/", "./"):
        if value.startswith(prefix):
            value = value[len(prefix):]
    if value.startswith(".xsh-kbuild/obj/"):
        value = value[len(".xsh-kbuild/obj/"):]
    elif value.startswith(".xsh-kbuild/"):
        value = value[len(".xsh-kbuild/"):]
    return posixpath.normpath(value)


def add_compile(compiles, output, source):
    output = normalize_path(output)
    source = normalize_path(source)
    if output.endswith((".o", ".a")) and source.endswith((".c", ".S", ".s")):
        compiles[output] = source


def parse_command_tokens(line):
    try:
        return shlex.split(line, posix=True)
    except ValueError:
        return []


def input_key(source_root, config):
    digest = hashlib.sha256()
    digest.update(ORACLE_FORMAT.encode())
    files = []
    for path in source_root.rglob("*"):
        if path.is_file() and path.name in ("Makefile", "Kbuild"):
            files.append(path)
    files.append(config)
    for path in sorted(files):
        relative = path.relative_to(source_root) if path.is_relative_to(source_root) else path
        digest.update(str(relative).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def extract_upstream(path):
    compiles = {}
    artifacts = set()
    relocatables = {}
    archives = {}
    archive_re = re.compile(
        r'printf\s+"([^"]*%s[^"]*)"\s+([^|]+)\|\s+xargs\s+\S*ar\s+\S+\s+([^;\s]+)'
    )

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if "printf '%s\\n' 'savedcmd_" in line:
            line = line.split("printf '%s\\n' 'savedcmd_", 1)[0]
        tokens = parse_command_tokens(line)
        if "-c" in tokens and "-o" in tokens:
            output_index = tokens.index("-o") + 1
            if output_index < len(tokens):
                output = tokens[output_index]
                candidates = tokens[tokens.index("-c") + 1 :]
                source = next(
                    (item for item in candidates if item.endswith((".c", ".S", ".s"))),
                    "",
                )
                add_compile(compiles, output, source)

        if "-r" in tokens and "-o" in tokens:
            output_index = tokens.index("-o") + 1
            if output_index < len(tokens):
                inputs = [normalize_path(item) for item in tokens[output_index + 1 :]]
                inputs = [item for item in inputs if item.endswith(".o")]
                if inputs:
                    relocatables[normalize_path(tokens[output_index])] = inputs

        objcopy_index = next(
            (index for index, item in enumerate(tokens) if item.endswith("objcopy")),
            None,
        )
        if objcopy_index is not None:
            command = tokens[objcopy_index + 1 :]
            for marker in ("&&", ";", "||"):
                if marker in command:
                    command = command[: command.index(marker)]
            outputs = [item for item in command if normalize_path(item).endswith(".o")]
            if outputs:
                artifacts.add(normalize_path(outputs[-1]))

        match = archive_re.search(line)
        if match:
            format_string, members_text, archive = match.groups()
            members = []
            for member in parse_command_tokens(members_text):
                members.append(normalize_path(format_string.replace("%s", member)))
            archives[normalize_path(archive)] = members

        for index, token in enumerate(tokens):
            if (
                not (token == "ar" or token.endswith("-ar"))
                or index + 2 >= len(tokens)
                or (index > 0 and tokens[index - 1] == "xargs")
            ):
                continue
            archive = tokens[index + 2]
            members = [normalize_path(item) for item in tokens[index + 3 :] if item.endswith(".o")]
            archives[normalize_path(archive)] = members

    return {
        "compiles": compiles,
        "artifacts": sorted(artifacts),
        "relocatables": relocatables,
        "archives": archives,
    }


def extract_xsh(plan_path, archive_path):
    objects = set()
    lib_objects = set()
    composites = {}
    for raw_line in plan_path.read_text().splitlines():
        parts = raw_line.split("\t")
        if not parts:
            continue
        if parts[0] in ("obj", "lib") and len(parts) >= 2:
            objects.add(normalize_path(parts[1]))
            if parts[0] == "lib":
                lib_objects.add(normalize_path(parts[1]))
        elif parts[0] == "composite" and len(parts) >= 3:
            composites[normalize_path(parts[1])] = [
                normalize_path(item) for item in parts[2:]
            ]

    archive_report = json.loads(archive_path.read_text())
    compiles = {}
    artifacts = set()
    relocatables = {}
    archives = {}
    for task in archive_report.get("tasks", []):
        argv = [str(item) for item in task.get("argv", [])]
        if "-c" in argv and "-o" in argv:
            output_index = argv.index("-o") + 1
            if output_index < len(argv):
                source = next(
                    (item for item in argv[argv.index("-c") + 1 :] if item.endswith((".c", ".S", ".s"))),
                    "",
                )
                add_compile(compiles, argv[output_index], source)
        if "-r" in argv and "-o" in argv:
            output_index = argv.index("-o") + 1
            if output_index < len(argv):
                relocatables[normalize_path(argv[output_index])] = [
                    normalize_path(item)
                    for item in argv[output_index + 1 :]
                    if str(item).endswith(".o")
                ]
        if argv and argv[0].endswith("objcopy"):
            outputs = [item for item in argv[1:] if item.endswith(".o")]
            if outputs:
                artifacts.add(normalize_path(outputs[-1]))
        if "cDPrST" in argv:
            archive_index = argv.index("cDPrST") + 1
            if archive_index < len(argv):
                archives[normalize_path(argv[archive_index])] = [
                    normalize_path(item) for item in argv[archive_index + 1 :]
                ]

    generated_objects = {
        normalize_path(str(item))
        for item in archive_report.get("generated_objects", [])
    }
    return {
        "objects": sorted(objects),
        "lib_objects": sorted(lib_objects),
        "composites": composites,
        "compiles": compiles,
        "relocatables": relocatables,
        "artifacts": sorted(artifacts),
        "archives": archives,
        "generated_objects": generated_objects,
        "missing_sources": archive_report.get("missing_sources", []),
    }


def load_upstream(dry_run, cache, source_root, config):
    key = None
    if source_root is not None and config is not None:
        key = input_key(source_root, config)
    if cache is not None and cache.exists():
        if key is None:
            raise SystemExit("oracle cache requires --source-root and --config for validation")
        stored = json.loads(cache.read_text())
        if stored.get("format") == ORACLE_FORMAT and stored.get("key") == key:
            print(f"linux-kbuild-oracle: upstream cache hit {cache}")
            return stored["manifest"]
    if dry_run is None:
        raise SystemExit("upstream cache miss; provide --upstream-dry-run to populate it")
    manifest = extract_upstream(dry_run)
    if cache is not None:
        if key is None:
            raise SystemExit("writing an oracle cache requires --source-root and --config")
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps({"format": ORACLE_FORMAT, "key": key, "manifest": manifest}, sort_keys=True))
        print(f"linux-kbuild-oracle: upstream cache populated {cache}")
    return manifest


def flatten_archive(archives, name, seen=None):
    seen = set() if seen is None else seen
    if name in seen:
        return []
    seen.add(name)
    members = archives.get(name)
    if members is None and name.endswith("/lib.a"):
        members = archives.get(f"{name[:-len('lib.a')]}built-in.a")
    if members is None:
        return []
    flattened = []
    for member in members:
        if member.endswith(".a") and member in archives:
            flattened.extend(flatten_archive(archives, member, seen))
        else:
            flattened.append(member)
    return flattened


def read_materialized_outputs(manifest, root):
    lines = manifest.read_text().splitlines()
    if not lines or lines[0] != "format linux-materialized-outputs-v1":
        raise SystemExit(f"invalid materialized-output manifest: {manifest}")

    outputs = set()
    for raw in lines[1:]:
        item = normalize_path(raw)
        if not item:
            continue
        candidates = (root / item, root / ".xsh-kbuild" / "obj" / item)
        if not any(path.is_file() for path in candidates):
            raise SystemExit(f"materialized output missing: {item}")
        outputs.add(item)
    return outputs


def compare(xsh, upstream, prebuilt_objects, materialized):
    failures = []
    expected_objects = (set(xsh["objects"]) | set(xsh["lib_objects"])) - set(xsh["composites"])
    expected_objects -= xsh["generated_objects"]
    expected_objects -= prebuilt_objects
    for members in xsh["composites"].values():
        expected_objects.update(set(members) - xsh["generated_objects"])
    for item in xsh["missing_sources"]:
        failures.append(f"XSH plan has unresolved source: {item}")
    actual_objects = (
        set(upstream["compiles"])
        | set(upstream["artifacts"])
        | set(upstream["relocatables"])
    )
    actual_objects = {
        item
        for item in actual_objects
        if not item.startswith(("scripts/", "tools/"))
    }
    actual_objects -= materialized
    for prebuilt in prebuilt_objects:
        prefix = prebuilt.removesuffix(".o")
        actual_objects = {
            item
            for item in actual_objects
            if not (
                item == prebuilt
                or item.startswith(f"{prefix}.")
                or item in {
                    f"{posixpath.dirname(prebuilt)}/hyp-reloc.o",
                    f"{posixpath.dirname(prebuilt)}/{posixpath.basename(prefix)}.rel.o",
                    f"{posixpath.dirname(prebuilt)}/{posixpath.basename(prefix)}.tmp.o",
                }
            )
        }
    pi_outputs = {item for item in expected_objects if item.endswith(".pi.o")}
    actual_objects = {
        item
        for item in actual_objects
        if not (
            (
                item.startswith("arch/arm64/kernel/pi/")
                or item.startswith("arch/x86/boot/startup/")
            )
            and f"{item[:-2]}.pi.o" in pi_outputs
        )
    }
    efi_stub_outputs = {
        item
        for item in (
            set(upstream["artifacts"]) | set(upstream["relocatables"])
        )
        if item.startswith("drivers/firmware/efi/libstub/") and item.endswith(".stub.o")
    }
    for stub in efi_stub_outputs:
        base = stub.removesuffix(".stub.o") + ".o"
        if base in upstream["compiles"]:
            expected_objects.add(stub)
    for base in upstream["compiles"]:
        if not base.startswith("drivers/firmware/efi/libstub/lib-"):
            continue
        alias = f"lib/{posixpath.basename(base)[4:]}"
        alias = alias.removesuffix(".o") + ".o"
        if alias in expected_objects:
            expected_objects.discard(base)
            actual_objects.discard(base)
    missing = sorted(expected_objects - actual_objects)
    unexpected = sorted(actual_objects - expected_objects)
    for item in missing:
        failures.append(f"missing upstream object: {item}")
    for item in unexpected:
        failures.append(f"unexpected upstream object: {item}")

    for output, source in sorted(xsh["compiles"].items()):
        actual_source = upstream["compiles"].get(output)
        if actual_source is None:
            failures.append(f"missing upstream compile: {output} <- {source}")
        elif actual_source != source:
            failures.append(
                f"source mismatch: {output}: XSH={source} upstream={actual_source}"
            )

    for output, members in sorted(xsh["composites"].items()):
        actual_members = upstream["relocatables"].get(output)
        if actual_members is not None and actual_members != members:
            failures.append(f"composite membership mismatch: {output}")

    xsh_root = [
        item
        for item in flatten_archive(xsh["archives"], "built-in.a")
        if item not in materialized
    ]
    upstream_root = [
        item
        for item in flatten_archive(upstream["archives"], "built-in.a")
        if item not in materialized
    ]
    if Counter(xsh_root) != Counter(upstream_root):
        failures.append("flattened built-in archive membership mismatch")
    elif xsh_root != upstream_root:
        print("linux-kbuild-oracle: archive member order differs; membership matches")

    if failures:
        print("linux-kbuild-oracle: FAIL")
        for failure in failures[:100]:
            print(failure)
        if len(failures) > 100:
            print(f"... {len(failures) - 100} more differences")
        return 1

    print(
        "linux-kbuild-oracle: PASS "
        f"{len(expected_objects)} objects, {len(xsh['archives'])} archives"
    )
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--xsh-plan", type=Path, required=True)
    parser.add_argument("--xsh-archive-plan", type=Path, required=True)
    parser.add_argument("--upstream-dry-run", type=Path)
    parser.add_argument("--upstream-cache", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--prebuilt-object", action="append", default=[])
    parser.add_argument("--materialized-manifest", type=Path)
    args = parser.parse_args()
    upstream = load_upstream(args.upstream_dry_run, args.upstream_cache, args.source_root, args.config)
    materialized = (
        read_materialized_outputs(args.materialized_manifest, args.source_root)
        if args.materialized_manifest
        else set()
    )
    return compare(
        extract_xsh(args.xsh_plan, args.xsh_archive_plan),
        upstream,
        {normalize_path(item) for item in args.prebuilt_object},
        materialized,
    )


if __name__ == "__main__":
    sys.exit(main())
