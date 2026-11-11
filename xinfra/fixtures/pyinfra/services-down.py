from pyinfra.operations import files, openrc

files.put(name="init", src="/work/xinfradiff", dest="/etc/init.d/xinfradiff", mode="755", user="root", group="root", _sudo=False)
openrc.service(name="svc", service="xinfradiff", running=False, enabled=False, _sudo=False)
