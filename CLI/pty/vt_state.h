#ifndef PITWALL_VT_STATE_H
#define PITWALL_VT_STATE_H
#include <stddef.h>
#include <stdint.h>

/// A headless terminal (libghostty-vt) mirroring a session's screen so a
/// re-attaching client can be given an exact snapshot.
void *pw_vt_new(uint16_t cols, uint16_t rows);
void pw_vt_free(void *vt);
void pw_vt_write(void *vt, const uint8_t *data, size_t len);
void pw_vt_resize(void *vt, uint16_t cols, uint16_t rows);
/// Formats the terminal (screen + scrollback). vt != 0: VT sequences that
/// recreate it; vt == 0: plain text. Free the result with pw_vt_free_buf.
uint8_t *pw_vt_format(void *vt, int as_vt, size_t *out_len);
void pw_vt_free_buf(uint8_t *buf, size_t len);
#endif
