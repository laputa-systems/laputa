from pyinfra.operations import apk

apk.packages(name="pkgs", packages=["tree"], present=False, update=False, _sudo=False)
