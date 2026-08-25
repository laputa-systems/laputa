#!/bin/xsh
type Hashes = {
  aarch64_xsh: Str,
  aarch64_xshi: Str,
  aarch64_xsht: Str,
  x86_64_xsh: Str,
  x86_64_xshi: Str,
  x86_64_xsht: Str,
  core: Str,
}

error FindError = NotFound(message: Str)

error UpdateXshError = ReleaseAsset(message: Str)

proc parse_sha256_response(label: Str, status: Int, body: Str) [error] -> Result[Str] {
  if status != 200 {
    return Err(UpdateXshError.ReleaseAsset(message: f"${label} checksum request returned HTTP ${status}"))
  }

  let words = body.trim().words()

  if words.len() == 0 {
    return Err(UpdateXshError.ReleaseAsset(message: f"${label} checksum response was empty"))
  }

  let sha = words[0]
  let sha_re = regex.compile("^[0-9a-f]{64}$")?

  if sha_re.captures(sha).len() == 0 {
    return Err(UpdateXshError.ReleaseAsset(message: f"${label} checksum response did not start with a sha256 digest"))
  }

  return sha
}

proc fetch_release_sha256(label: Str, url: Str) [net, error] -> Result[Str] {
  let resp = net.request({method: "GET", url: url})?
  return parse_sha256_response(label, resp.status, resp.body.utf8()?)
}

proc fetch_new_hashes(tag: Str) [fs, net, error] -> Result[Hashes] {
  let aarch64_xsh = fetch_release_sha256(
    "aarch64 xsh",
    f"https://github.com/laputa-systems/xsh/releases/download/${tag}/xsh-${tag}-aarch64-linux-musl.sha256",
  )?
  let aarch64_xshi = fetch_release_sha256(
    "aarch64 xshi",
    f"https://github.com/laputa-systems/xsh/releases/download/${tag}/xshi-${tag}-aarch64-linux-musl.sha256",
  )?
  let aarch64_xsht = fetch_release_sha256(
    "aarch64 xsht",
    f"https://github.com/laputa-systems/xsh/releases/download/${tag}/xsht-${tag}-aarch64-linux-musl.sha256",
  )?
  let x86_64_xsh = fetch_release_sha256(
    "x86_64 xsh",
    f"https://github.com/laputa-systems/xsh/releases/download/${tag}/xsh-${tag}-x86_64-linux-musl.sha256",
  )?
  let x86_64_xshi = fetch_release_sha256(
    "x86_64 xshi",
    f"https://github.com/laputa-systems/xsh/releases/download/${tag}/xshi-${tag}-x86_64-linux-musl.sha256",
  )?
  let x86_64_xsht = fetch_release_sha256(
    "x86_64 xsht",
    f"https://github.com/laputa-systems/xsh/releases/download/${tag}/xsht-${tag}-x86_64-linux-musl.sha256",
  )?
  let core_url = f"https://github.com/laputa-systems/xsh/releases/download/${tag}/core-${tag}.sha256"
  let core = fetch_release_sha256("core scripts", core_url)?
  return {
    aarch64_xsh,
    aarch64_xshi,
    aarch64_xsht,
    x86_64_xsh,
    x86_64_xshi,
    x86_64_xsht,
    core,
  }
}

proc replace_context_hashes(content: Str, hashes: Hashes) [error] -> Result[Str] {
  let hash_re = regex.compile("[0-9a-f]{64}")?
  let lines = content.lines()
  var result: List[Str] = []
  var arch = "aarch64"
  var binary = "xsh"

  for line in lines {
    var l = line
    if "aarch64" in line or "arm64" in line {
      arch = "aarch64"
    } else if "x86_64" in line or "amd64" in line {
      arch = "x86_64"
    }

    if "CORE_SHA" in line or "core-" in line {
      binary = "core"
    } else if "XSHI" in line or "xshi-" in line {
      binary = "xshi"
    } else if "XSHT" in line or "xsht-" in line {
      binary = "xsht"
    } else if "XSH" in line or "xsh-" in line {
      binary = "xsh"
    }

    let caps = hash_re.captures(l)
    if caps.len() >= 1 {
      let new_hash = if binary == "core" {
        hashes.core
      } else if arch == "aarch64" and binary == "xsh" {
        hashes.aarch64_xsh
      } else if arch == "aarch64" and binary == "xshi" {
        hashes.aarch64_xshi
      } else if arch == "aarch64" {
        hashes.aarch64_xsht
      } else if binary == "xsh" {
        hashes.x86_64_xsh
      } else if binary == "xshi" {
        hashes.x86_64_xshi
      } else {
        hashes.x86_64_xsht
      }
      l = l.replace(caps[0], new_hash)
    }

    result = result.push(l)
  }

  return result.join("\n")
}

proc find_old_tag(content: Str) [error] -> Result[Str] {
  let tag_re = regex.compile("release-[0-9a-f]{40}")?

  for line in content.lines() {
    let caps = tag_re.captures(line)

    if caps.len() >= 1 {
      return caps[0]
    }
  }

  return Err(FindError.NotFound(message: "no release tag found"))
}

proc update_file(file: Path, tag: Str, commit: Str, hashes: Hashes) [fs, error] -> Result[Bool] {
  if ! fs.exists(file)? {
    return false
  }

  let content = fs.read_text(file)?
  let old_tag = find_old_tag(content)?

  if old_tag == tag {
    return false
  }

  let old_commit = old_tag.replace("release-", "")
  var updated = content.replace(old_tag, tag)
  updated = updated.replace(old_commit, commit)
  updated = replace_context_hashes(updated, hashes)?

  if updated == content {
    return false
  }

  fs.write(file, updated)?
  return true
}

proc update_pkgbuild(file: Path, tag: Str, commit: Str, hashes: Hashes) [fs, error] -> Result[Bool] {
  if ! fs.exists(file)? {
    return false
  }

  let content = fs.read_text(file)?
  let old_tag = find_old_tag(content)?

  if old_tag == tag {
    return false
  }

  let old_commit = old_tag.replace("release-", "")
  var updated = content.replace(old_tag, tag)
  updated = updated.replace(old_commit, commit)
  let hash_re = regex.compile("[0-9a-f]{64}")?
  let rel_re = regex.compile("export let rel: Str = \"(\\d+)\"")?
  var arch = "aarch64"
  var binary = "xsh"
  var bumped = false
  var new_lines: List[Str] = []

  for line in updated.lines() {
    var l = line

    if "arch: \"aarch64\"" in l {
      arch = "aarch64"
    } else if "arch: \"x86_64\"" in l {
      arch = "x86_64"
    }

    if "xsh-core" in l or "core-" in l {
      binary = "core"
    } else if "xshi-bin" in l or "xshi-" in l {
      binary = "xshi"
    } else if "xsht-bin" in l or "xsht-" in l {
      binary = "xsht"
    } else if "xsh-bin" in l or "xsh-" in l {
      binary = "xsh"
    }

    let caps = hash_re.captures(l)

    if caps.len() >= 1 {
      let new_hash = if binary == "core" {
        hashes.core
      } else if arch == "aarch64" and binary == "xsh" {
        hashes.aarch64_xsh
      } else if arch == "aarch64" and binary == "xshi" {
        hashes.aarch64_xshi
      } else if arch == "aarch64" {
        hashes.aarch64_xsht
      } else if binary == "xsh" {
        hashes.x86_64_xsh
      } else if binary == "xshi" {
        hashes.x86_64_xshi
      } else {
        hashes.x86_64_xsht
      }
      l = l.replace(caps[0], new_hash)
    }

    if ! bumped {
      let rel_caps = rel_re.captures(l)

      if rel_caps.len() >= 2 {
        let old_rel = rel_caps[1].parse_int()?
        l = f"export let rel: Str = \"${old_rel + 1}\""
        bumped = true
      }
    }

    new_lines = new_lines.push(l)
  }

  updated = new_lines.join("\n")

  if updated == content {
    return false
  }

  fs.write(file, updated)?
  return true
}

proc main(...argv: List[Str]) [fs, net, error] {
  if argv.len() != 1 {
    print "usage: update-xsh.xsh RELEASE-TAG"
    print "  e.g. update-xsh.xsh release-f46249e1647af0ffb9cc7abf6592218029c30ff1"
    return
  }

  let tag = argv[0]
  let commit = tag.replace("release-", "")
  print f"updating xsh to ${tag}"
  print "fetching release asset hashes..."
  let hashes = fetch_new_hashes(tag)?
  print f"  aarch64 xsh:  ${hashes.aarch64_xsh}"
  print f"  aarch64 xshi: ${hashes.aarch64_xshi}"
  print f"  aarch64 xsht: ${hashes.aarch64_xsht}"
  print f"  x86_64 xsh:   ${hashes.x86_64_xsh}"
  print f"  x86_64 xshi:  ${hashes.x86_64_xshi}"
  print f"  x86_64 xsht:  ${hashes.x86_64_xsht}"
  print f"  core:    ${hashes.core}"

  let laputa_files = [
    fp"Makefile",
    fp"Dockerfile.build-essential-native",
    fp"Dockerfile.bootstrap-build-essential-native",
    fp".github/workflows/laputa-validate.yml",
  ]

  let pkgbuilds = [fp"../packages/repo/xsh/PKGBUILD.xsh"]
  print "updating laputa repo files..."

  for file in laputa_files {
    if update_file(file, tag, commit, hashes)? {
      print f"  ${file}"
    }
  }

  print "updating PKGBUILDs..."

  for file in pkgbuilds {
    if update_pkgbuild(file, tag, commit, hashes)? {
      print f"  ${file} (rel bumped)"
    }
  }

  print "done"
}

main(@args)?
