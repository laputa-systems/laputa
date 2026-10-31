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


class VerifyOutputTest(unittest.TestCase):
    def setUp(self):
        self.valid = "\n".join([
            drill.PROOF_OK, drill.VERIFY_OK, f"{drill.MARKER_COUNT} 2",
            "RESTORE_CHECK_OK", "RESTORE_RESTIC_OK", "RESTORE_REBACKUP_OK",
            "RESTORE_KEYLOSS_OK", "RESTORE_SECOND_KEY_OK", "RESTORE_MASTERKEY_OK",
        ])

    def test_kernel_message_can_split_intermediate_dhcp_diagnostic(self):
        text = self.valid + "\nLAPUTAclocksource: Watchdog remote CPU 1 read timed out\n_MAINTAINED_DHCP_OK lease is bound with a managed resolver\n"
        drill.validate_verify_output(text)

    def test_missing_authoritative_proof_fails(self):
        with self.assertRaises(AssertionError):
            drill.validate_verify_output(self.valid.replace(drill.PROOF_OK, ""))

    def test_failure_marker_fails(self):
        for failure in (drill.FAILED, "RESTORE_FAILED", "Kernel panic", "not syncing"):
            with self.subTest(failure=failure), self.assertRaises(AssertionError):
                drill.validate_verify_output(self.valid + "\n" + failure)

    def test_missing_restore_marker_fails(self):
        with self.assertRaises(AssertionError):
            drill.validate_verify_output(self.valid.replace("RESTORE_MASTERKEY_OK", ""))


if __name__ == "__main__":
    unittest.main()
