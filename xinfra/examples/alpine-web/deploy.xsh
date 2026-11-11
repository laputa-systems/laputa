##! A complete Alpine web host: a package, a service account, a rendered
##! configuration validated before it replaces the live one, content, and an
##! OpenRC service that reloads or restarts when they change.

use infra.declare
use infra.model

pure number(host: model.Host, name: Str, fallback: Int) -> Result[Int, Error] {
  match host.vars.get(name) {
    Ok(value) => value.require(Int)
    Err(_) => Ok(fallback)
  }
}

pure text(host: model.Host, name: Str, fallback: Str) -> Result[Str, Error] {
  match host.vars.get(name) {
    Ok(value) => value.require(Str)
    Err(_) => Ok(fallback)
  }
}

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  let data = json.encode({
    host: host.name,
    port: number(host, "port", 8080)?,
    title: text(host, "title", "xsh-infra example")?,
    root: "/srv/www",
  })?
  [
    declare.package(id: "lighttpd", name: "lighttpd")?,
    declare.group_account(id: "web-group", name: "webops")?,
    declare.user_account(id: "web-user", name: "webops", primary_group: "webops", groups: ["wheel"], shell: "/bin/ash", needs: ["web-group"])?,
    declare.directory(id: "web-root", at: "/srv/www", owner: "webops", group_name: "webops", mode: 0o755, parents: true, needs: ["web-user"])?,
    declare.file(
      id: "web-page",
      at: "/srv/www/index.html",
      template_file: p"examples/alpine-web/files/index.html.tmpl",
      template_json: data,
      owner: "webops",
      group_name: "webops",
      mode: 0o644,
      needs: ["web-root"],
    )?,
    declare.file(
      id: "web-conf",
      at: "/etc/lighttpd/lighttpd.conf",
      template_file: p"examples/alpine-web/files/lighttpd.conf.tmpl",
      template_json: data,
      mode: 0o644,
      validate: ["lighttpd", "-tt", "-f", "{}"],
      needs: ["lighttpd", "web-root"],
    )?,
    declare.symlink(id: "web-current", at: "/srv/www/current.html", target: "index.html", needs: ["web-page"])?,
    declare.service(id: "web-service", name: "lighttpd", enabled: true, running: true, reload_on: ["web-page"], restart_on: ["web-conf"], needs: ["lighttpd"])?,
  ]
}
