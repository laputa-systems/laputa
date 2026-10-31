##! Build a maintained state image with the first-boot operator's inode owners.
use system.first_boot

proc main(...argv: List[Str]) [fs, process, error] {
  guard argv.len() == 5 else {
    fail "usage: maintained_state_image.xsh STATE_ROOT OUTPUT SIZE FORMATTER XSH"
  }
  let root = Path(argv[0])
  let output = Path(argv[1])
  let size = argv[2].parse_int()?
  let formatter = Path(argv[3])
  let xsh = Path(argv[4])
  let owners = first_boot.state_ownership(root)?
  with scratch = fs.tempdir_in(output.parent())? {
    let owner_file = fp"{scratch.host_path()?}/owners.json"
    json.write(owner_file, owners)?
    atomically replace output as temporary {
      temporary.write(b"")?
      temporary.chmod(0o600)?
      temporary.truncate(size)?
      let status = process.run(process.command_argv(xsh, [xsh.display(), formatter.display(), "--", "-d", root.display(), "--inode-owners", owner_file.display(), temporary.display()]))?
      guard status.ok else { fail "maintained state image formatter failed" }
      fs.fsync(temporary)?
    }
  }
}
main(@args)?
