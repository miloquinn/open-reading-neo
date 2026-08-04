import unittest

from reading_source_lab.audit import audit_files
from reading_source_lab.parser import parse_payload


class ParserTest(unittest.TestCase):
    def test_parses_wrappers_and_keeps_last_duplicate(self):
        result = parse_payload(
            {
                "sources": [
                    {"bookSourceName": "old", "bookSourceUrl": "https://same.test"},
                    {"bookSourceName": "new", "bookSourceUrl": "https://same.test"},
                ]
            }
        )

        self.assertEqual(result.duplicates, 1)
        self.assertEqual([source.name for source in result.sources], ["new"])

    def test_collects_nested_source_urls_without_fetching(self):
        result = parse_payload({"sourceUrls": ["https://list.test/a.json"]})

        self.assertEqual(result.source_urls, ["https://list.test/a.json"])
        self.assertEqual(result.sources, [])
        self.assertEqual(result.errors, [])

    def test_keeps_invalid_url_for_audit_instead_of_losing_the_record(self):
        result = parse_payload(
            [{"bookSourceName": "legacy", "bookSourceUrl": "{{dynamicUrl}}"}]
        )

        self.assertEqual(len(result.sources), 1)
        self.assertFalse(result.sources[0].is_http_url)

    def test_audits_script_and_java_collection_api_usage(self):
        import json
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sources.json"
            path.write_text(
                json.dumps(
                    [
                        {
                            "bookSourceName": "script",
                            "bookSourceUrl": "https://script.test",
                            "ruleContent": {
                                "content": "@js:source.put('x','1'); java.getStringList('li').size()"
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )
            report = audit_files([path])

        self.assertEqual(report["script_api_totals"]["source.put"], 1)
        self.assertEqual(report["script_api_totals"]["java.getStringList"], 1)
        self.assertEqual(report["java_collection_api_totals"]["size"], 1)

    def test_ignores_empty_optional_capability_fields(self):
        import json
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sources.json"
            path.write_text(
                json.dumps(
                    [
                        {
                            "bookSourceName": "plain",
                            "bookSourceUrl": "https://plain.test",
                            "loginUrl": "",
                            "loginUi": "",
                            "loginCheckJs": "",
                            "webJs": "",
                            "jsLib": "",
                            "enabledCookieJar": False,
                            "bookSourceComment": "old WebView login example",
                            "searchUrl": "/search?key={{key}},{\"webView\":false}",
                            "ruleSearch": {"bookList": ".book"},
                            "ruleToc": {"chapterList": ".chapter"},
                            "ruleContent": {"content": "article@text"},
                        }
                    ]
                ),
                encoding="utf-8",
            )
            report = audit_files([path])

        self.assertEqual(report["files"][0]["compatibility"], {"supported": 1})
        for feature in ("login", "webview", "cookie", "shared_script"):
            self.assertNotIn(feature, report["feature_totals"])
        self.assertEqual(report["files"][0]["core_reading"], {"ready": 1})


if __name__ == "__main__":
    unittest.main()
