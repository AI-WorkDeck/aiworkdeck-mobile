#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "fvad.h"

/* Host regression for the exact source linked by Android, Harmony and WASM. */
int main(int argc, char **argv) {
    assert(argc == 2);
    int rate = atoi(argv[1]);
    Fvad *vad = fvad_new();
    assert(vad != NULL);
    assert(fvad_set_sample_rate(vad, 44100) == -1);
    assert(fvad_set_mode(vad, 4) == -1);
    assert(fvad_set_sample_rate(vad, rate) == 0);
    assert(fvad_set_mode(vad, 2) == 0);
    int16_t frame[960] = {0};
    size_t length = (size_t)rate / 50;
    assert(fvad_process(vad, frame, length - 1) == -1);
    /* Five real minutes of silence, without advancing an artificial wall clock. */
    for (int i = 0; i < 15000; ++i) assert(fvad_process(vad, frame, length) == 0);
    fvad_reset(vad);
    assert(fvad_set_sample_rate(vad, rate) == 0);
    assert(fvad_set_mode(vad, 2) == 0);
    int speech = 0, total = 0;
    while (fread(frame, sizeof(int16_t), length, stdin) == length) {
        int result = fvad_process(vad, frame, length);
        assert(result == 0 || result == 1);
        speech += result;
        ++total;
    }
    fvad_free(vad);
    printf("%d/%d\n", speech, total);
    return 0;
}
