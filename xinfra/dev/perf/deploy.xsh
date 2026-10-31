##! Performance deployment shared with the pyinfra oracle.
use xinfra.model

## The declared resources.
export pure resources() -> List[model.Resource] {
  [
    model.Directory(model.DirectorySpec(
      id: "dir",
      path: p"/home/xinfra/xinfra-q1/dir",
      owner: "xinfra",
      group: "xinfra",
      mode: 0o755,
    )),
    model.File(model.FileSpec(
      id: "motd",
      path: p"/home/xinfra/xinfra-q1/dir/motd",
      source: model.Content("hello from the oracle\n"),
      owner: "xinfra",
      group: "xinfra",
      mode: 0o644,
    )),
    model.Package(model.PackageSpec(id: "tree", name: "tree")),
    model.GroupResource(model.GroupSpec(id: "group", name: "xinfra-q1-group", gid: 1600)),
    model.UserResource(model.UserSpec(
      id: "user",
      name: "xinfra-q1-user",
      gid: 1600,
      home: p"/home/xinfra/xinfra-q1/home",
      shell: p"/bin/sh",
      create_home: true,
    )),
    model.CommandResource(model.CommandSpec(
      id: "command",
      shell: "printf pyinfra > /home/xinfra/xinfra-q1/command",
      always_run: true,
    )),
    model.ServiceResource(model.ServiceSpec(
      id: "crond",
      name: "crond",
      state: model.Started,
      enabled: true,
    )),
  ]
}
