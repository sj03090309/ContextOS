#!/usr/bin/env python3
"""Prove unsafe output is rejected before building and failed publish rolls back."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import package_output


class PackageOutputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="contextos-package-output-")
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def reject_before_build(self, output):
        script = Path(__file__).with_name("package_app.sh").resolve()
        result = subprocess.run(["bash", str(script), "--output", str(output),
                                 "--binary-dir", str(self.root / "missing-binaries")],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Packaging stopped:", result.stderr)
        self.assertNotIn("Missing Release binary", result.stderr)

    def test_applications_and_alias_are_rejected_before_build(self):
        self.reject_before_build(Path("/Applications"))
        self.reject_before_build(Path.home() / "Applications")
        alias = self.root / "installed-alias"
        alias.symlink_to("/Applications", target_is_directory=True)
        self.reject_before_build(alias / "build-output")

    def test_existing_app_and_symlink_are_preserved(self):
        app = self.root / "ContextOS.app"
        app.mkdir()
        sentinel = app / "UNRELATED_USER_FILE"
        sentinel.write_text("preserve")
        self.reject_before_build(self.root)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["ContextOS.app"])
        output_alias = self.root / "output-link"
        output_alias.symlink_to(self.root / "fresh", target_is_directory=True)
        self.reject_before_build(output_alias)
        self.assertFalse((self.root / "fresh").exists())

    def fixture(self):
        output = self.root / "output"
        output.mkdir()
        stage = output / ".package-fixture"
        stage.mkdir()
        for name in ["release.zip", "release.sha256"]:
            (stage / name).write_text(name)
        (stage / "ContextOS.app").mkdir()
        (stage / "ContextOS.app/binary").write_text("candidate")
        return output, stage, ["release.zip", "release.sha256", "ContextOS.app"]

    def test_success_publishes_app_and_archive(self):
        output, stage, names = self.fixture()
        package_output.publish(stage, output, names)
        self.assertEqual((output / "ContextOS.app/binary").read_text(), "candidate")
        self.assertTrue(all((output / name).exists() for name in names))
        self.assertEqual(list(stage.iterdir()), [])

    def test_publish_failure_restores_staged_artifacts(self):
        output, stage, names = self.fixture()
        real_rename = os.rename
        count = 0
        def fail_second(source, target):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError("simulated publication failure")
            return real_rename(source, target)
        with patch.object(package_output.os, "rename", side_effect=fail_second):
            with self.assertRaisesRegex(OSError, "simulated"):
                package_output.publish(stage, output, names)
        self.assertTrue(all((stage / name).exists() for name in names))
        self.assertTrue(all(not (output / name).exists() for name in names))

    def test_existing_archive_is_never_replaced(self):
        output, stage, names = self.fixture()
        (output / "release.zip").write_text("old archive")
        with self.assertRaisesRegex(ValueError, "Refusing to replace"):
            package_output.publish(stage, output, names)
        self.assertEqual((output / "release.zip").read_text(), "old archive")
        self.assertTrue(all((stage / name).exists() for name in names))


if __name__ == "__main__":
    unittest.main()
