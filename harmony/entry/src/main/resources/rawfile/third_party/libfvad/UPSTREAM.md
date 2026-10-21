# libfvad provenance

Source: https://github.com/dpirch/libfvad
Commit: 532ab666c20d3cfda38bca63abbb0f152706c369
License: BSD-3-Clause; retain LICENSE, PATENTS and AUTHORS in distributions.

Unmodified include/, src/, tests/ and CMakeLists.txt are vendored for offline voice activity detection in Android, Harmony and the mini program WASM build. This is a speech activity classifier, not a volume threshold or speech transcription service. It never sends audio to a server. Supported input rates: 8, 16, 32 and 48 kHz; frame sizes 10, 20 or 30 ms.

Native clients link the upstream static CMake target `fvad`; mini program builds the same source into WASM. The reminder state machine only counts successfully classified audio, resets on gaps, and never stops a recording automatically.
