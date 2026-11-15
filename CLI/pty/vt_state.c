#include "vt_state.h"
#include <ghostty/vt.h>
#include <stdint.h>

void *pw_vt_new(uint16_t cols, uint16_t rows) {
    GhosttyTerminal t = NULL;
    if (ghostty_terminal_new(NULL, &t, cols ? cols : 80, rows ? rows : 24) != GHOSTTY_SUCCESS) return NULL;
    size_t bytes = 32u << 20;   // generous scrollback; default is tiny
    size_t lines = 20000;
    ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes);
    ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines);
    return t;
}

void pw_vt_free(void *vt) { if (vt) ghostty_terminal_free((GhosttyTerminal)vt); }

void pw_vt_write(void *vt, const uint8_t *data, size_t len) {
    if (vt && len) ghostty_terminal_vt_write((GhosttyTerminal)vt, data, len);
}

void pw_vt_resize(void *vt, uint16_t cols, uint16_t rows) {
    if (vt && cols && rows) ghostty_terminal_resize((GhosttyTerminal)vt, cols, rows, 8, 16);
}

uint8_t *pw_vt_format(void *vt, int as_vt, size_t *out_len) {
    *out_len = 0;
    if (!vt) return NULL;
    GhosttyFormatter f = NULL;
    if (ghostty_formatter_terminal_new(NULL, &f, (GhosttyTerminal)vt) != GHOSTTY_SUCCESS) return NULL;
    GhosttyFormatterFormat emit = as_vt ? GHOSTTY_FORMATTER_FORMAT_VT : GHOSTTY_FORMATTER_FORMAT_PLAIN;
    ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
    if (as_vt) {
        // Everything except the palette, which would override the app's theme.
        GhosttyFormatterExtras ex = GHOSTTY_FORMATTER_EXTRAS_ALL & ~GHOSTTY_FORMATTER_EXTRA_PALETTE;
        ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_EXTRAS, &ex);
        // Keep trailing blank rows so the screen part fills every row and the
        // restored cursor position lines up with the original.
        bool trim = false;
        ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
    } else {
        bool unwrap = true;
        ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap);
    }
    uint8_t *out = NULL;
    size_t len = 0;
    GhosttyResult r = ghostty_formatter_format_alloc(f, NULL, &out, &len);
    ghostty_formatter_free(f);
    if (r != GHOSTTY_SUCCESS) return NULL;
    *out_len = len;
    return out;
}

void pw_vt_free_buf(uint8_t *buf, size_t len) { if (buf) ghostty_free(NULL, buf, len); }
