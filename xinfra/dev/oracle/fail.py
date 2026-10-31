from pyinfra.operations import apk

apk.packages("xinfra-no-such-package", present=True)
