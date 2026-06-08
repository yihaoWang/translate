# Mac Live Translator

Mac Live Translator 是一個原生 macOS 即時字幕工具。它使用透明浮動字幕框顯示系統聲音的原文與繁體中文翻譯，直接透過 ScreenCaptureKit 擷取 macOS 系統輸出音訊，不需要 BlackHole 或 Loopback。

預設可使用本機 `whisper-cli` 與 Whisper 模型做語音辨識；也可以在設定面板切換成 OpenAI Cloud transcription。每次開始收音時，app 也會同步保存完整 session 的 WAV 錄音檔。

## 功能

- 直接擷取 Mac 系統輸出音訊，適合 YouTube、Chrome、影片播放器、會議音訊等場景。
- 浮動字幕框顯示最新原文與繁體中文翻譯。
- 支援本機 Whisper 辨識與 OpenAI Cloud 辨識。
- 支援語音語言自動偵測，或手動指定英文、日文、韓文、中文、西文、法文、德文。
- 翻譯可開關；關閉時只顯示原文。
- 日文與英文會優先嘗試本機直翻到繁體中文。
- 支援速度 / 準確模式、停頓斷句、最短 / 最長語句長度、換人斷點等字幕切分設定。
- 設定會保存在本機；OpenAI API key 會存到 macOS Keychain。
- 每次收音會保存完整 WAV 錄音檔。

## 需求

- macOS 13 或更新版本。
- Xcode Command Line Tools。
- 螢幕錄製權限，供 ScreenCaptureKit 擷取系統輸出音訊。
- 本機 Whisper 模式需要 Homebrew 安裝的 `whisper-cli`：

```sh
brew install whisper-cpp
```

- 本機 Whisper 模式需要 Whisper 模型檔，例如：

```text
~/.whisper-models/ggml-small.bin
```

- OpenAI Cloud 模式需要 OpenAI API key，可在設定面板輸入。

## 執行

開發模式：

```sh
swift run
```

打包成 macOS app 後啟動：

```sh
chmod +x scripts/package-app.sh
scripts/package-app.sh
open .build/MacLiveTranslator.app
```

第一次啟動時，macOS 可能會要求螢幕錄製權限。請到「系統設定 > 隱私權與安全性 > 螢幕錄製」允許 MacLiveTranslator，然後重新啟動 app。

## 使用方式

1. 開啟 app 後，浮動字幕框會出現在畫面下方。
2. 按字幕框上的播放按鈕開始擷取系統輸出音訊。
3. 到 Settings 調整 ASR 引擎、語音語言、翻譯開關與斷句參數。
4. 按停止按鈕結束收音；錄音檔會自動收尾成可播放 WAV。

## 語音辨識

設定面板可選擇兩種 ASR 引擎：

- `Local Whisper`：使用 `/opt/homebrew/bin/whisper-cli` 與 `~/.whisper-models/` 裡的模型檔，音訊辨識留在本機。
- `OpenAI Cloud`：使用 OpenAI `/v1/audio/transcriptions`，預設模型是 `gpt-4o-mini-transcribe`，需要輸入 OpenAI API key。

## 翻譯

字幕框第一行是辨識出的原文，第二行是繁體中文翻譯。

翻譯流程會優先使用本機直翻能力：

- 日文會先嘗試 Apple Translation 的已安裝日文到繁中語言包，再嘗試 Argos 已安裝的日文到中文 / 繁中模型。
- 英文會走英文到繁中翻譯。
- 中文原文會用 OpenCC 轉繁體。
- 如果本機沒有直接翻譯能力，會使用可用的 Argos fallback 路徑。

若在設定面板選「只顯示原文」，app 會跳過翻譯流程，只跑語音辨識。

## 錄音保存

每次按「開始」都會建立一個完整 session 的 WAV 錄音檔，停止時自動收尾成可播放檔案。

錄音儲存位置：

```text
~/Documents/MacLiveTranslator Recordings/
```

設定面板會顯示最新錄音檔路徑。檔名包含時間戳與短 UUID，避免連續開始錄音時覆寫舊檔。

## 目前限制

- 目前擷取整個系統輸出音訊；Chrome-only 或指定 app 篩選可在後續版本加入。
- 字幕延遲取決於語音切分設定、Whisper 模型大小與翻譯耗時。
- 日文到繁中與英文到繁中路徑已優先支援；韓文、西文、法文、德文到繁中需要安裝對應的 Argos 離線翻譯模型。
