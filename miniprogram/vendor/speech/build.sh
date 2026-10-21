#!/bin/sh
set -eu
cd "$(dirname "$0")"
root="$(git rev-parse --show-toplevel)"
clang="${WASM_CLANG:-/opt/homebrew/opt/llvm@16/bin/clang}"
"$clang" --target=wasm32 -std=c11 -O2 -DNDEBUG -ffreestanding -fno-builtin -nostdlib \
  -I freestanding -I "$root/third_party/libfvad/src" \
  speech.c "$root"/third_party/libfvad/src/signal_processing/*.c "$root"/third_party/libfvad/src/vad/*.c \
  -Wl,--no-entry -Wl,--export=reset -Wl,--export=input_ptr -Wl,--export=decode \
  -Wl,--export=decisions_ptr -Wl,--export=decision_count -Wl,--export=decoded_samples \
  -Wl,--initial-memory=262144 -Wl,--max-memory=262144 -Wl,--strip-all -o speech.wasm
shasum -a 256 speech.wasm
