use pm.remote
use pm.types

proc stop_mirror(child: ProcessHandle) [process, error] {
  match process.kill(child.pid, signal: "KILL") {
    Ok(_) => {},
    Err(_) => {}
  }
  match process.wait_any([child]) {
    Ok(_) => {},
    Err(_) => {}
  }
}

test immutable_http_publication_across_chunk_boundary [fs, process, env, time, net, error] { |ctx|
  test.timeout(ctx, 10m)
  let root = test.temp_dir(ctx, name: "chunked-mirror")?
  let data = fp"{root}/data"
  let output = fp"{root}/server.log"
  let mirror = path.absolute(p".out/host/x86_64/laputa-mirror")?
  let child = spawn run $mirror --local $data --listen "127.0.0.1:0" > $output 2> $output ?
  defer stop_mirror(child)?
  wait until output.exists()? and "(local mode, no auth)" in output.read_text()? within 20s every 50ms
  let url = output.read_text()?.split(" ")[0]
  let source = fp"{root}/source"
  source.write(b"laputa")?
  source.truncate(67108864)?
  let work = fp"{root}/work"
  let exact = p"sources/zlib/zlib-1.3.2-5-aarch64-src.tar.bz2"
  let large = p"sources/zlib/zlib-1.3.2-6-aarch64-src.tar.bz2"
  assert remote.upload_immutable_repo_file(url, exact, source, "", work)?
  let fetched = fp"{root}/fetched"
  assert remote.try_fetch_repo_file(url, exact, fetched)? == ""
  assert fetched.read_bytes()? == source.read_bytes()?
  source.truncate(67108865)?
  let _ = bytes.write_at(source, 67108864, b"a")?
  assert remote.upload_immutable_repo_file(url, large, source, "", work)?
  assert remote.try_fetch_repo_file(url, large, fetched)? == ""
  assert fetched.read_bytes()? == source.read_bytes()?
  assert ! remote.upload_immutable_repo_file(url, large, source, "", work)?
  let _ = bytes.write_at(source, 67108864, b"b")?
  match remote.upload_immutable_repo_file(url, large, source, "", work) {
    Ok(_) => test.fail("different bytes were accepted"),
    Err(problem) => assert problem == types.PmError.PackageConflict(f"immutable remote object {large} already exists with different bytes")
  }
  assert remote.try_fetch_repo_file(url, large, fetched)? == ""
  let _ = bytes.write_at(source, 67108864, b"a")?
  assert fetched.read_bytes()? == source.read_bytes()?
}
