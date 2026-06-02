#!/usr/bin/env python3
import sys


def main() -> int:
    source = sys.argv[1] if len(sys.argv) > 1 else "en"
    text = sys.stdin.read().strip()
    if not text:
        return 0

    try:
        if source in {"", "auto"}:
            latin_count = sum(1 for char in text if ("A" <= char <= "Z") or ("a" <= char <= "z"))
            kana_count = sum(1 for char in text if "\u3040" <= char <= "\u30ff")
            han_count = sum(1 for char in text if "\u4e00" <= char <= "\u9fff")
            if latin_count >= max(4, kana_count + han_count):
                source = "en"
            elif kana_count:
                source = "ja"
            elif han_count:
                source = "zh"
            else:
                source = "ja"

        if source in {"zh", "zt", "zh-Hant", "zh-TW"}:
            from opencc import OpenCC

            print(OpenCC("s2t").convert(text))
            return 0

        from argostranslate import translate

        if source == "ja":
            languages = {language.code: language for language in translate.get_installed_languages()}
            translated = None
            source_language = languages.get("ja")
            if source_language is not None:
                for target in ("zt", "zh", "zh-Hant", "zh-TW"):
                    if any(item.to_lang.code == target for item in source_language.translations_to):
                        translated = translate.translate(text, "ja", target)
                        break
            if translated is None:
                english = translate.translate(text, "ja", "en")
                translated = translate.translate(english, "en", "zt")
        else:
            translated = translate.translate(text, source, "zt")
        try:
            from opencc import OpenCC

            translated = OpenCC("s2t").convert(translated.strip())
        except Exception:
            translated = translated.strip()

        print(translated)
        return 0
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
