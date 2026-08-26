import json
import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
PLUGIN = REPO / "plugin"


def plugin_sources():
    for path in PLUGIN.iterdir():
        if path.is_file():
            text = path.read_text()
            code = "\n".join(line.split("//", 1)[0] for line in text.splitlines())
            yield path, code


class PluginTests(unittest.TestCase):
    def test_manifest_names_safe_files_present_in_the_clone(self):
        manifest = json.loads((REPO / "manifest.json").read_text())
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "sphiment.omavcamd")
        self.assertEqual(manifest["kinds"], ["bar-widget"])
        entry_points = manifest["entryPoints"]
        self.assertTrue(entry_points["barWidget"].endswith(".qml"))
        for entry_point in entry_points.values():
            path = Path(entry_point)
            self.assertFalse(path.is_absolute())
            self.assertNotIn("..", path.parts)
            self.assertEqual(path.parts[0], "plugin")
            self.assertTrue((REPO / path).is_file(), entry_point)

    def test_wrapper_asks_the_daemon_and_runs_nothing(self):
        sources = list(plugin_sources())
        self.assertTrue(sources)
        for path, code in sources:
            for forbidden in ("Process", "execDetached", "scrcpy", "modprobe", "hyprctl"):
                self.assertNotIn(forbidden, code, f"{path}: client invokes {forbidden}")

    def test_preview_uses_live_omarchy_theme_tokens(self):
        panel = (PLUGIN / "Panel.qml").read_text()
        for expected in (
            'label: "Preview"', "Style.cornerRadius", "Style.normalBorderWidth",
            'send("preview"', "daemonState.preview_style",
            "if (message.ok) syncPreviewStyle()", 'known.transport === "wireless"',
            "item.phone.serial === known.hardware_id", "FloatingWindow",
            'title: "vcamd reconnecting"',
            "visible: root.reconnecting && root.previewing",
            "activeColor: root.reconnecting ? root.urgent",
        ):
            self.assertIn(expected, panel)

    def test_daemon_text_cannot_become_markup(self):
        for path, code in plugin_sources():
            if "JSON.parse" in code:
                self.assertIn("plain(JSON.parse(line))", code, str(path))
                self.assertIn('replace(/[<>]/g, "")', code, str(path))
            self.assertEqual(code.count("Text {"), code.count("textFormat: Text.PlainText"), str(path))

    def test_missing_engine_shows_a_guide(self):
        panel = (PLUGIN / "Panel.qml").read_text()
        self.assertIn("vcamd-git", panel)
        self.assertIn("pacman -U", panel)
        self.assertIn("daemonState.missing", panel)
        self.assertNotRegex(panel, re.compile(r"\bProcess\s*\{"))


if __name__ == "__main__":
    unittest.main()
