import importlib.util
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO


spec = importlib.util.spec_from_file_location("install_backend", Path(__file__).parent / "scripts/install-backend.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class BackendInstallTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name) / "community/lyrics"
        self.base.mkdir(parents=True)
        (self.base / "plugin.toml").write_text('id = "h465855hgg/lyrics"\nversion = "1.5.5"\ndependencies = ["python3"]\n')
        (self.base / "lyrics.luau").write_text("existing user interface")
        self.destination = Path(self.temp.name) / "local/lyrics"
        self.backups = Path(self.temp.name) / "backups"

    def run_install(self, dry_run=False):
        with redirect_stdout(StringIO()):
            return installer.install(self.base, self.destination, self.backups, dry_run=dry_run)

    def test_dry_run_does_not_write(self):
        self.run_install(dry_run=True)
        self.assertFalse(self.destination.exists())

    def test_preserves_ui_and_version_and_copies_backend_module(self):
        self.run_install()
        self.assertEqual((self.destination / "lyrics.luau").read_text(), "existing user interface")
        self.assertIn('version = "1.5.5"', (self.destination / "plugin.toml").read_text())
        self.assertIn('"timeout"', (self.destination / "plugin.toml").read_text())
        self.assertEqual((self.destination / "music_sources.py").read_bytes(), (installer.ROOT / "music_sources.py").read_bytes())
        self.assertFalse((self.base / "music_sources.py").exists())
        self.assertNotIn('noctalia.getConfig("display_mode")', (self.destination / "lyrics_service.luau").read_text())

    def test_existing_override_is_backed_up(self):
        self.run_install()
        (self.destination / "lyrics.luau").write_text("old local interface")
        backup = self.run_install()
        self.assertEqual((backup / "lyrics.luau").read_text(), "old local interface")


if __name__ == "__main__":
    unittest.main()
