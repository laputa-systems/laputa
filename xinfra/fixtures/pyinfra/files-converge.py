from pyinfra.operations import files, server

files.directory(name="dir", path="/var/tmp/pi/dir", mode="750", user="root", group="wheel", present=True, _sudo=False)
files.put(name="file", src="/work/motd", dest="/var/tmp/pi/dir/motd", mode="640", user="root", group="wheel", _sudo=False)
files.link(name="link", path="/var/tmp/pi/dir/current", target="motd", _sudo=False)
server.group(name="grp", group="pig", gid=4401, _sudo=False)
server.user(name="usr", user="piu", uid=4402, group="pig", shell="/bin/ash", home="/home/piu", ensure_home=True, _sudo=False)
