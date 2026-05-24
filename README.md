# Mac Live Translator

一個原生 macOS 即時字幕工具。它以透明浮動字幕框顯示雙語字幕，讀取目前的預設音訊輸入裝置，將聲音切成短段 WAV，並用本機 `whisper-cli` 與 Whisper 模型處理，不會連到 OpenAI。

## 需求

- macOS 13 或更新版本
- Xcode Command Line Tools
- Homebrew 安裝的 `whisper-cli`
- Whisper 模型檔，例如 `/Users/yihao.wang/.whisper-models/ggml-small.bin`
- 如果要翻譯「Mac 系統聲音」，建議安裝 BlackHole 2ch 或 Loopback，將系統輸出路由成輸入裝置

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

第一次啟動錄音時，macOS 會要求麥克風權限。請允許 Terminal 或執行此 app 的程式使用麥克風。

## 本地模型模式

目前 app 使用本機 Whisper：

- 字幕框第一行是 Whisper 偵測/轉錄出的原文。
- 字幕框第二行是繁體中文翻譯。
- 語音語言可以選「自動」或指定英文、日文、韓文、中文、西文、法文、德文；指定語言會提升 Whisper 辨識準確度。
- 繁中翻譯使用本機 Argos Translate。日文會走 Japanese → English → Chinese (traditional)，英文會走 English → Chinese (traditional)，中文原文會用 OpenCC 轉繁中。

## 翻譯 Mac 系統聲音

macOS 一般 app 不能直接偷聽所有系統輸出音訊。最穩定的做法是用虛擬音訊裝置：

1. 安裝 BlackHole 2ch。
2. 在「音訊 MIDI 設定」建立 Multi-Output Device，勾選你的喇叭或耳機，以及 BlackHole 2ch。
3. 在「系統設定 > 聲音 > 輸出」選擇剛建立的 Multi-Output Device。
4. 在「系統設定 > 聲音 > 輸入」選擇 BlackHole 2ch。
5. 啟動本工具並按「開始」。

如果只是要翻譯麥克風或會議輸入，直接把系統輸入裝置設成對應的麥克風即可。

## 目前限制

- 目前使用預設輸入裝置；切換輸入裝置請到 macOS 系統設定。
- 每 5 秒處理一段音訊，因此字幕會有短延遲。
- 目前已安裝並驗證日文 → 繁中與英文 → 繁中翻譯。韓文、西文、法文、德文 → 繁中需要再安裝對應的 Argos 離線翻譯模型。
