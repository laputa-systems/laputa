import os

from pyinfra.operations import apk, files, openrc, server

BASE = "/home/xinfra/xinfra-q1"

files.directory(f"{BASE}/dir", user="xinfra", group="xinfra", mode="755")
files.put(src=os.path.join(os.path.dirname(__file__), "files/motd.txt"), dest=f"{BASE}/dir/motd", user="xinfra", group="xinfra", mode="644")
apk.packages("tree", present=True)
server.group("xinfra-q1-group", gid=1600)
server.user(
    "xinfra-q1-user",
    home=f"{BASE}/home",
    shell="/bin/sh",
    group="xinfra-q1-group",
    create_home=True,
)
server.shell(commands=f"printf pyinfra > {BASE}/command")
openrc.service("crond", running=True, enabled=True)
