import importlib.util
import pathlib
import tempfile
import unittest
from unittest import mock

path = pathlib.Path(__file__).with_name("restore_drill.py")
spec = importlib.util.spec_from_file_location("restore_drill", path)
drill = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drill)


class ConsoleReplayTest(unittest.TestCase):
    def test_replay_waits_for_current_guest_output(self):
        with tempfile.TemporaryDirectory(dir=drill.scratch) as directory:
            console = pathlib.Path(directory) / "console"
            console.write_text(drill.VERIFY_OK)
            with mock.patch.object(drill.subprocess, "Popen"):
                _, err = drill.launch(["qemu", "-serial", "old", "-append", ""],
                                      console, pathlib.Path(directory) / "qemu.log")
            err.close()
            with mock.patch.object(drill.time, "time", side_effect=[0, 0, 2]), \
                 mock.patch.object(drill.time, "sleep"):
                with self.assertRaises(RuntimeError):
                    drill.wait_for(console, drill.VERIFY_OK, 1)
            console.write_text(drill.VERIFY_OK)
            drill.wait_for(console, drill.VERIFY_OK, 1)


if __name__ == "__main__":
    unittest.main()
