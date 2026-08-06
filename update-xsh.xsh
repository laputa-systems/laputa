#!/bin/xsh
type Hashes = {aarch64: Str, x86_64: Str, core: Str}

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
  let aarch64_url = f"https://github.com/laputa-systems/xsh/releases/download/${tag}/xsh-multicall-${tag}-aarch64-linux-musl.sha256"
  let aarch64 = fetch_release_sha256("aarch64 multicall", aarch64_url)?
  let x86_64_url = f"https://github.com/laputa-systems/xsh/releases/download/${tag}/xsh-multicall-${tag}-x86_64-linux-musl.sha256"
  let x86_64 = fetch_release_sha256("x86_64 multicall", x86_64_url)?
  let core_url = f"https://github.com/laputa-systems/xsh/releases/download/${tag}/core-${tag}.sha256"
  let core = fetch_release_sha256("core scripts", core_url)?
  return {aarch64: aarch64, x86_64: x86_64, core: core}
}

pure hash_context(line: Str) -> Str {
  if "XSH_CORE_SHA" in line {
    return "core"
  }

  if "aarch64" in line or "arm64" in line {
    return "aarch64"
  }

  if "x86_64" in line or "amd64" in line {
    return "x86_64"
  }

  if "core" in line and "sha256sum" in line {
    return "core"
  }

  return ""
}

proc replace_context_hashes(content: Str, hashes: Hashes) [error] -> Result[Str] {
  let hash_re = regex.compile("[0-9a-f]{64}")?
  let lines = content.lines()
  var result: List[Str] = []
  var prev = ""

  for line in lines {
    var l = line
    var htype = hash_context(l)

    if htype == "" {
      htype = hash_context(prev)
    }

    if htype != "" {
      let caps = hash_re.captures(l)

      if caps.len() >= 1 {
        let new_hash = match htype { "aarch64" => hashes.aarch64, "x86_64" => hashes.x86_64, _ => hashes.core }
        l = l.replace(caps[0], new_hash)
      }
    }

    result = result.push(l)
    prev = line
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
  var in_aarch64 = false
  var in_x86_64 = false
  var in_checksums = false
  var aarch64_binary_done = false
  var x86_64_binary_done = false
  var generic_core_done = false
  var aarch64_core_done = false
  var x86_64_core_done = false
  var bumped = false
  var new_lines: List[Str] = []

  for line in updated.lines() {
    var l = line

    if "export let checksums_aarch64" in l {
      in_aarch64 = true
      in_x86_64 = false
      in_checksums = false
      aarch64_binary_done = false
      aarch64_core_done = false
    } else if "export let checksums_x86_64" in l {
      in_aarch64 = false
      in_x86_64 = true
      in_checksums = false
      x86_64_binary_done = false
      x86_64_core_done = false
    } else if "export let checksums:" in l {
      in_aarch64 = false
      in_x86_64 = false
      in_checksums = true
      generic_core_done = false
    }

    let caps = hash_re.captures(l)

    if caps.len() >= 1 {
      if in_aarch64 and ! aarch64_binary_done {
        l = l.replace(caps[0], hashes.aarch64)
        aarch64_binary_done = true
      } else if in_aarch64 and ! aarch64_core_done {
        l = l.replace(caps[0], hashes.core)
        aarch64_core_done = true
      } else if in_x86_64 and ! x86_64_binary_done {
        l = l.replace(caps[0], hashes.x86_64)
        x86_64_binary_done = true
      } else if in_x86_64 and ! x86_64_core_done {
        l = l.replace(caps[0], hashes.core)
        x86_64_core_done = true
      } else if in_checksums and ! generic_core_done {
        l = l.replace(caps[0], hashes.core)
        generic_core_done = true
      }
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
  print f"  aarch64: ${hashes.aarch64}"
  print f"  x86_64:  ${hashes.x86_64}"
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
