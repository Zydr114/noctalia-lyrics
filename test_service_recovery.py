from pathlib import Path
import shutil
import subprocess
import unittest


class ServiceRecoveryTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("lua"), "Lua is required for service simulations")
    def test_service_recovery_scenarios(self):
        root = Path(__file__).resolve().parent
        result = subprocess.run(["lua", str(root / "tests/service_recovery.lua"), str(root / "lyrics_service.luau")],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("10 service recovery scenarios passed", result.stdout)
