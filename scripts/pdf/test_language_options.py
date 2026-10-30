#!/usr/bin/env python3
"""PDF bridge language contract; no runtime download, credentials or requests."""
import importlib.util
from pathlib import Path
import unittest

BRIDGE = Path(__file__).resolve().parents[2] / "app/macos/Sources/TranslationWorkbench/Resources/PDF/babeldoc_bridge.py"
spec = importlib.util.spec_from_file_location("babeldoc_bridge_language_test", BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class LanguageOptionsTests(unittest.TestCase):
    def test_new_pair_reaches_engine_language_codes(self):
        self.assertEqual(bridge.translation_languages({"sourceLanguage": "ja", "targetLanguage": "fr"}), ("ja", "fr"))

    def test_chinese_and_regional_aliases_keep_engine_format(self):
        self.assertEqual(bridge.translation_languages({"sourceLanguage": "zh-Hans", "targetLanguage": "pt-BR"}), ("zh", "pt-br"))
        self.assertEqual(bridge.translation_languages({"sourceLanguage": "en", "targetLanguage": "zh-Hant"}), ("en", "zh-tw"))
        self.assertEqual(bridge.language_code("zh_CN"), "zh")

    def test_existing_pair_payloads_remain_compatible(self):
        self.assertEqual(bridge.translation_languages({"direction": "englishToChinese"}), ("en", "zh"))
        self.assertEqual(bridge.translation_languages({"direction": "chineseToEnglish"}), ("zh", "en"))

    def test_unsupported_or_incomplete_pairs_fail_before_translation(self):
        for request in [
            {"sourceLanguage": "en", "targetLanguage": "ar"},
            {"sourceLanguage": "en", "targetLanguage": "unknown"},
            {"sourceLanguage": "en"},
            {"sourceLanguage": ["en"], "targetLanguage": "fr"},
        ]:
            with self.subTest(request=request), self.assertRaises(bridge.BridgeFailure):
                bridge.translation_languages(request)


if __name__ == "__main__":
    unittest.main()
