##! The Alpine web example deployment: nginx, a webapp account, and its config.

use xinfra.model

## Returns the declaration-only resource list for the example.
export pure resources() -> List[model.Resource] {
  [
    model.Package(
      model.PackageSpec(
        id: "nginx-package",
        name: "nginx",
      ),
    ),
    model.GroupResource(
      model.GroupSpec(
        id: "webapp-group",
        name: "webapp",
        system: true,
      ),
    ),
    model.UserResource(
      model.UserSpec(
        id: "webapp-user",
        name: "webapp",
        home: p"/var/www",
        shell: p"/sbin/nologin",
        system: true,
        requires: ["webapp-group"],
      ),
    ),
    model.File(
      model.FileSpec(
        id: "motd",
        path: p"/etc/motd",
        source: model.Content("Welcome to Alpine Web\n"),
        owner: "root",
        group: "root",
        privilege: model.AsRoot,
      ),
    ),
    model.File(
      model.FileSpec(
        id: "nginx-config",
        path: p"/etc/nginx/nginx.conf",
        source: model.Templated(
          model.Template(
            path: p"templates/nginx.conf.tmpl",
            vars: {
              "server_name": "alpine-web",
              "root": "/var/www/localhost/htdocs",
            },
          ),
        ),
        owner: "root",
        group: "root",
        privilege: model.AsRoot,
        validate: model.Validation(argv: ["nginx", "-t", "-c"]),
        requires: ["nginx-package"],
        notify: ["nginx-service"],
      ),
    ),
    model.ServiceResource(
      model.ServiceSpec(
        id: "nginx-service",
        name: "nginx",
        state: model.Started,
        enabled: true,
        requires: ["nginx-package", "nginx-config"],
      ),
    ),
  ]
}
