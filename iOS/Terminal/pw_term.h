#ifndef PW_TERM_H
#define PW_TERM_H
#include <stdint.h>
#include <stddef.h>

/// One rendered cell. Colors are 0xRRGGBB; PW_DEFAULT means "use the theme's".
#define PW_DEFAULT 0xFF000000u
#define PW_BOLD 1u
#define PW_ITALIC 2u
#define PW_UNDERLINE 4u
#define PW_INVERSE 8u
#define PW_FAINT 16u
#define PW_STRIKE 32u

typedef struct {
    uint32_t cp;      // first codepoint (0 = empty)
    uint32_t fg;
    uint32_t bg;
    uint32_t flags;
} pw_cell;

typedef struct {
    uint16_t cols, rows;
    int16_t cursor_x, cursor_y; // -1 when hidden
} pw_frame;

void *pwt_new(uint16_t cols, uint16_t rows);
void pwt_free(void *t);
void pwt_write(void *t, const uint8_t *data, size_t len);
void pwt_resize(void *t, uint16_t cols, uint16_t rows);
void pwt_reset(void *t);
/// Fills `cells` (row-major, cols*rows, capacity `cap`). Returns the frame size.
pw_frame pwt_render(void *t, pw_cell *cells, size_t cap);
#endif
