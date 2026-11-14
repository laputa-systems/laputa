##! The oxish recipe consumes one pinned ssh-build release archive and installs its six executables.
use packages.oxish.PKGBUILD as oxish_recipe
use pm.recipe
use pm.types
use pm.util

const executables = ["oxish", "oxish-keygen", "oxish-scp", "oxish-server", "oxish-session", "oxish-sftp"]
const documents = ["LICENSE-APACHE", "LICENSE-MIT", "THIRD-PARTY.md", "provenance.json"]

proc stage_release(root: Path, omit: Str) [fs, error] -> Result[Path] {
  let release = fp"{root}/release"

  for tool in executables {
    if f"bin/{tool}" != omit {
      fp"{release}/bin/{tool}".parent.mkdir(parents: true)
      fp"{release}/bin/{tool}".write(bytes.from_text(f"#!{tool}\n"))
    }
  }

  for document in documents {
    if document != omit {
      fp"{release}/{document}".parent.mkdir(parents: true)
      fp"{release}/{document}".write(bytes.from_text(f"{document}\n"))
    }
  }

  release
}

test oxish_recipe_pins_one_release_archive_per_architecture [fs, env, error] {
  let root = path.absolute(p".")?

  for arch in ["x86_64", "aarch64"] {
    let target = if arch == "x86_64" { types.target_x86_64() } else { types.target_aarch64() }
    let pkg = recipe.load_package_for_target(fp"{root}/packages/oxish", target)?
    let release_source = pkg.upstream_sources[0]
    let url = util.expand_source(release_source.source.display(), pkg, arch, arch)
    assert url.starts_with("https://github.com/laputa-systems/ssh-build/releases/download/release-")
    assert url.ends_with(f"/oxish-{pkg.ver}-{arch}-unknown-linux-musl.tar.xz => oxish")
    assert "{" not in url and "VERSION" not in url and "ARCH" not in url
    let arches = release_source.checksums |> map .arch |> collect
    assert arches == ["aarch64", "x86_64"]

    for checksum in release_source.checksums {
      assert checksum.sha256.byte_len() == 64
    }

    for source in pkg.upstream_sources[1..] {
      assert source.checksums |> all { |checksum| checksum.sha256 == "SKIP" }
    }
  }
}

test oxish_recipe_installs_the_release_executables_and_service_modules [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "oxish install")?
  let release = stage_release(root, "")?
  let dest = fp"{root}/dest"
  oxish_recipe.install_release(release, p"packages/oxish", dest)?

  for tool in executables {
    let installed = fp"{dest}/usr/bin/{tool}"
    assert installed.read_text()? == f"#!{tool}\n"
    assert installed.metadata()?.mode.bit_and(0o777) == 0o755
  }

  for document in documents {
    assert fp"{dest}/usr/share/oxish/{document}".read_text()? == f"{document}\n"
  }

  assert fp"{dest}/usr/lib/xinit/services/oxish.xsh".read_bytes()? == p"packages/oxish/service.xsh".read_bytes()?
  assert fp"{dest}/usr/lib/xinit/services/oxish-hostkey.xsh".read_bytes()? == p"packages/oxish/hostkey.xsh".read_bytes()?

  let declared = oxish_recipe.filetree |> map .path |> map .display() |> collect

  for entry in declared {
    assert fp"{dest}/{entry}".exists()?, f"declared but not installed: {entry}"
  }
}

test oxish_recipe_refuses_a_release_missing_an_executable_or_document [fs, error] { |ctx|
  for omit in ["bin/oxish", "bin/oxish-session", "bin/oxish-scp", "bin/oxish-sftp", "provenance.json"] {
    let root = test.temp_dir(ctx, name: f"oxish missing {omit.replace("/", with: "-")}")?
    let release = stage_release(root, omit)?
    assert oxish_recipe.install_release(release, p"packages/oxish", fp"{root}/dest") is Err(_)
  }
}
