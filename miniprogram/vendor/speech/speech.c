/* Local MP3 decoder and WebRTC VAD. No allocation, network, or host imports. */
#define MINIMP3_IMPLEMENTATION
#define MINIMP3_NO_SIMD
#define MINIMP3_ONLY_MP3
#include "minimp3.h"
#include "vad/vad_core.h"
static mp3dec_t decoder;
static VadInstT vad;
static unsigned char input[16384];
static mp3d_sample_t pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
static int16_t frame[160];
static unsigned char decisions[16];
static int fill, count, valid;
void *memset(void *dst, int c, size_t n) { unsigned char *d=dst; while(n--) *d++=(unsigned char)c; return dst; }
void *memcpy(void *dst, const void *src, size_t n) { unsigned char *d=dst; const unsigned char *s=src; while(n--) *d++=*s++; return dst; }
void *memmove(void *dst, const void *src, size_t n) { unsigned char *d=dst; const unsigned char *s=src; if(d<s) return memcpy(dst,src,n); while(n) { --n; d[n]=s[n]; } return dst; }
void reset(void) { mp3dec_init(&decoder); WebRtcVad_InitCore(&vad); WebRtcVad_set_mode_core(&vad, 2); fill=count=valid=0; }
unsigned char *input_ptr(void) { return input; }
unsigned char *decisions_ptr(void) { return decisions; }
int decision_count(void) { return count; }
int decoded_samples(void) { return valid; }
int decode(int length) {
  mp3dec_frame_info_t info;
  count=valid=0;
  if(length<0 || length>sizeof(input)) return -1;
  int samples=mp3dec_decode_frame(&decoder,input,length,pcm,&info);
  if(samples>0) {
    if(info.hz!=16000 || info.channels!=1) return -1;
    valid=samples;
    for(int i=0;i<samples;i++) {
      frame[fill++]=pcm[i];
      if(fill==160) {
        decisions[count++]=WebRtcVad_CalcVad16khz(&vad,frame,160)>0;
        fill=0;
      }
    }
  }
  return info.frame_bytes;
}
