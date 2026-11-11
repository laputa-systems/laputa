from pyinfra.operations import apk

apk.packages(name="pkgs", packages=["jq", "tree"], present=True, update=False, _sudo=False)
