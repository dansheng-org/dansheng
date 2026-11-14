"""Core resource selection used by APK audits in both repository layouts."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "audit_apk", Path(__file__).resolve().parents[1] / "audit-apk.py"
)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class CorePaths(unittest.TestCase):
    def test_monorepo_precedes_legacy_sibling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for core in (root / "core", root / "apps/dansheng-core"):
                (core / "include").mkdir(parents=True)
                (core / "Cargo.toml").write_text("[workspace]")
                (core / "include/dansheng.h").write_text("/* fixture */")
            self.assertEqual(audit.default_core_path(root / "apps/dansheng_app"), root / "core")
            self.assertEqual(audit.default_core_path(root / "app"), root / "core")
            self.assertEqual(audit.default_core_path(root / "other"), root / "dansheng-core")

    def test_missing_monorepo_core_uses_valid_legacy_sibling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            core = root / "apps/dansheng-core"
            (core / "include").mkdir(parents=True)
            (core / "Cargo.toml").write_text("[workspace]")
            (core / "include/dansheng.h").write_text("/* fixture */")
            self.assertEqual(audit.default_core_path(root / "apps/dansheng_app"), core)


if __name__ == "__main__":
    unittest.main()
