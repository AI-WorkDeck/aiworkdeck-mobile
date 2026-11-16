# Local MP3 voice-activity detector

This module preserves RecorderManager's 16 kHz / mono / 48 kbps MP3 recording. Only the frame callback bytes are decoded locally. The archived file, its bytes, upload flow and ten-minute segment limit are unchanged. No audio is sent to a voice service or saved a second time.

Sources:

- `minimp3.h`: https://github.com/lieff/minimp3 at `ea99364f61c14656440e8d77e9c233ccf3124633`; CC0, full text in `MINIMP3-LICENSE` (distributed as the byte-identical `MINIMP3-LICENSE.md`).
- WebRTC VAD via libfvad: repository root `third_party/libfvad`, pinned commit `532ab666c20d3cfda38bca63abbb0f152706c369`; BSD notice, patent grant and authors are preserved in `LIBFVAD-LICENSE`, `LIBFVAD-PATENTS` and `LIBFVAD-AUTHORS`; their byte-identical `.md` copies are distributed in the mini-program package. Mode 2; 16 kHz PCM, 10 ms classified frames.
- `speech.c` is this project's bounded wrapper: one decoder and VAD per WASM instance, 16 KiB compressed input buffer, 256 KiB fixed memory, no host imports, no allocator. The freestanding headers implement only the C declarations/macros used by these sources.

Rebuild from the repository root with `miniprogram/vendor/speech/build.sh`. Requires LLVM's wasm target and wasm-ld; tested with Homebrew LLVM 16 (`WASM_CLANG` can select another executable). Source-only C/header files are build inputs, not JavaScript modules. The mini-program loads the packaged `vendor/speech/speech.wasm` using WXWebAssembly; no network download/eval.

Checked binary SHA-256: `f7d0be192ae300f6a3ab665e8a00c7fee54f2e493260016b5219efe468265393` (LLVM 16).

The classifier is statistical, not speech recognition. Loud noise can be classified as speech and delay a reminder. Missing frames, decode/capability failures and paused time never count as silence; capture and save remain available with an explicit unavailable notice. The fixture tests include synthetic speech, digital silence, and seeded white noise, and deliberately record this conservative noisy-input behavior.

The WeChat compiler excludes extensionless files even when they are explicitly included in `packOptions`. Keep the `.md` notice copies identical to their original files when updating these dependencies. Run `npm run mp:package:check` before upload to compile the actual package and verify all four notices and the WASM bytes. This check uses the existing upload key for the SDK's read-only project configuration lookup; it does not upload a version. An optional output ZIP path may be passed after `--`.
