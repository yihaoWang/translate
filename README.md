# Mac Live Translator

一個原生 macOS 即時字幕工具。它以透明浮動字幕框顯示雙語字幕，直接擷取 macOS 系統輸出音訊，將聲音切成短段 WAV，並用本機 `whisper-cli` 與 Whisper 模型處理，不會連到 OpenAI。

## 需求

- macOS 13 或更新版本
- Xcode Command Line Tools
- Homebrew 安裝的 `whisper-cli`
- Whisper 模型檔，例如 `/Users/yihao.wang/.whisper-models/ggml-small.bin`
- 螢幕錄製權限，供 ScreenCaptureKit 擷取系統輸出音訊

## 執行

```sh
swift run
```

如果想用真正的 macOS app 視窗啟動：

```sh
chmod +x scripts/package-app.sh
scripts/package-app.sh
open .build/MacLiveTranslator.app
```

第一次啟動時，macOS 可能會要求螢幕錄製權限。請到「系統設定 > 隱私權與安全性 > 螢幕錄製」允許 MacLiveTranslator，然後重新啟動 app。

## 本地模型模式

目前 app 使用本機 Whisper：

- 字幕框第一行是 Whisper 偵測/轉錄出的原文。
- 字幕框第二行是繁體中文翻譯。
- 語音語言可以選「自動」或指定英文、日文、韓文、中文、西文、法文、德文；指定語言會提升 Whisper 辨識準確度。
- 繁中翻譯使用本機 Argos Translate。日文會走 Japanese → English → Chinese (traditional)，英文會走 English → Chinese (traditional)，中文原文會用 OpenCC 轉繁中。

## 翻譯 Mac 系統聲音

本工具現在使用 ScreenCaptureKit 直接擷取系統輸出音訊，不需要 BlackHole 或 Loopback。按「開始」後，Chrome、YouTube、影片播放器等輸出到 Mac 的聲音會進入本機 Whisper。

## 目前限制

- 目前擷取整個系統輸出音訊；Chrome-only 篩選可在後續版本加入。
- 每 5 秒處理一段音訊，因此字幕會有短延遲。
- 目前已安裝並驗證日文 → 繁中與英文 → 繁中翻譯。韓文、西文、法文、德文 → 繁中需要再安裝對應的 Argos 離線翻譯模型。
