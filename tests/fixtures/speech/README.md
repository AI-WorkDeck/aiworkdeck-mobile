Synthetic local test material, generated 2026-10-21. No user audio.

- voice.mp3: macOS `say -v Samantha` reading “This is a synthetic voice recording for testing. Please continue taking notes and remember to save your recording.”, converted to 16 kHz mono MP3 / 48 kbps with FFmpeg.
- silence.mp3: six seconds of FFmpeg `anullsrc=r=16000:cl=mono`, same encoding.
- noise.mp3: six seconds of FFmpeg `anoisesrc=color=white:sample_rate=16000:amplitude=0.2:seed=123`, same encoding.
- silence-long.mp3.gz: 310 seconds of the same silent MP3, gzip-compressed to keep the repository fixture small; tests inflate it and feed the shipped decoder/VAD. It covers the actual five-minute threshold without mocking the classifier.
