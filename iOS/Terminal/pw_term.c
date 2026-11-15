#include "pw_term.h"
#include <ghostty/vt.h>
#include <string.h>
#include <stdlib.h>

typedef struct { GhosttyTerminal term; GhosttyRenderState rs; GhosttyRenderStateRowIterator it; GhosttyRenderStateRowCells cells; } PW;

void *pwt_new(uint16_t cols, uint16_t rows) {
    PW *p = calloc(1, sizeof(PW));
    if (ghostty_terminal_new(NULL, &p->term, cols ? cols : 80, rows ? rows : 24) != GHOSTTY_SUCCESS) { free(p); return NULL; }
    size_t bytes = 4u << 20, lines = 5000;
    ghostty_terminal_set(p->term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes);
    ghostty_terminal_set(p->term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines);
    ghostty_render_state_new(NULL, &p->rs);
    ghostty_render_state_row_iterator_new(NULL, &p->it);
    ghostty_render_state_row_cells_new(NULL, &p->cells);
    return p;
}

void pwt_free(void *t) {
    PW *p = t; if (!p) return;
    ghostty_render_state_row_cells_free(p->cells);
    ghostty_render_state_row_iterator_free(p->it);
    ghostty_render_state_free(p->rs);
    ghostty_terminal_free(p->term);
    free(p);
}

void pwt_write(void *t, const uint8_t *data, size_t len) { PW *p = t; if (p && len) ghostty_terminal_vt_write(p->term, data, len); }
void pwt_resize(void *t, uint16_t cols, uint16_t rows) { PW *p = t; if (p && cols && rows) ghostty_terminal_resize(p->term, cols, rows, 8, 16); }
void pwt_reset(void *t) { PW *p = t; if (p) ghostty_terminal_reset(p->term); }

static uint32_t rgb(GhosttyColorRgb c) { return ((uint32_t)c.r << 16) | ((uint32_t)c.g << 8) | c.b; }

pw_frame pwt_render(void *t, pw_cell *out, size_t cap) {
    pw_frame f = {0, 0, -1, -1};
    PW *p = t; if (!p) return f;
    if (ghostty_render_state_update(p->rs, p->term) != GHOSTTY_SUCCESS) return f;
    uint16_t cols = 0, rows = 0;
    ghostty_render_state_get(p->rs, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
    ghostty_render_state_get(p->rs, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
    f.cols = cols; f.rows = rows;
    bool vis = false, has = false;
    ghostty_render_state_get(p->rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &vis);
    ghostty_render_state_get(p->rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &has);
    if (vis && has) {
        uint16_t cx = 0, cy = 0;
        ghostty_render_state_get(p->rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx);
        ghostty_render_state_get(p->rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy);
        f.cursor_x = cx; f.cursor_y = cy;
    }
    if ((size_t)cols * rows > cap) return f;
    memset(out, 0, sizeof(pw_cell) * cols * rows);
    ghostty_render_state_get(p->rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &p->it);
    uint16_t y = 0;
    while (ghostty_render_state_row_iterator_next(p->it) && y < rows) {
        ghostty_render_state_row_get(p->it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &p->cells);
        uint16_t x = 0;
        while (ghostty_render_state_row_cells_next(p->cells) && x < cols) {
            pw_cell *c = &out[(size_t)y * cols + x];
            c->fg = PW_DEFAULT; c->bg = PW_DEFAULT;
            uint32_t glen = 0;
            ghostty_render_state_row_cells_get(p->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
            if (glen > 0) {
                uint32_t cps[4];
                GhosttyCodepointBuffer buf = { .ptr = cps, .cap = 4 };
                ghostty_render_state_row_cells_get(p->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &buf);
                c->cp = cps[0];
            }
            GhosttyColorRgb col;
            if (ghostty_render_state_row_cells_get(p->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &col) == GHOSTTY_SUCCESS) c->fg = rgb(col);
            if (ghostty_render_state_row_cells_get(p->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &col) == GHOSTTY_SUCCESS) c->bg = rgb(col);
            GhosttyStyle st;
            if (ghostty_render_state_row_cells_get(p->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &st) == GHOSTTY_SUCCESS) {
                if (st.flags & GHOSTTY_STYLE_FLAG_BOLD) c->flags |= PW_BOLD;
                if (st.flags & GHOSTTY_STYLE_FLAG_ITALIC) c->flags |= PW_ITALIC;
                if (st.flags & GHOSTTY_STYLE_FLAG_INVERSE) c->flags |= PW_INVERSE;
                if (st.flags & GHOSTTY_STYLE_FLAG_FAINT) c->flags |= PW_FAINT;
                if (st.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH) c->flags |= PW_STRIKE;
                if (GHOSTTY_STYLE_UNDERLINE(st)) c->flags |= PW_UNDERLINE;
            }
            x++;
        }
        y++;
    }
    ghostty_render_state_clean(p->rs);
    return f;
}
