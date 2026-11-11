from pyinfra.operations import files, server

files.directory(name="dir", path="/var/tmp/pi", present=True, _sudo=False)
server.shell(name="creates", commands="test -e /var/tmp/pi/created || { echo x >> /var/tmp/pi/creates.log; touch /var/tmp/pi/created; }", _sudo=False)
server.shell(name="always", commands="echo x >> /var/tmp/pi/always.log", _sudo=False)
