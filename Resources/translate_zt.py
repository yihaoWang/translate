#!/usr/bin/env python3
import sys


def main() -> int:
    source = sys.argv[1] if len(sys.argv) > 1 else "en"
    text = sys.stdin.read().strip()
    if not text:
        return 0

    try:
        if source in {"zh", "zt", "zh-Hant", "zh-TW"}:
            from opencc import OpenCC

            print(OpenCC("s2t").convert(text))
            return 0

        from argostranslate import translate

        if source == "ja":
            english = translate.translate(text, "ja", "en")
            translated = translate.translate(english, "en", "zt")
        else:
            translated = translate.translate(text, source, "zt")
        print(translated.strip())
        return 0
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
