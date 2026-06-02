# Roadmap

## 1. Faster Caption Dispatch With Speech-Pause Detection

Status: implemented in `LocalWhisperTranslator` with RMS-based speech start/end detection.

Goal: replace fixed-duration audio chunking with speech-pause detection so Japanese speech is sent to Whisper soon after the speaker pauses.

Current behavior:
- Audio is accumulated for a fixed window before Whisper runs.
- This creates avoidable latency even when the speaker has already stopped.

Planned behavior:
- Start buffering when audio energy crosses a speech threshold.
- Continue buffering while speech remains active.
- When silence lasts long enough, treat the utterance as complete and send it to Whisper immediately.
- Force-send long utterances after a maximum duration so long sentences still produce partial captions.
- Drop near-silent segments before Whisper to reduce hallucinated subtitles.

Initial parameters to discuss before implementation:
- Target audio profile: clean dialogue / clean voice.
- Tuning priority: preserve sentence completeness over ultra-low latency.
- `speechThreshold`: default `0.012` RMS, adjustable in Settings.
- `silenceMs`: default `900ms`, adjustable in Settings.
- `minUtteranceMs`: default `900ms`, adjustable in Settings.
- `maxUtteranceMs`: default `8000ms`, adjustable in Settings.
- Default speech language: Japanese (`ja`) for better Whisper accuracy.

Acceptance criteria:
- Captions are dispatched after a natural pause instead of waiting for a full fixed chunk.
- Quiet/no-speech periods do not trigger Whisper.
- Long continuous speech still produces captions within the max utterance window.
- Status text can distinguish listening, recognizing, and translating.
- Processing time per utterance is observable for later tuning.

Risks and tradeoffs:
- Background music or loud effects may trigger false speech.
- Short silence thresholds may split Japanese sentences too aggressively.
- Long silence thresholds reduce fragmentation but increase latency.
- Shorter utterances may reduce translation context and produce less natural Traditional Chinese.

Open questions:
- Should partial captions replace the previous line or append history?
- Should max utterance dispatch overlap the next segment to avoid cutting words?
- What range should Settings sliders expose for threshold, silence duration, min utterance, and max utterance?

## 2. Speed / Accuracy Modes

Status: implemented in Settings as `Fast`, `Balanced`, and `Accurate`. `Fast` is now the default for sub-second caption turnaround after dispatch.

Goal: provide simple presets that tune latency, segmentation, and recommended Whisper model choice.

Implemented presets:
- `Fast`: short dispatch windows, aggressive pause detection, recommended `ggml-base.bin`.
- `Balanced`: moderate pause detection, around 3-second fallback windows, recommended `ggml-small.bin`.
- `Accurate`: longer phrase windows, around 5-second fallback windows, recommended `ggml-small.bin` or `ggml-medium.bin`.

Settings behavior:
- Presets should set sensible defaults for threshold, pause duration, min utterance, max utterance, and recommended model.
- Advanced users should still be able to override individual values.
- The active mode should be visible in Settings.

## 3. Silence Filtering Before Whisper

Status: implemented with RMS filtering before Whisper dispatch.

Goal: avoid running Whisper and translation on no-speech audio.

Planned behavior:
- Measure audio energy before dispatching an utterance.
- Drop near-silent segments before invoking Whisper.
- Keep a short status indication when silence is being ignored.

Expected benefit:
- Fewer wasted Whisper runs.
- Fewer hallucinated captions during quiet sections.
- Lower CPU/GPU usage and better perceived responsiveness.

## 3.1 Speaker-Change Caption Breaks

Status: implemented as a lightweight realtime heuristic in `LocalWhisperTranslator`.

Goal: split dialogue more like real conversation by dispatching the current caption when the app detects that the active voice likely changed.

Current behavior:
- The app still uses pause detection as the primary boundary.
- While speech is active, it also extracts a short-window voice feature from system audio.
- If the voice feature changes enough for two consecutive speech chunks, and the current utterance is long enough, the current caption is dispatched before appending the new speaker's audio.

Settings:
- `換人斷點`: enable or disable speaker-change splitting.
- `換人敏感度`: lower values split more aggressively; higher values are more conservative.
- `最短換人間隔`: prevents rapid false speaker flips during a single sentence.

Tradeoff:
- This is not full speaker diarization and does not identify stable `Speaker A/B` labels.
- It is designed to be fast enough for live captions, so music, overlapping voices, or dramatic changes in volume can still create false splits.

## 4. Translation Pipeline Optimization

Status: partially implemented. Repeated translation caching is active, Argos now runs as a persistent helper process, and the app now prefers installed direct Japanese -> Traditional Chinese/Chinese translation paths before falling back to Japanese -> English -> Traditional Chinese.

Current behavior:
- Japanese speech is transcribed by Whisper.
- Translation can be disabled from Settings. In original-only mode, the app skips Apple/Argos translation and only shows Whisper transcription.
- Japanese text first tries Apple Translation's installed Japanese -> Traditional Chinese language pack.
- If Apple local translation is unavailable, Argos tries any installed direct Japanese -> Chinese/Traditional Chinese package.
- If no direct path is installed, Argos falls back to `Japanese -> English -> Traditional Chinese`.

Planned improvements:
- Cache repeated translations by normalized source text.
- Skip translation when the source text is empty or filtered as noise.
- Investigate and install a high-quality local Japanese -> Chinese / Japanese -> Traditional Chinese model.
- Replace the two-step Argos fallback once a direct local model is verified to be faster and more readable.

Tradeoff:
- The two-step path is available today but slower and can lose nuance.
- A direct Japanese -> Traditional Chinese model may improve speed and fluency, but needs separate runtime/model evaluation.

## 5. Whisper Model Selection

Status: implemented for local files detected under `~/.whisper-models`.

Goal: let the app switch between local Whisper models instead of hard-coding `ggml-small.bin`.

Recommended model options:
- `ggml-tiny.bin`: fastest, lowest accuracy.
- `ggml-base.bin`: better speed/accuracy balance.
- `ggml-small.bin`: current default, better accuracy but slower.
- `ggml-medium.bin`: higher accuracy, likely too slow for real-time unless hardware permits.

Settings behavior:
- Provide a model picker or path selector.
- Detect common model paths under `~/.whisper-models`.
- Warn when a selected model does not exist.
- Make mode presets recommend a model but not forcibly override the user's chosen path without confirmation.

## 5.1 Cloud ASR Engine

Status: implemented as an optional OpenAI Cloud transcription engine.

Goal: provide a higher-accuracy alternative when local Whisper is too inaccurate for noisy video/audio.

Current behavior:
- Settings exposes `ASR ENGINE`: `Local Whisper` or `OpenAI Cloud`.
- `OpenAI Cloud` sends each utterance WAV chunk to `/v1/audio/transcriptions`.
- Default cloud model is `gpt-4o-mini-transcribe`; `gpt-4o-transcribe` is also selectable.
- The app keeps translation as a separate setting, so cloud ASR can be used with bilingual captions or original-only captions.

Verification note:
- Build/package passed locally.
- A real cloud request requires `OPENAI_API_KEY`; the current shell did not have that environment variable, so live API validation remains pending.

## 6. Verification Standard

Status: implemented as visible per-utterance metrics in Settings. A repeatable local Japanese TTS regression set is now used for tuning.

Latest local evaluation:
- Sentence set: average `723ms` end-to-end after warm-up, readable Traditional Chinese output.
- Colloquial set: average `700ms` end-to-end after warm-up, common short Japanese phrases corrected into natural Traditional Chinese.
- Continuous five-sentence audio: VAD produces five full sentence segments instead of word fragments.

Every speed-related change should be tested against the same Japanese audio sample.

Metrics:
- First-caption latency.
- Per-utterance Whisper time.
- Per-utterance translation time.
- Total speech-end-to-caption time.
- Translation readability.
- Missing speech rate.
- Over-fragmentation / sentence chopping.
- Hallucinated captions during silence.

Acceptance target:
- Faster first visible caption without making Japanese sentence boundaries unusably fragmented.
- No Whisper/Argos runs for clear silence.
- Japanese -> Traditional Chinese output remains readable enough for video watching.
