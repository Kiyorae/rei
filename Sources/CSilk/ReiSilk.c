#include "ReiSilk.h"
#include "SKP_Silk_SDK_API.h"
#include <stdlib.h>

void *rei_silk_decoder_create(void) {
    SKP_int32 size = 0;
    if (SKP_Silk_SDK_Get_Decoder_Size(&size) != 0 || size <= 0) return NULL;
    void *state = calloc(1, (size_t)size);
    if (state != NULL && SKP_Silk_SDK_InitDecoder(state) != 0) {
        free(state);
        return NULL;
    }
    return state;
}

void rei_silk_decoder_destroy(void *decoder) {
    free(decoder);
}

int rei_silk_decode_frame(void *decoder, const uint8_t *packet, size_t length,
                          int16_t *samples, int16_t *sample_count, int *has_more_frames) {
    if (decoder == NULL || packet == NULL || samples == NULL || sample_count == NULL ||
        has_more_frames == NULL || length > 1024) return -1;
    SKP_SILK_SDK_DecControlStruct control = {0};
    control.API_sampleRate = 24000;
    *sample_count = 480;
    int result = SKP_Silk_SDK_Decode(decoder, &control, length == 0,
                                   packet, (int)length, samples, sample_count);
    *has_more_frames = control.moreInternalDecoderFrames;
    return result;
}
