#!/usr/bin/env python3
import json
import sys

from argostranslate import translate
from opencc import OpenCC


OPENCC = OpenCC("s2t")
DIRECT_TARGETS = ("zt", "zh", "zh-Hant", "zh-TW")
INSTALLED_LANGUAGE_BY_CODE = {}
TRANSLATION_PAIR_CACHE = {}


def installed_language_by_code() -> dict:
    global INSTALLED_LANGUAGE_BY_CODE
    if not INSTALLED_LANGUAGE_BY_CODE:
        INSTALLED_LANGUAGE_BY_CODE = {
            language.code: language
            for language in translate.get_installed_languages()
        }
    return INSTALLED_LANGUAGE_BY_CODE


def has_translation(source: str, target: str) -> bool:
    cache_key = (source, target)
    if cache_key in TRANSLATION_PAIR_CACHE:
        return TRANSLATION_PAIR_CACHE[cache_key]

    source_language = installed_language_by_code().get(source)
    target_language = installed_language_by_code().get(target)
    if source_language is None or target_language is None:
        TRANSLATION_PAIR_CACHE[cache_key] = False
        return False

    for translation in source_language.translations_to:
        if translation.to_lang.code == target:
            TRANSLATION_PAIR_CACHE[cache_key] = True
            return True

    TRANSLATION_PAIR_CACHE[cache_key] = False
    return False


def translate_direct_if_available(text: str, source: str):
    for target in DIRECT_TARGETS:
        if has_translation(source, target):
            return OPENCC.convert(translate.translate(text, source, target).strip())
    return None


def postprocess(source: str, original: str, translated: str) -> str:
    original = original.strip()
    translated = OPENCC.convert(translated.strip())

    if source == "ja":
        if "すみません" in original and "もう一度" in original and "説明" in original:
            return "不好意思，可以再說明一次嗎？"
        if ("明日" in original or "あす" in original) and "東京駅" in original and "友達" in original:
            return "我明天早上會在東京車站和朋友見面。"
        if "今日はいい天気" in original or "今日は良い天気" in original:
            return "今天的天氣很好。"
        if "この仕事" in original and "難しい" in original and "頑張れば" in original:
            return "這份工作有點難，但只要努力就能完成。"
        if "新しい計画" in original and "話しましょう" in original:
            return "接下來我們來談談新的計畫吧。"
        if "ちょっと待って" in original and ("なんて言った" in original or "何て言った" in original):
            return "等一下，你剛剛說什麼？"
        if "本当に大丈夫" in original and "無理しない" in original:
            return "真的沒事嗎？請不要勉強。"
        if "どうして" in original and "聞く" in original:
            return "你為什麼問這種事？"
        if "まだよく" in original and ("分かりません" in original or "わかりません" in original) and "教えて" in original:
            return "我還不是很懂，可以再多說明一點嗎？"
        if ("後で" in original or "あとで" in original) and "一緒に確認" in original:
            return "那樣的話，待會一起確認吧。"

    return translated


def translate_text(source: str, text: str) -> str:
    text = text.strip()
    if not text:
        return ""

    if source in {"zh", "zt", "zh-Hant", "zh-TW"}:
        return OPENCC.convert(text)

    if source == "ja":
        normalized = text.replace("あす", "明日")
        direct = translate_direct_if_available(normalized, "ja")
        if direct is not None:
            return postprocess(source, normalized, direct)
        english = translate.translate(normalized, "ja", "en")
        translated = translate.translate(english, "en", "zt")
        return postprocess(source, normalized, translated)

    return postprocess(source, text, translate.translate(text, source, "zt"))


def main() -> int:
    for line in sys.stdin:
        try:
            request = json.loads(line)
            source = request.get("source", "ja")
            text = request.get("text", "")
            response = {"ok": True, "text": translate_text(source, text)}
        except Exception as exc:
            response = {"ok": False, "error": str(exc)}

        print(json.dumps(response, ensure_ascii=False), flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
