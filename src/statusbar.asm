; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; statusbar.asm -- the "Ln X, Col Y" status bar (plain GtkLabel, updated
; whenever the cursor moves) and its View > Status Bar visibility toggle.

%include "consts.inc"          ; GTK_ALIGN_START, G_CONNECT_DEFAULT
%include "callconv.inc"        ; CCALL/ICALL macros
%include "extern.inc"          ; extern gtk_label_new/gtk_label_set_text/gtk_text_buffer_get_iter_at_mark/gtk_text_iter_get_line(_offset)/g_signal_connect_data/gettext/g_strdup_printf/g_free

global build_statusbar          ; called once from window.asm, returns the label widget to pack into the layout
global on_status_bar_activate   ; the "win.status-bar" GAction handler, registered in actions.asm

extern g_buffer                  ; main.asm -- we read the cursor position from here
extern toggle_bool_action        ; format.asm -- shared "flip a stateful boolean GSimpleAction" helper

section .rodata
    sig_notify_cursor db "notify::cursor-position", 0   ; GtkTextBuffer's own "cursor-position" GObject property change notification -- fires on every caret move, not just every keystroke
    status_fmt        db "Ln %d, Col %d", 0             ; i18n: printf-style format fed through gettext, then g_strdup_printf, for both the real cursor position and the initial "Ln 1, Col 1"

section .bss
    align 8
    g_status_label resq 1                  ; GtkLabel* -- the status bar widget itself

section .text

; void update_status_label(void)
; Recomputes the 1-based line and column of the cursor (GtkTextIter's own
; line/offset are 0-based, hence the "inc eax" after each) and reformats
; the status label from them. Called every time the cursor moves (see
; on_cursor_moved below).
update_status_label:
    push rbp
    mov  rbp, rsp
    sub  rsp, 96                  ; [rbp-96..-17] = a GtkTextIter (80 bytes, GTK_TEXT_ITER_SIZE) [rbp-8] = 1-based line number [rbp-16] = 1-based column number

    ; --- get an iterator at the cursor ("insert" mark) position -------
    mov  rdi, [rel g_buffer]                    ; arg1 = buffer
    CCALL gtk_text_buffer_get_insert              ; GtkTextMark *gtk_text_buffer_get_insert(GtkTextBuffer*) -- the mark that tracks the text cursor
    mov  rdx, rax                                  ; arg3 (mark) = the mark we just got -- captured now, before rdi/rsi below overwrite unrelated registers (rax itself isn't touched by the next two loads)
    mov  rdi, [rel g_buffer]                       ; arg1 = buffer (fresh load, doesn't depend on rax)
    lea  rsi, [rbp-96]                             ; arg2 = &iter (out-param)
    CCALL gtk_text_buffer_get_iter_at_mark          ; void gtk_text_buffer_get_iter_at_mark(GtkTextBuffer*, GtkTextIter *iter, GtkTextMark *where) -- fills [rbp-96] with the cursor's position

    ; --- line = iter's line + 1 (GTK counts lines from 0) -------------
    lea  rdi, [rbp-96]                    ; arg1 = &iter
    CCALL gtk_text_iter_get_line           ; int gtk_text_iter_get_line(const GtkTextIter*) -- 0-based line index
    inc  eax                                ; -> 1-based, matching what a human calls "line 1"
    mov  [rbp-8], rax                        ; stash for the string-building below (zero-extended: eax write clears the upper 32 bits of rax)

    ; --- column = iter's line offset + 1 (also 0-based in GTK) --------
    lea  rdi, [rbp-96]                    ; arg1 = &iter (same iter, still valid -- nothing has modified the buffer since it was filled)
    CCALL gtk_text_iter_get_line_offset    ; int gtk_text_iter_get_line_offset(const GtkTextIter*) -- 0-based column within the line
    inc  eax                                ; -> 1-based
    mov  [rbp-16], rax

    ; --- format and push "Ln <line>, Col <col>" into the label ---------
    mov  edi, [rbp-8]     ; arg1 = line
    mov  esi, [rbp-16]    ; arg2 = col
    ICALL format_set_status_label

    leave
    ret

; void format_set_status_label(gint line, gint col)
; Formats "Ln <line>, Col <col>" via a translatable printf-style format
; string and pushes the result into the status label. Shared by
; update_status_label (the real cursor position) and build_statusbar (the
; initial "Ln 1, Col 1" shown before the first cursor-move signal ever
; fires) so there's exactly one place that knows the label's wording.
format_set_status_label:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32          ; [rbp-8]=line [rbp-16]=col [rbp-24]=g_strdup_printf's freshly-allocated string
    mov  [rbp-8], edi
    mov  [rbp-16], esi

    lea  rdi, [rel status_fmt]  ; arg1 = msgid
    CCALL gettext                 ; rax = the translated format string (or status_fmt itself, unchanged, if untranslated)
    mov  rdi, rax                  ; arg1 = format
    mov  esi, [rbp-8]                ; arg2 = line
    mov  edx, [rbp-16]                ; arg3 = col
    CCALL g_strdup_printf              ; gchar *g_strdup_printf(const gchar *format, ...) -- owned, must g_free below
    mov  [rbp-24], rax

    mov  rdi, [rel g_status_label]   ; arg1 = the GtkLabel
    mov  rsi, [rbp-24]                 ; arg2 = the formatted string
    CCALL gtk_label_set_text             ; void gtk_label_set_text(GtkLabel*, const char*) -- copies the text, doesn't take ownership

    mov  rdi, [rbp-24]
    CCALL g_free

    leave
    ret

; void on_cursor_moved(GObject *buffer, GParamSpec *pspec, gpointer user_data)
; GObject "notify::<property>" signal handler signature (pspec and
; user_data are both unused here -- we only care *that* it fired, not
; which property or with what extra context).
on_cursor_moved:
    push rbp
    mov  rbp, rsp
    ICALL update_status_label
    pop  rbp
    ret

; GtkWidget *build_statusbar(void) -- creates the label, connects the
; buffer's cursor-position notification, returns the label widget to pack.
build_statusbar:
    push rbp
    mov  rbp, rsp
    ; rsp is 16-aligned here (entry 8, -8 for push rbp = 0); no locals
    ; needed -- g_status_label is written straight to its .bss global.

    xor  edi, edi                            ; arg1 = NULL -- start empty, format_set_status_label below fills in the real (translated) text
    CCALL gtk_label_new                     ; GtkWidget *gtk_label_new(const char *str)
    mov  [rel g_status_label], rax          ; stash globally -- update_status_label, on_status_bar_activate, and window.asm's packing code all need this later

    mov  edi, 1                              ; arg1 = line 1
    mov  esi, 1                              ; arg2 = col 1 -- the label's text before the first cursor-move signal ever fires
    ICALL format_set_status_label

    mov  rdi, [rel g_status_label]
    mov  esi, GTK_ALIGN_START               ; left-align the text within the label (default is centered, which looks wrong for a status bar)
    CCALL gtk_widget_set_halign

    mov  rdi, [rel g_status_label]
    mov  esi, 3                              ; a few pixels so the text doesn't sit flush against the window's left edge/rounded corner
    CCALL gtk_widget_set_margin_start

    ; whenever the cursor moves, GtkTextBuffer's "cursor-position"
    ; property changes, which fires this "notify::cursor-position"
    ; signal -- connect it straight to on_cursor_moved so the label stays
    ; live without us polling anything.
    mov  rdi, [rel g_buffer]                 ; arg1 = instance = the text buffer
    lea  rsi, [rel sig_notify_cursor]        ; arg2 = "notify::cursor-position"
    lea  rdx, [rel on_cursor_moved]          ; arg3 = callback
    xor  ecx, ecx                            ; arg4 = user_data = NULL (not needed)
    xor  r8, r8                              ; arg5 = destroy_data = NULL
    mov  r9d, G_CONNECT_DEFAULT              ; arg6 = flags = 0
    CCALL g_signal_connect_data

    mov  rax, [rel g_status_label]           ; return value = the label widget, for the caller to pack
    leave
    ret

; void on_status_bar_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
; View > Status Bar: flips the stateful "win.status-bar" action (which
; also updates its own checkbox rendering) and shows/hides the label to
; match.
on_status_bar_activate:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = new_bool (the flipped state)
    ICALL toggle_bool_action       ; rdi already = action (this function's own incoming arg1); flips its GVariant boolean state and returns the new value in eax
    mov  [rbp-8], rax

    mov  rdi, [rel g_status_label]  ; arg1 = the label widget
    mov  esi, [rbp-8]                ; arg2 = visible? (TRUE/FALSE, same value the action's checkbox now shows)
    CCALL gtk_widget_set_visible      ; void gtk_widget_set_visible(GtkWidget*, gboolean)

    leave
    ret
