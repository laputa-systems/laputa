from pyinfra.operations import files, server

files.directory(name="dir", path="/var/tmp/pi", present=True, _sudo=False)
server.shell(name="first", commands="touch /var/tmp/pi/first", _sudo=False)
server.shell(name="boom", commands="exit 7", _sudo=False)
server.shell(name="last", commands="touch /var/tmp/pi/last", _sudo=False)
