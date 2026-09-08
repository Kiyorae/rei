#ifndef REI_SILK_H
#define REI_SILK_H

#include <stddef.h>
#include <stdint.h>

// Each decoder owns a SILK SDK state. Decoded frames are mono PCM at 24 kHz.
void *rei_silk_decoder_create(void);
void rei_silk_decoder_destroy(void *decoder);
int rei_silk_decode_frame(void *decoder, const uint8_t *packet, size_t length,
                          int16_t *samples, int16_t *sample_count, int *has_more_frames);

#endif
