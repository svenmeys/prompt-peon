"""The rules that keep the package split safely. Breaking one of these breaks something quietly."""
import ast
import os
import re
import shutil
import subprocess
import sys
import unittest


from bridge_helpers import ROOT, Base
from promptpeon import settings

PACKAGE = ROOT / "bridge/promptpeon"
MODULES = sorted(PACKAGE.glob("*.py"))


def parsed(path):
    return ast.parse(path.read_text(encoding="utf-8"), feature_version=(3, 10))


class Layout(unittest.TestCase):
    def test_every_module_says_what_it_is_for(self):
        for path in MODULES:
            self.assertTrue(ast.get_docstring(parsed(path)), path.name)

    def test_link_can_still_parse_on_the_t3_machines_python(self):
        # The floor for `link` is 3.10, and every module gets imported. Annotations stay unevaluated, for the same reason.
        for path in MODULES:
            tree = parsed(path)
            if path.name != "__init__.py":
                self.assertTrue(any(isinstance(node, ast.ImportFrom) and node.module == "__future__" for node in tree.body), path.name)

    def test_modules_import_modules_so_a_patch_reaches_every_caller(self):
        names = {path.stem for path in MODULES}
        for path in MODULES:
            for node in ast.walk(parsed(path)):
                if isinstance(node, ast.ImportFrom) and node.level:
                    self.assertIsNone(node.module, f"{path.name} imports a name, not a module")
                    self.assertLessEqual({alias.name for alias in node.names}, names, path.name)

    def test_everything_is_imported_at_startup(self):
        # An install replaces these files under a copy that's running, and uninstall deletes them. A late import would
        # read the new version, or nothing at all.
        for path in MODULES:
            for scope in ast.walk(parsed(path)):
                if isinstance(scope, ast.FunctionDef):
                    for node in ast.walk(scope):
                        self.assertFalse(isinstance(node, ast.ImportFrom) and node.level, f"{path.name}: {scope.name}")

    def test_no_local_name_hides_a_module(self):
        # `safefiles = ...` in a function would make every `safefiles.write_atomic` in it fail, but only when it runs.
        for path in MODULES:
            tree = parsed(path)
            imported = {alias.name for node in tree.body if isinstance(node, ast.ImportFrom) and node.level for alias in node.names}
            for scope in ast.walk(tree):
                if isinstance(scope, ast.FunctionDef):
                    arguments = {argument.arg for argument in ast.walk(scope.args) if isinstance(argument, ast.arg)}
                    stored = {node.id for node in ast.walk(scope) if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store)}
                    self.assertEqual((arguments | stored) & imported, set(), f"{path.name}: {scope.name}")

    def test_the_version_has_one_home(self):
        homes = [path.name for path in (*MODULES, ROOT / "bridge/promptpeon_bridge.py") if re.search(r'^VERSION = "', path.read_text(encoding="utf-8"), re.M)]
        self.assertEqual(homes, ["settings.py"])

    def test_only_settings_works_out_where_the_program_is(self):
        # Anywhere else, __file__ would name that module and not the entry point.
        users = [path.name for path in MODULES if "__file__" in path.read_text(encoding="utf-8")]
        self.assertEqual(users, ["settings.py"])

    def test_the_entry_point_is_where_settings_says(self):
        self.assertTrue((settings.PROGRAM_DIR / settings.ENTRY_POINT).is_file())
        self.assertEqual(settings.PROGRAM_DIR.name, "bridge")
        self.assertEqual((settings.PROGRAM_DIR / settings.PACKAGE).resolve(), PACKAGE.resolve())


class Isolated(Base):
    def test_nothing_planted_beside_the_program_runs_under_python_isolated_mode(self):
        copy = self.dir / "bridge"
        shutil.copytree(ROOT / "bridge", copy, ignore=shutil.ignore_patterns("__pycache__"))
        planted = self.dir / "elsewhere"
        planted.mkdir()
        for folder in (copy, planted):
            (folder / "json.py").write_text("raise SystemExit('a planted module ran')\n")
        (planted / "promptpeon.py").write_text("raise SystemExit('a planted module ran')\n")
        done = subprocess.run([sys.executable, "-I", str(copy / settings.ENTRY_POINT), "--help"], capture_output=True, text=True, timeout=60,
                              cwd=planted, env=dict(os.environ, PYTHONPATH=str(planted)))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertNotIn("planted", done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
