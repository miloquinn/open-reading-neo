import tempfile
import unittest
from pathlib import Path

from tool.generate_changelog import build_catalog, parse_release_notes


class GenerateChangelogTest(unittest.TestCase):
    def test_extracts_bullets_and_ignores_version_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "v9.1.0.md"
            path.write_text(
                "# Open Reading v9.1.0\n\n"
                "## Changes\n\n"
                "- **Fast** reading with [details](https://example.com).\n"
                "\n## Version\n\n- Version: `9.1.0`\n",
                encoding="utf-8",
            )

            self.assertEqual(
                parse_release_notes(path),
                ["Fast reading with details."],
            )

    def test_adds_markdown_versions_and_preserves_existing_localizations(self):
        with tempfile.TemporaryDirectory() as directory:
            notes_dir = Path(directory) / "release-notes"
            notes_dir.mkdir()
            (notes_dir / "v9.1.0.md").write_text(
                "# Open Reading v9.1.0\n\n## Changes\n\n- New feature\n",
                encoding="utf-8",
            )
            existing = {
                "schemaVersion": 1,
                "entries": [
                    {
                        "version": "9.0.0",
                        "notes": {
                            "en": ["Existing translation"],
                            "zh": ["已有翻译"],
                        },
                    }
                ],
            }

            catalog = build_catalog(notes_dir, existing)

            self.assertEqual(
                [entry["version"] for entry in catalog["entries"]],
                ["9.1.0", "9.0.0"],
            )
            self.assertEqual(catalog["entries"][0]["notes"]["zh"], ["New feature"])
            self.assertEqual(
                catalog["entries"][1]["notes"]["en"],
                ["Existing translation"],
            )


if __name__ == "__main__":
    unittest.main()
