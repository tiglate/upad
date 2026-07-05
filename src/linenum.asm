; linenum.asm -- the line-numbers gutter (View > Line Numbers, on by
; default) and its View menu toggle.
;
; GtkTextView has no built-in "show line numbers" property (that's a
; GtkSourceView feature, a separate library this project deliberately
; doesn't depend on -- see CLAUDE.md). Instead, GTK4 exposes
; gtk_text_view_set_gutter(text_view, GTK_TEXT_WINDOW_LEFT, widget): any
; widget dropped in there is automatically kept aligned with the text
; view's own vertical scrolling. We use a plain GtkDrawingArea and do the
; drawing ourselves, once per visible line:
;
;   1. gtk_text_view_get_visible_rect finds which vertical slice of the
;      BUFFER is currently on screen.
;   2. gtk_text_view_get_line_at_y + a gtk_text_iter_forward_line loop
;      walks every buffer line that overlaps that slice (using
;      gtk_text_view_get_line_yrange to know each line's own vertical
;      span, and to notice once we've walked past the visible area).
;   3. gtk_text_view_buffer_to_window_coords converts each line's
;      buffer-coordinate top into the gutter's own drawing coordinates.
;   4. A small PangoLayout (matching the text view's own font, via
;      gtk_widget_create_pango_layout) is set to that line's 1-based
;      number and drawn right-aligned via pango_cairo_show_layout, which
;      -- unlike printing.asm's pango_cairo_show_layout_line -- positions
;      from the layout's own TOP-left at the current point, not its
;      baseline, so no extra vertical math is needed.
;
; A single buffer line that word-wraps into several visual rows still
; gets exactly one number, at the top of the wrapped block -- this falls
; out of the algorithm above for free, since get_line_yrange reports one
; buffer line's FULL vertical span (all of its wrapped rows) as a single
; range, matching how real editors number wrapped lines.
;
; The gutter's width tracks the document's actual line count: it starts
; at one digit wide and grows/shrinks as needed, recomputed whenever
; Format > Font changes the font (see refresh_line_number_gutter_width)
; or the number of DIGITS in the line count changes (on_linenum_buffer_changed
; below). That second check runs on every edit but is O(1) regardless of
; document size -- GtkTextBuffer tracks its own line count incrementally,
; and counting a 32-bit integer's decimal digits is at most ~10 loop
; iterations -- so a 10,000,000-line document costs the same few
; instructions per keystroke as a 100-line one. The comparatively
; expensive part (laying out a sample string and resizing the widget)
; only actually runs on the rare edits that push the digit count itself
; across a power-of-ten boundary, never on every edit.

%include "consts.inc"    ; GTK_TEXT_WINDOW_LEFT, GTK_TEXT_ITER_SIZE, G_CONNECT_DEFAULT, TRUE, LINE_NUMBER_RIGHT_PAD, LINE_NUMBER_GUTTER_PADDING
%include "callconv.inc"  ; CCALL/ICALL macros
%include "extern.inc"    ; extern declarations for every GTK/Pango/cairo call used below

global setup_line_numbers                ; called once from window.asm, after g_textview/g_scrolled both exist
global refresh_line_number_gutter_width  ; called from on_linenum_buffer_changed below whenever the digit count changes, and from format.asm whenever the font changes
global on_line_numbers_activate          ; the "win.line-numbers" GAction handler (actions.asm)

extern g_textview          ; main.asm -- the gutter is attached to this
extern g_scrolled          ; main.asm -- its vertical GtkAdjustment is one of our redraw triggers
extern g_buffer            ; main.asm -- its "changed" signal is our other redraw trigger
extern itoa_decimal        ; format.asm -- decimal integer-to-string, reused here for each line number
extern toggle_bool_action  ; format.asm -- shared "flip a stateful boolean GSimpleAction" helper

section .rodata
    sig_changed        db "changed", 0        ; GtkTextBuffer's own signal -- content changed, so the line count (and thus the numbers on screen) might have too
    sig_value_changed  db "value-changed", 0  ; GtkAdjustment's signal -- the view scrolled
    sig_adj_changed    db "changed", 0        ; GtkAdjustment's OWN "changed" (a different instance than sig_changed above, despite the identical bytes -- kept as a separate symbol for clarity at each call site) -- its scrollable range changed (font size, word wrap, or a resize), even if the current scroll position didn't

    align 8
    gray_component  dq 0.5    ; line-number text color (0.5, 0.5, 0.5) -- a fixed mid-gray, deliberately not theme-aware (see Known limitations): readable against both a light and a dark background without needing to track Dark Mode state here too

section .bss
    align 8
    g_linenum_gutter      resq 1  ; GtkDrawingArea* (as a plain GtkWidget*) -- the gutter widget itself, also what View > Line Numbers shows/hides
    g_linenum_digit_count resd 1  ; the digit budget last used to size the gutter (0 = "never computed yet", guaranteeing the very first check in on_linenum_buffer_changed always resizes) -- read/written only via 32-bit registers, see that function's comment

section .text

; -------------------------------------------------------------------------
; void on_linenum_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data)
; GtkDrawingAreaDrawFunc -- redraws the whole gutter from scratch every
; time it's called, which is cheap: only the currently-visible lines are
; ever walked, never the whole document.
; -------------------------------------------------------------------------
on_linenum_draw:
    push rbp
    mov  rbp, rsp
    sub  rsp, 208
    ; [rbp-8]   = cr
    ; [rbp-16]  = width (this drawing area's own width, sign-extended)
    ; [rbp-24]  = layout (PangoLayout*, built once via gtk_widget_create_pango_layout, reused per line via set_text)
    ; [rbp-32]  = bottom_y (visible_rect.y + visible_rect.height, buffer coords)
    ; [rbp-40]  = line_number (1-based)
    ; [rbp-48]  = text_width   [rbp-56] = text_height -- out-params for pango_layout_get_pixel_size (text_height never read)
    ; [rbp-64]  = y            [rbp-72] = line_height -- out-params for gtk_text_view_get_line_yrange (line_height never read)
    ; [rbp-80]  = window_x (out-param, never read)   [rbp-88] = window_y (out-param, what we actually want)
    ; [rbp-96]  = line_top (out-param for gtk_text_view_get_line_at_y, never read)
    ; [rbp-112..-97] = numbuf (16 bytes -- itoa_decimal's destination, comfortably fits any 32-bit line number)
    ; [rbp-128..-113] = visible_rect (GdkRectangle: x@-128, y@-124, width@-120, height@-116 -- a tightly-packed 4-int struct, NOT four separate qword slots)
    ; [rbp-208..-129] = iter (GtkTextIter, 80 bytes, GTK_TEXT_ITER_SIZE)
    ;
    ; Every int*/GdkRectangle field a callee below fills is written as a
    ; plain 32-bit int -- only ever read back via a 32-bit register
    ; (zero-extending into the full qword), matching this codebase's usual
    ; discipline for `int`-returning values (see fileio.asm's movsxd
    ; pattern); the qword slots above just give each one its own
    ; comfortably-aligned address; the upper 32 bits are never assumed
    ; meaningful.

    mov  [rbp-8], rsi  ; cr (this callback's own arg2)
    movsxd rax, edx    ; width (arg3)
    mov  [rbp-16], rax

    ; --- black... er, gray text, set once for every number this call draws ---
    mov  rdi, [rbp-8]
    movsd xmm0, [rel gray_component]
    movsd xmm1, [rel gray_component]
    movsd xmm2, [rel gray_component]
    CCALL cairo_set_source_rgb

    ; --- a small reusable layout matching the text view's own font ---------
    mov  rdi, [rel g_textview]
    xor  esi, esi                         ; text = NULL -- pango_layout_set_text fills it in per line, below
    CCALL gtk_widget_create_pango_layout  ; PangoLayout *gtk_widget_create_pango_layout(GtkWidget*, const char*) -- rax = a new layout, ours to free
    mov  [rbp-24], rax

    ; --- which buffer lines are actually on screen right now? --------------
    mov  rdi, [rel g_textview]
    lea  rsi, [rbp-128]                   ; &visible_rect
    CCALL gtk_text_view_get_visible_rect  ; void gtk_text_view_get_visible_rect(GtkTextView*, GdkRectangle*) -- buffer coordinates

    mov  eax, [rbp-124]  ; visible_rect.y
    add  eax, [rbp-116]  ; + visible_rect.height
    movsxd rax, eax
    mov  [rbp-32], rax                         ; bottom_y

    mov  rdi, [rel g_textview]
    lea  rsi, [rbp-208]                ; &iter (out)
    mov  edx, [rbp-124]                ; y = visible_rect.y
    lea  rcx, [rbp-96]                 ; &line_top (out, unused)
    CCALL gtk_text_view_get_line_at_y  ; void gtk_text_view_get_line_at_y(GtkTextView*, GtkTextIter*, int y, int *line_top) -- positions iter at (or just before) the first visible line

.line_loop:
    mov  rdi, [rel g_textview]
    lea  rsi, [rbp-208]                  ; &iter
    lea  rdx, [rbp-64]                   ; &y (out)
    lea  rcx, [rbp-72]                   ; &line_height (out, unused)
    CCALL gtk_text_view_get_line_yrange  ; void gtk_text_view_get_line_yrange(GtkTextView*, const GtkTextIter*, int *y, int *height) -- y = this line's buffer-coordinate top

    mov  eax, [rbp-64]
    movsxd rax, eax
    mov  [rbp-64], rax                          ; y, laundered to a clean qword

    cmp  rax, [rbp-32]                            ; past the visible area yet? (y >= bottom_y)
    jge  .done_drawing

    ; --- this line's buffer-coordinate top -> the gutter's own drawing coordinates ---
    mov  rdi, [rel g_textview]
    mov  esi, GTK_TEXT_WINDOW_LEFT
    xor  edx, edx                                ; buffer_x = 0 (unused -- only the y conversion matters here)
    mov  ecx, [rbp-64]                           ; buffer_y = y
    lea  r8, [rbp-80]                            ; &window_x (out, unused)
    lea  r9, [rbp-88]                            ; &window_y (out) -- what we actually want
    CCALL gtk_text_view_buffer_to_window_coords  ; void gtk_text_view_buffer_to_window_coords(GtkTextView*, GtkTextWindowType, int, int, int*, int*)

    mov  eax, [rbp-88]
    movsxd rax, eax
    mov  [rbp-88], rax                  ; window_y, laundered

    ; --- this line's 1-based number, as text -------------------------------
    lea  rdi, [rbp-208]           ; &iter
    CCALL gtk_text_iter_get_line  ; int gtk_text_iter_get_line(const GtkTextIter*) -- 0-based
    inc  eax                      ; -> 1-based
    mov  [rbp-40], rax

    lea  rdi, [rbp-112]  ; dest = numbuf
    mov  esi, [rbp-40]   ; value = the line number
    ICALL itoa_decimal   ; format.asm -- writes the digits + NUL

    ; --- lay it out and measure it, so it can be right-aligned -------------
    mov  rdi, [rbp-24]   ; layout
    lea  rsi, [rbp-112]  ; numbuf
    mov  edx, -1         ; NUL-terminated
    CCALL pango_layout_set_text

    mov  rdi, [rbp-24]
    lea  rsi, [rbp-48]                 ; &text_width (out)
    lea  rdx, [rbp-56]                 ; &text_height (out, unused)
    CCALL pango_layout_get_pixel_size  ; void pango_layout_get_pixel_size(PangoLayout*, int *width, int *height)

    mov  eax, [rbp-48]
    movsxd rax, eax
    mov  [rbp-48], rax                        ; text_width, laundered

    ; --- draw it, right-aligned with a little breathing room -------------
    mov  rax, [rbp-16]               ; this drawing area's own width
    sub  rax, [rbp-48]               ; - text_width
    sub  rax, LINE_NUMBER_RIGHT_PAD  ; - padding
    cvtsi2sd xmm0, rax               ; x, as a double
    mov  rax, [rbp-88]               ; window_y
    cvtsi2sd xmm1, rax               ; y, as a double -- the layout's own TOP, per pango_cairo_show_layout's contract (see file header)

    mov  rdi, [rbp-8]                     ; cr
    CCALL cairo_move_to

    mov  rdi, [rbp-8]              ; cr
    mov  rsi, [rbp-24]             ; layout
    CCALL pango_cairo_show_layout  ; void pango_cairo_show_layout(cairo_t*, PangoLayout*)

    lea  rdi, [rbp-208]               ; &iter
    CCALL gtk_text_iter_forward_line  ; gboolean gtk_text_iter_forward_line(GtkTextIter*) -- advances to the next line; FALSE if there wasn't one
    test eax, eax
    jnz  .line_loop
    ; else fall through -- no more lines at all, regardless of bottom_y

.done_drawing:
    mov  rdi, [rbp-24]                  ; layout
    CCALL g_object_unref

    leave
    ret

; -------------------------------------------------------------------------
; void refresh_line_number_gutter_width(void)
; Re-measures a string of g_linenum_digit_count '9's (the widest possible
; value for that many digits) in the text view's CURRENT font, and resizes
; the gutter to fit it plus padding. Called whenever that pixel width
; might have changed: the digit count itself did
; (on_linenum_buffer_changed below) or the font did (format.asm).
; -------------------------------------------------------------------------
refresh_line_number_gutter_width:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48
    ; [rbp-8]        = layout
    ; [rbp-16]       = text_width   [rbp-24] = text_height (unused) -- out-params for pango_layout_get_pixel_size
    ; [rbp-40..-25]  = sample buffer (16 bytes -- room for up to 15 '9's + NUL, far more than a 32-bit line count could ever need, which tops out at 10 digits)

    ; --- build "9" * g_linenum_digit_count into the sample buffer ---------
    lea  rdi, [rbp-40]                 ; dest = sample buffer
    mov  ecx, [rel g_linenum_digit_count]
    test ecx, ecx
    jnz  .fill_loop
    mov  ecx, 1                          ; defensive floor: measure at least one '9' if this were ever somehow called before on_linenum_buffer_changed sets a real count
.fill_loop:
    mov  byte [rdi], '9'
    inc  rdi
    dec  ecx
    jnz  .fill_loop
    mov  byte [rdi], 0                     ; NUL-terminate

    ; --- measure it in the text view's current font -----------------------
    mov  rdi, [rel g_textview]
    xor  esi, esi
    CCALL gtk_widget_create_pango_layout
    mov  [rbp-8], rax

    mov  rdi, [rbp-8]
    lea  rsi, [rbp-40]  ; the sample buffer just built
    mov  edx, -1        ; NUL-terminated
    CCALL pango_layout_set_text

    mov  rdi, [rbp-8]
    lea  rsi, [rbp-16]                 ; &text_width (out)
    lea  rdx, [rbp-24]                 ; &text_height (out, unused)
    CCALL pango_layout_get_pixel_size  ; void pango_layout_get_pixel_size(PangoLayout*, int *width, int *height)

    mov  rdi, [rbp-8]                  ; layout
    CCALL g_object_unref

    mov  eax, [rbp-16]              ; text_width (int* out-param -- 32-bit read, see on_linenum_draw's comment on this pattern)
    add  eax, LINE_NUMBER_GUTTER_PADDING

    mov  rdi, [rel g_linenum_gutter]
    mov  esi, eax
    CCALL gtk_drawing_area_set_content_width   ; void gtk_drawing_area_set_content_width(GtkDrawingArea*, int)

    leave
    ret

; -------------------------------------------------------------------------
; void on_linenum_buffer_changed(GtkTextBuffer *buffer, gpointer user_data)
; GtkTextBuffer's "changed" signal handler (also called directly, ignoring
; its would-be arguments, by setup_line_numbers below to establish the
; initial digit count/width). See the file header for the performance
; argument: gtk_text_buffer_get_line_count is O(1) and the digit-counting
; loop below is at most ~10 iterations, so this whole function costs the
; same regardless of document size -- only the rare digit-count-changing
; edit actually re-measures/resizes anything.
; -------------------------------------------------------------------------
on_linenum_buffer_changed:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- the line count (already in eax right after the
    ; CCALL below) goes straight into the digit-counting loop, with
    ; nothing else clobbering it in between

    mov  rdi, [rel g_buffer]
    CCALL gtk_text_buffer_get_line_count   ; int gtk_text_buffer_get_line_count(GtkTextBuffer*) -- O(1), see file header

    ; --- count eax's decimal digits ----------------------------------------
    xor  ecx, ecx                 ; ecx = digit count so far
.count_loop:
    inc  ecx
    xor  edx, edx                  ; clear the high half before `div` -- it divides the full edx:eax pair
    mov  r10d, 10
    div  r10d                        ; eax /= 10 (quotient, becomes the remaining value); edx (the remainder) is discarded, we only care how many divisions it takes to reach 0
    test eax, eax
    jnz  .count_loop

    ; --- only actually resize the gutter if that changed the digit count ---
    cmp  ecx, [rel g_linenum_digit_count]
    je   .redraw_only

    mov  [rel g_linenum_digit_count], ecx
    ICALL refresh_line_number_gutter_width

.redraw_only:
    mov  rdi, [rel g_linenum_gutter]
    CCALL gtk_widget_queue_draw            ; the visible NUMBERS may have changed even when the digit-count budget didn't

    pop  rbp
    ret

; void on_linenum_invalidate(...) -- a generic redraw trigger, reused for
; both of GtkAdjustment's signals ("value-changed"/"changed"), which only
; ever mean one thing to us: "the set of visible line numbers might have
; changed, repaint" -- unlike on_linenum_buffer_changed above, scrolling
; or a scrollable-range change can never change the document's actual
; line count, so there's no digit-count work to redo here. None of the
; signals' actual arguments matter, so this ignores all of them.
on_linenum_invalidate:
    push rbp
    mov  rbp, rsp
    mov  rdi, [rel g_linenum_gutter]
    CCALL gtk_widget_queue_draw
    pop  rbp
    ret

; -------------------------------------------------------------------------
; void setup_line_numbers(void) -- call once, after g_textview AND
; g_scrolled both exist (window.asm).
; -------------------------------------------------------------------------
setup_line_numbers:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the text view's vertical GtkAdjustment

    CCALL gtk_drawing_area_new       ; GtkWidget *gtk_drawing_area_new(void)
    mov  [rel g_linenum_gutter], rax

    mov  rdi, rax                         ; arg1 = self (still in rax, untouched)
    lea  rsi, [rel on_linenum_draw]       ; arg2 = draw_func
    xor  edx, edx                         ; arg3 = user_data = NULL
    xor  ecx, ecx                         ; arg4 = destroy = NULL
    CCALL gtk_drawing_area_set_draw_func  ; void gtk_drawing_area_set_draw_func(GtkDrawingArea*, GtkDrawingAreaDrawFunc, gpointer, GDestroyNotify)

    mov  rdi, [rel g_textview]
    mov  esi, GTK_TEXT_WINDOW_LEFT
    mov  rdx, [rel g_linenum_gutter]
    CCALL gtk_text_view_set_gutter             ; void gtk_text_view_set_gutter(GtkTextView*, GtkTextWindowType, GtkWidget*) -- GTK now keeps this widget aligned with the text view's own vertical scrolling automatically

    ICALL on_linenum_buffer_changed               ; establishes the initial digit count/width for whatever's already loaded (a blank document needs exactly 1 digit) -- ignores its own would-be (buffer, user_data) arguments, same as when it runs as the real signal handler below

    ; recompute the digit count/width (if needed) and redraw whenever the
    ; buffer's content changes...
    mov  rdi, [rel g_buffer]
    lea  rsi, [rel sig_changed]
    lea  rdx, [rel on_linenum_buffer_changed]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    ; ...or whenever the view scrolls, or its scrollable range changes
    ; (word wrap toggling, a font-size change, or a window resize -- any
    ; of which can change which buffer lines are on screen without the
    ; buffer's own "changed" signal above ever firing)
    mov  rdi, [rel g_scrolled]
    CCALL gtk_scrolled_window_get_vadjustment       ; GtkAdjustment *gtk_scrolled_window_get_vadjustment(GtkScrolledWindow*) -- borrowed
    mov  [rbp-8], rax

    mov  rdi, [rbp-8]
    lea  rsi, [rel sig_value_changed]
    lea  rdx, [rel on_linenum_invalidate]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    mov  rdi, [rbp-8]
    lea  rsi, [rel sig_adj_changed]
    lea  rdx, [rel on_linenum_invalidate]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    leave
    ret

; void on_line_numbers_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
; View > Line Numbers: flips the stateful "win.line-numbers" action (which
; also updates its own checkbox rendering) and shows/hides the gutter to
; match -- same shape as statusbar.asm's on_status_bar_activate.
on_line_numbers_activate:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16              ; [rbp-8] = new_bool (the flipped state)
    ICALL toggle_bool_action  ; rdi already = action (this function's own incoming arg1)
    mov  [rbp-8], rax

    mov  rdi, [rel g_linenum_gutter]
    mov  esi, [rbp-8]
    CCALL gtk_widget_set_visible

    leave
    ret
