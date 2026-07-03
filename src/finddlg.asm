; finddlg.asm -- Find, Replace, and Go To Line. Each is a small plain
; GtkWindow (not modal, transient-for the main window), built lazily the
; first time it's needed and then just shown/hidden on reuse -- closing
; one via its titlebar X hides it too (close-request is intercepted)
; rather than destroying it, so the same dialog+widgets are reused for
; the life of the process.
;
; The actual search (find_next) walks GtkTextIter/gtk_text_iter_forward_search
; directly and always wraps around at end-of-buffer; Replace and Replace
; All both build on top of it so there is exactly one place that knows how
; to find a match.

%include "consts.inc"          ; G_CONNECT_DEFAULT, GTK_ORIENTATION_*, GTK_TEXT_SEARCH_TEXT_ONLY, FIND_TEXT_SIZE, TRUE/FALSE
%include "callconv.inc"        ; CCALL/ICALL macros
%include "extern.inc"          ; extern declarations for every GTK/GLib call used below

global on_find_activate         ; "win.find" GAction handler (actions.asm)
global on_find_next_activate    ; "win.find-next" GAction handler
global on_replace_activate      ; "win.replace" GAction handler
global on_goto_activate         ; "win.go-to-line" GAction handler

extern g_window                  ; main.asm -- transient-for parent for all three dialogs
extern g_textview                 ; main.asm -- scroll target after a match/jump
extern g_buffer                    ; main.asm -- every search/replace/goto operation reads or writes this
extern strcopy_bounded               ; fileio.asm -- bounded string copy, reused here to pull entry-widget text into our own buffers

section .rodata
    sig_activate         db "activate", 0          ; GtkEntry/GtkSpinButton's "user pressed Enter" signal
    sig_clicked          db "clicked", 0             ; GtkButton's signal
    sig_close_request    db "close-request", 0        ; GtkWindow's "titlebar X was clicked" signal

    title_find           db "Find", 0
    title_replace        db "Replace", 0
    title_goto           db "Go To Line", 0
    lbl_find_what        db "Find what:", 0
    lbl_replace_with     db "Replace with:", 0
    lbl_line_number      db "Line number:", 0
    lbl_find_next_btn    db "_Find Next", 0
    lbl_replace_btn      db "_Replace", 0
    lbl_replace_all_btn  db "Replace _All", 0
    lbl_cancel_btn       db "_Cancel", 0
    lbl_ok_btn           db "_OK", 0

section .data
    align 8
    ; gtk_spin_button_new_with_range takes three *doubles* (min, max,
    ; step) -- there's no way to load an arbitrary non-zero float
    ; immediate directly into an XMM register on x86, so these live in
    ; memory and get loaded with `movsd` at the two call sites below.
    dq_one     dq 1.0
    dq_million dq 1000000.0

section .bss
    align 8
    ; Find dialog widgets (built lazily by ensure_find_dialog)
    g_find_dialog         resq 1
    g_find_entry           resq 1
    ; Replace dialog widgets (built lazily by ensure_replace_dialog)
    g_replace_dialog       resq 1
    g_replace_find_entry   resq 1
    g_replace_with_entry   resq 1
    ; Go To Line dialog widgets (built lazily by ensure_goto_dialog)
    g_goto_dialog           resq 1
    g_goto_spin             resq 1
    ; the last search/replace terms, kept independent of whichever dialog
    ; (Find or Replace) most recently set them, since F3 (Find Next) must
    ; keep working even if the Find dialog was never opened this session
    g_find_text             resb FIND_TEXT_SIZE
    g_replace_text          resb FIND_TEXT_SIZE

section .text

; -------------------------------------------------------------------------
; GtkWidget *new_dialog(const char *title)
; Common shell for all three dialogs: plain non-modal GtkWindow, transient
; for the main window, not resizable, and close-request intercepted so
; the titlebar X hides it instead of destroying it (so g_find_dialog/
; g_replace_dialog/g_goto_dialog stay valid pointers for the rest of the
; program's life once built, safe to reuse without a NULL check beyond
; the initial "has this been built at all" one each ensure_*_dialog does).
; -------------------------------------------------------------------------
new_dialog:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                 ; [rbp-8]=title (the incoming arg, saved immediately -- every call below is free to clobber rdi)  [rbp-16]=the new GtkWindow, needed across several setup calls

    mov  [rbp-8], rdi

    CCALL gtk_window_new           ; GtkWidget *gtk_window_new(void)
    mov  [rbp-16], rax

    mov  rdi, [rbp-16]               ; arg1 = the new window
    mov  rsi, [rbp-8]                 ; arg2 = title
    CCALL gtk_window_set_title

    mov  rdi, [rbp-16]                 ; arg1 = the new window
    mov  rsi, [rel g_window]            ; arg2 = the main window
    CCALL gtk_window_set_transient_for    ; ties this dialog to the main window (stays above it, minimizes/restores together on most window managers)

    mov  rdi, [rbp-16]
    mov  esi, FALSE                       ; non-modal -- the user can still interact with the main window (or another dialog) while this one is open, matching classic Notepad's own modeless Find/Replace
    CCALL gtk_window_set_modal

    mov  rdi, [rbp-16]
    mov  esi, FALSE                        ; not resizable -- these are small, fixed-content dialogs
    CCALL gtk_window_set_resizable

    ; intercept the titlebar close button: without this, closing via X
    ; would DESTROY the widget, leaving g_find_dialog/etc. pointing at
    ; freed memory the next time it's needed
    mov  rdi, [rbp-16]                      ; arg1 = instance = the new window
    lea  rsi, [rel sig_close_request]        ; arg2 = "close-request"
    lea  rdx, [rel on_dialog_close_request]   ; arg3 = callback
    xor  ecx, ecx                              ; arg4 = user_data = NULL (the handler uses rdi/the window itself, doesn't need it)
    xor  r8, r8                                 ; arg5 = destroy_data = NULL
    mov  r9d, G_CONNECT_DEFAULT                  ; arg6 = flags = 0
    CCALL g_signal_connect_data

    mov  rax, [rbp-16]                            ; return value = the finished window
    leave
    ret

; gboolean on_dialog_close_request(GtkWindow *window, gpointer user_data)
; Shared by all three dialogs (connected once each, in new_dialog above).
; Returning TRUE tells GTK "I handled this, don't run the default
; destroy-the-window behavior".
on_dialog_close_request:
    push rbp
    mov  rbp, rsp
    mov  esi, FALSE                 ; arg2 = visible = FALSE (rdi is already the window -- this function's own incoming arg1)
    CCALL gtk_widget_set_visible     ; hide instead of destroy
    mov  eax, TRUE                    ; tell GTK the close request was handled -- don't also destroy the window
    pop  rbp
    ret

; void on_dialog_cancel_clicked(GtkButton *button, gpointer user_data)
; user_data must be the dialog to hide -- shared by all three dialogs'
; Cancel buttons, each connected with its own dialog as user_data (see
; the g_signal_connect_data calls in each ensure_*_dialog below, where
; rcx is set to [rbp-8], the dialog itself, rather than NULL).
on_dialog_cancel_clicked:
    push rbp
    mov  rbp, rsp
    mov  rdi, rsi                    ; arg1 = the dialog to hide = this function's own incoming user_data (rsi, the 2nd GtkButton "clicked" signal argument)
    mov  esi, FALSE                   ; arg2 = visible = FALSE
    CCALL gtk_widget_set_visible
    pop  rbp
    ret

; void apply_dialog_box_margins(GtkWidget *box) -- so a dialog's content
; doesn't sit flush against the (rounded-corner) window edge
apply_dialog_box_margins:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                 ; [rbp-8] = box (the incoming arg, saved since each margin call below clobbers rdi)
    mov  [rbp-8], rdi

    mov  rdi, [rbp-8]
    mov  esi, 10
    CCALL gtk_widget_set_margin_start
    mov  rdi, [rbp-8]
    mov  esi, 10
    CCALL gtk_widget_set_margin_end
    mov  rdi, [rbp-8]
    mov  esi, 10
    CCALL gtk_widget_set_margin_top
    mov  rdi, [rbp-8]
    mov  esi, 10
    CCALL gtk_widget_set_margin_bottom

    leave
    ret

; -------------------------------------------------------------------------
; void append_label_entry_row(GtkBox *parent, const char *label_text,
;                              GtkWidget *entry)
; Builds one horizontal "Label: [entry]" row and appends it to parent --
; the shared layout piece behind Find's "Find what:", Replace's two rows,
; and Go To Line's "Line number:".
; -------------------------------------------------------------------------
append_label_entry_row:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                 ; four local slots, one per argument/intermediate: [rbp-8]=parent [rbp-16]=label_text [rbp-24]=entry [rbp-32]=the row box we're building -- all three incoming args need to survive the several calls below, so none of them can stay in a register
    mov  [rbp-8], rdi
    mov  [rbp-16], rsi
    mov  [rbp-24], rdx

    mov  edi, GTK_ORIENTATION_HORIZONTAL
    mov  esi, 8                     ; spacing between the label and the entry
    CCALL gtk_box_new                 ; the row itself
    mov  [rbp-32], rax

    mov  rdi, [rbp-16]                 ; arg1 = the label text
    CCALL gtk_label_new                  ; GtkWidget *gtk_label_new(const char*)
    mov  rdi, [rbp-32]                    ; arg1 = the row
    mov  rsi, rax                          ; arg2 = the label widget just created (still in rax)
    CCALL gtk_box_append                     ; label goes first (left side)

    mov  rdi, [rbp-24]                        ; the entry widget
    mov  esi, TRUE
    CCALL gtk_widget_set_hexpand                ; let the entry (not the label) claim any extra horizontal space, so it grows to fill the dialog's width

    mov  rdi, [rbp-32]                            ; arg1 = the row
    mov  rsi, [rbp-24]                              ; arg2 = the entry
    CCALL gtk_box_append                               ; entry goes second (right side, after the label)

    mov  rdi, [rbp-8]                                   ; arg1 = parent (the dialog's main vertical box)
    mov  rsi, [rbp-32]                                    ; arg2 = the finished row
    CCALL gtk_box_append                                     ; the row itself gets appended to the dialog's content

    leave
    ret

; -------------------------------------------------------------------------
; gboolean find_next(void)
; Searches forward from the cursor for g_find_text, wrapping at
; end-of-buffer. On a match: selects it (with "insert" left at the match's
; end, so a repeated call continues past it), scrolls it into view, and
; returns TRUE. Returns FALSE if g_find_text is empty or not found
; anywhere in the buffer.
;
; This is the one place in the program that knows how to search --
; do_replace_one/do_replace_all (below) and on_find_next_activate both
; call it rather than duplicating any search logic.
; -------------------------------------------------------------------------
find_next:
    push rbp
    mov  rbp, rsp
    sub  rsp, 240                ; three GtkTextIter-sized (80 bytes each = GTK_TEXT_ITER_SIZE) local slots:
                                  ; [rbp-80]  = the search's starting position (the cursor, or doc start on the wrap-around retry)
                                  ; [rbp-160] = match_start, filled in by a successful search
                                  ; [rbp-240] = match_end, filled in by a successful search

    ; nothing to search for?
    movzx eax, byte [rel g_find_text]   ; peek at the first byte of the remembered search term
    test al, al
    jz   .out                              ; empty string -- bail out immediately, returning FALSE

    ; --- get an iterator at the current cursor position -----------------
    mov  rdi, [rel g_buffer]
    CCALL gtk_text_buffer_get_insert         ; GtkTextMark *gtk_text_buffer_get_insert(GtkTextBuffer*) -- the mark that tracks the cursor
    mov  rdx, rax                              ; arg3 (mark) for the next call -- captured now, before rdi/rsi are reloaded below; rax itself isn't touched by those two loads, so this is safe even though it "looks" out of order
    mov  rdi, [rel g_buffer]                     ; arg1 = buffer (fresh load, independent of rax)
    lea  rsi, [rbp-80]                             ; arg2 = &iter (out-param)
    CCALL gtk_text_buffer_get_iter_at_mark            ; fills [rbp-80] with the cursor's current position

    ; --- try searching forward from there ---------------------------------
    lea  rdi, [rbp-80]                     ; arg1 = &iter (the search's starting point)
    lea  rsi, [rel g_find_text]              ; arg2 = the text to search for
    mov  edx, GTK_TEXT_SEARCH_TEXT_ONLY        ; arg3 = flags -- plain text match, case-sensitive (no CASE_INSENSITIVE flag set)
    lea  rcx, [rbp-160]                          ; arg4 = &match_start (out-param)
    lea  r8, [rbp-240]                             ; arg5 = &match_end (out-param)
    xor  r9, r9                                     ; arg6 = limit = NULL (search all the way to the end of the buffer)
    CCALL gtk_text_iter_forward_search                 ; gboolean gtk_text_iter_forward_search(...) -- TRUE if found
    test eax, eax
    jnz  .found                                          ; found it on the first try -- skip the wrap-around retry entirely

    ; --- not found from the cursor onward -- wrap around and retry from the very start ---
    mov  rdi, [rel g_buffer]
    lea  rsi, [rbp-80]                       ; reuse the same iter slot -- its old (cursor) value is no longer needed
    CCALL gtk_text_buffer_get_start_iter        ; void gtk_text_buffer_get_start_iter(GtkTextBuffer*, GtkTextIter*) -- position 0

    lea  rdi, [rbp-80]                        ; arg1 = &iter, now at document start
    lea  rsi, [rel g_find_text]
    mov  edx, GTK_TEXT_SEARCH_TEXT_ONLY
    lea  rcx, [rbp-160]
    lea  r8, [rbp-240]
    xor  r9, r9
    CCALL gtk_text_iter_forward_search           ; second attempt, from the very beginning
    test eax, eax
    jz   .out                                      ; genuinely not found anywhere in the document -- give up, return FALSE

.found:
    ; --- select the match, positioned so a REPEATED find_next continues past it ---
    ; gtk_text_buffer_select_range(buffer, ins, bound) sets the "insert"
    ; mark to `ins` and "selection_bound" to `bound`. Passing match_end
    ; as `ins` (not match_start) means the cursor -- and thus the next
    ; call's starting-point lookup above -- ends up positioned right
    ; AFTER this match, so a second find_next call finds the NEXT
    ; occurrence rather than re-finding this same one. The visible
    ; selection still spans the whole match either way, since GTK
    ; highlights everything between "insert" and "selection_bound"
    ; regardless of which one is which.
    mov  rdi, [rel g_buffer]
    lea  rsi, [rbp-240]           ; ins = match_end
    lea  rdx, [rbp-160]           ; bound = match_start
    CCALL gtk_text_buffer_select_range

    ; --- scroll the match into view ---------------------------------------
    mov  rdi, [rel g_textview]        ; arg1 = the text view
    lea  rsi, [rbp-240]                 ; arg2 = &iter to scroll to (match_end -- either end works equally well for scrolling, since the goal is just "make the match visible")
    pxor xmm0, xmm0                       ; arg3 = within_margin = 0.0 (a double; pxor zeroes it bit-for-bit, cheaper than loading a memory constant for exactly 0.0)
    xor  edx, edx                           ; arg4 = use_align = FALSE (integer arg, NOT a float -- interleaves with the xmm float args per the SysV ABI's separate integer/float register sequences)
    pxor xmm1, xmm1                           ; arg5 = xalign = 0.0 (unused since use_align is FALSE, but must still be a valid double bit pattern -- zero is always valid)
    pxor xmm2, xmm2                             ; arg6 = yalign = 0.0 (same)
    CCALL gtk_text_view_scroll_to_iter             ; gboolean gtk_text_view_scroll_to_iter(GtkTextView*, GtkTextIter*, double within_margin, gboolean use_align, double xalign, double yalign) -- return value ignored

    mov  eax, TRUE                                    ; return value = found a match
    jmp  .ret
.out:
    xor  eax, eax                                       ; return value = nothing found (or nothing to search for)
.ret:
    leave
    ret

; -------------------------------------------------------------------------
; void do_replace_one(void)
; If a match is currently selected, replaces it with g_replace_text, then
; advances to the next match. "Currently selected" is exactly what
; find_next leaves behind on success, so the normal flow is: Find Next (or
; open the Replace dialog, which pre-fills nothing but relies on the user
; clicking Find Next first) selects a match, then Replace acts on it.
; -------------------------------------------------------------------------
do_replace_one:
    push rbp
    mov  rbp, rsp
    sub  rsp, 160                 ; two GtkTextIter slots: [rbp-80]=selection start [rbp-160]=selection end

    mov  rdi, [rel g_buffer]
    lea  rsi, [rbp-80]
    lea  rdx, [rbp-160]
    CCALL gtk_text_buffer_get_selection_bounds   ; gboolean gtk_text_buffer_get_selection_bounds(GtkTextBuffer*, GtkTextIter *start, GtkTextIter *end) -- TRUE if there IS a non-empty selection, and fills start/end with it
    test eax, eax
    jz   .skip_replace              ; nothing selected -- there's nothing to replace, just advance to the next match instead (see the shared tail below)

    ; begin/end_user_action group the delete+insert below into one undo
    ; step -- without this, Undo would need two separate steps (undo the
    ; insert, THEN undo the delete) to fully revert one Replace click,
    ; which is not what a user expects "Undo" to do here.
    mov  rdi, [rel g_buffer]
    CCALL gtk_text_buffer_begin_user_action

    mov  rdi, [rel g_buffer]                  ; arg1 = buffer
    lea  rsi, [rbp-80]                          ; arg2 = &start
    lea  rdx, [rbp-160]                          ; arg3 = &end
    CCALL gtk_text_buffer_delete                   ; void gtk_text_buffer_delete(GtkTextBuffer*, GtkTextIter *start, GtkTextIter *end) -- deletes the match; per GTK's documented behavior, both start and end are left pointing at the single (now-empty) position where the deleted text used to be

    mov  rdi, [rel g_buffer]                          ; arg1 = buffer
    lea  rsi, [rbp-80]                                  ; arg2 = &iter -- the (now-collapsed) deletion point from above
    lea  rdx, [rel g_replace_text]                       ; arg3 = the replacement text
    mov  ecx, -1                                           ; arg4 = len = -1, NUL-terminated
    CCALL gtk_text_buffer_insert                              ; void gtk_text_buffer_insert(GtkTextBuffer*, GtkTextIter*, const char *text, int len) -- inserts at the iter, which GTK then advances in place to point right after the inserted text

    mov  rdi, [rel g_buffer]                                    ; arg1 = buffer
    lea  rsi, [rbp-80]                                            ; arg2 = &iter -- now positioned right after the replacement text (per gtk_text_buffer_insert's documented behavior, used above)
    CCALL gtk_text_buffer_place_cursor                              ; void gtk_text_buffer_place_cursor(GtkTextBuffer*, const GtkTextIter*) -- collapses the selection to that point, so find_next's next search starts right after the replacement rather than possibly re-matching part of it

    mov  rdi, [rel g_buffer]
    CCALL gtk_text_buffer_end_user_action                             ; closes the undo group opened above

.skip_replace:
    ICALL find_next                 ; either way (replaced, or nothing was selected), advance to/select the next match
    leave
    ret

; -------------------------------------------------------------------------
; void do_replace_all(void)
; Replaces every occurrence from the start of the document, bounded by a
; generous iteration cap so a replacement string that itself contains the
; search string can't hang the app.
; -------------------------------------------------------------------------
do_replace_all:
    push rbp
    mov  rbp, rsp
    sub  rsp, 176                 ; [rbp-8]=iteration counter (the safety cap)  [rbp-88..-9]=selection start iter (80B)  [rbp-168..-89]=selection end iter (80B)

    ; --- start from the very beginning of the document, not wherever the cursor happens to be ---
    ; (without this, Replace All would only cover matches from the
    ; cursor onward plus whatever find_next's own wrap-around covers,
    ; which could replace things in a confusing order rather than
    ; deterministically front-to-back)
    mov  rdi, [rel g_buffer]
    lea  rsi, [rbp-88]
    CCALL gtk_text_buffer_get_start_iter    ; position 0
    mov  rdi, [rel g_buffer]
    lea  rsi, [rbp-88]
    CCALL gtk_text_buffer_place_cursor        ; move the cursor there, so find_next's very first search below starts from the true beginning

    mov  qword [rbp-8], 0            ; iteration counter starts at 0
    ICALL find_next                    ; select the first match, if any
    test eax, eax
    jz   .done                           ; nothing matches at all -- nothing to do, no undo group even needs to be opened

    ; the whole run of replacements below is one undo step, same
    ; reasoning as do_replace_one -- Undo should revert the ENTIRE
    ; Replace All in one click, not one replacement at a time
    mov  rdi, [rel g_buffer]
    CCALL gtk_text_buffer_begin_user_action

.loop:
    ; find_next has already selected a match by this point (either from
    ; just above, or from the end of the previous iteration) -- fetch its
    ; bounds so we can delete+replace it
    mov  rdi, [rel g_buffer]
    lea  rsi, [rbp-88]
    lea  rdx, [rbp-168]
    CCALL gtk_text_buffer_get_selection_bounds    ; return value not checked here -- we already know from find_next's own TRUE return (either above, or at the bottom of this loop) that a match is currently selected

    ; safety cap: bail out rather than loop forever if the replacement
    ; text itself contains the search text (which would otherwise make
    ; find_next keep finding a "new" match forever)
    mov  rax, [rbp-8]
    cmp  rax, 100000
    jge  .end_group
    inc  rax
    mov  [rbp-8], rax

    mov  rdi, [rel g_buffer]              ; arg1 = buffer
    lea  rsi, [rbp-88]                      ; arg2 = &start
    lea  rdx, [rbp-168]                       ; arg3 = &end
    CCALL gtk_text_buffer_delete                ; delete the match; start/end both collapse to the deletion point (same GTK behavior do_replace_one relies on)

    mov  rdi, [rel g_buffer]                       ; arg1 = buffer
    lea  rsi, [rbp-88]                               ; arg2 = &iter (the collapsed deletion point)
    lea  rdx, [rel g_replace_text]                     ; arg3 = replacement text
    mov  ecx, -1                                          ; arg4 = NUL-terminated
    CCALL gtk_text_buffer_insert                             ; inserts; iter advances to just past the new text

    mov  rdi, [rel g_buffer]                                   ; arg1 = buffer
    lea  rsi, [rbp-88]                                           ; arg2 = &iter, now just past the replacement
    CCALL gtk_text_buffer_place_cursor                             ; collapse selection there, so the next find_next search starts right after this replacement -- this is what guarantees the loop can't infinitely re-match the text it just inserted, bounding it naturally in the common case (the safety cap above only matters for the pathological case where the replacement text itself contains the search text)

    ICALL find_next                  ; look for the next occurrence
    test eax, eax
    jnz  .loop                          ; found one -- go replace it too

.end_group:
    mov  rdi, [rel g_buffer]
    CCALL gtk_text_buffer_end_user_action    ; close the undo group -- only reached if at least one replacement happened (the jz .done above skips straight past this when there were zero matches to begin with)
.done:
    leave
    ret

; =========================================================================
; Find dialog
; =========================================================================

; GtkWidget *ensure_find_dialog(void) -- builds g_find_dialog (and its
; entry) the first time it's needed; a no-op on every later call.
ensure_find_dialog:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=the dialog window [rbp-16]=its main vertical box [rbp-24]=the button row [rbp-32]=scratch for whichever button we're currently creating
    mov  rax, [rel g_find_dialog]
    test rax, rax
    jz   .build                    ; not built yet -- fall through
    leave                            ; already built -- nothing to do
    ret
.build:
    lea  rdi, [rel title_find]        ; arg = "Find"
    ICALL new_dialog                    ; builds the shared dialog shell (see new_dialog above)
    mov  [rbp-8], rax
    mov  [rel g_find_dialog], rax        ; cache it globally -- this is what makes every later call a no-op

    mov  edi, GTK_ORIENTATION_VERTICAL
    mov  esi, 8                            ; spacing between rows
    CCALL gtk_box_new                        ; the dialog's main content box
    mov  [rbp-16], rax
    mov  rdi, [rbp-16]
    ICALL apply_dialog_box_margins             ; 10px padding on all sides so content doesn't touch the window edge

    CCALL gtk_entry_new                          ; the "Find what:" text entry
    mov  [rel g_find_entry], rax

    mov  rdi, [rbp-16]                             ; parent = the content box
    lea  rsi, [rel lbl_find_what]                    ; label = "Find what:"
    mov  rdx, [rel g_find_entry]                       ; entry = the one just created
    ICALL append_label_entry_row                          ; builds and appends the "Find what: [___]" row

    ; pressing Enter in the entry should act like clicking Find Next
    mov  rdi, [rel g_find_entry]                             ; arg1 = instance = the entry
    lea  rsi, [rel sig_activate]                               ; arg2 = "activate" (GtkEntry's Enter-pressed signal)
    lea  rdx, [rel on_find_dialog_go]                            ; arg3 = callback
    xor  ecx, ecx                                                  ; arg4 = user_data = NULL
    xor  r8, r8                                                     ; arg5 = destroy_data = NULL
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    ; the button row: Find Next, Cancel
    mov  edi, GTK_ORIENTATION_HORIZONTAL
    mov  esi, 8
    CCALL gtk_box_new
    mov  [rbp-24], rax

    lea  rdi, [rel lbl_find_next_btn]         ; "_Find Next"
    CCALL gtk_button_new_with_mnemonic           ; GtkWidget *gtk_button_new_with_mnemonic(const char*) -- the leading "_" becomes an Alt-accessible mnemonic
    mov  [rbp-32], rax
    mov  rdi, [rbp-32]                             ; arg1 = instance = the button
    lea  rsi, [rel sig_clicked]                      ; arg2 = "clicked"
    lea  rdx, [rel on_find_dialog_go]                  ; arg3 = callback (same handler the Enter key uses above)
    xor  ecx, ecx                                        ; arg4 = user_data = NULL
    xor  r8, r8                                           ; arg5 = destroy_data = NULL
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data
    mov  rdi, [rbp-24]                                      ; arg1 = the button row
    mov  rsi, [rbp-32]                                        ; arg2 = the Find Next button
    CCALL gtk_box_append

    lea  rdi, [rel lbl_cancel_btn]              ; "_Cancel"
    CCALL gtk_button_new_with_mnemonic
    mov  [rbp-32], rax
    mov  rdi, [rbp-32]                             ; arg1 = instance = the Cancel button
    lea  rsi, [rel sig_clicked]                      ; arg2 = "clicked"
    lea  rdx, [rel on_dialog_cancel_clicked]           ; arg3 = the SHARED cancel handler (see its own comment above)
    mov  rcx, [rbp-8]                                    ; arg4 = user_data = the dialog itself -- this is what tells the shared handler WHICH dialog to hide
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data
    mov  rdi, [rbp-24]                                       ; arg1 = the button row
    mov  rsi, [rbp-32]                                         ; arg2 = the Cancel button
    CCALL gtk_box_append

    mov  rdi, [rbp-16]                    ; arg1 = the content box
    mov  rsi, [rbp-24]                      ; arg2 = the finished button row
    CCALL gtk_box_append                       ; button row goes after the "Find what:" row

    mov  rdi, [rbp-8]                            ; arg1 = the dialog window
    mov  rsi, [rbp-16]                             ; arg2 = the finished content box
    CCALL gtk_window_set_child                        ; attaches the whole layout to the window

    leave
    ret

; void on_find_dialog_go(GtkWidget *widget, gpointer user_data)
; Shared by the Find entry's "activate" (Enter key) and the Find Next
; button's "clicked" -- both mean the same thing: take whatever's
; currently in the entry as the new search term, then search.
on_find_dialog_go:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- the text pointer from gtk_editable_get_text is
    ; only needed once, immediately, as strcopy_bounded's source

    mov  rdi, [rel g_find_entry]
    CCALL gtk_editable_get_text        ; const char *gtk_editable_get_text(GtkEditable*) -- rax = a BORROWED pointer, owned by the entry itself, not us -- must not be freed
    mov  rsi, rax                        ; src = that text
    lea  rdi, [rel g_find_text]            ; dest = the persistent remembered-search-term buffer
    mov  rdx, FIND_TEXT_SIZE
    ICALL strcopy_bounded                     ; copies the entry's current text into g_find_text
    ICALL find_next                              ; and search for it
    pop  rbp
    ret

; void on_find_activate(GSimpleAction*, GVariant*, gpointer)
; Edit > Find...: opens the dialog, pre-filled with whatever the last
; search term was (possibly from a previous Find OR Replace dialog use).
on_find_activate:
    push rbp
    mov  rbp, rsp
    ICALL ensure_find_dialog          ; build the dialog if this is the first time

    mov  rdi, [rel g_find_entry]        ; arg1 = the entry
    lea  rsi, [rel g_find_text]           ; arg2 = the remembered search term (possibly empty)
    CCALL gtk_editable_set_text              ; void gtk_editable_set_text(GtkEditable*, const char*)

    mov  rdi, [rel g_find_dialog]
    CCALL gtk_window_present                  ; show/raise/focus the dialog window itself

    mov  rdi, [rel g_find_entry]
    CCALL gtk_widget_grab_focus                 ; and put the text cursor straight into the entry, ready to type

    pop  rbp
    ret

; void on_find_next_activate(GSimpleAction*, GVariant*, gpointer)
; Edit > Find Next / F3: repeats the last search without needing the
; dialog open at all -- but if nothing has ever been searched for this
; run, there's nothing to repeat, so fall back to opening Find instead
; (matches classic Notepad's own F3-with-nothing-searched-yet behavior).
on_find_next_activate:
    push rbp
    mov  rbp, rsp
    movzx eax, byte [rel g_find_text]     ; is there a remembered search term at all?
    test al, al
    jnz  .search
    ICALL on_find_activate         ; nothing searched yet -- open Find instead (rdi/rsi/rdx still hold this function's own original incoming args, which on_find_activate doesn't use anyway)
    jmp  .done
.search:
    ICALL find_next
.done:
    pop  rbp
    ret

; =========================================================================
; Replace dialog
; =========================================================================

; GtkWidget *ensure_replace_dialog(void) -- same lazy-build-once pattern
; as ensure_find_dialog, with two entries (Find what / Replace with) and
; four buttons (Find Next / Replace / Replace All / Cancel) instead of one entry and two buttons.
ensure_replace_dialog:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=dialog [rbp-16]=content box [rbp-24]=button row [rbp-32]=scratch for whichever button we're building
    mov  rax, [rel g_replace_dialog]
    test rax, rax
    jz   .build
    leave
    ret
.build:
    lea  rdi, [rel title_replace]
    ICALL new_dialog
    mov  [rbp-8], rax
    mov  [rel g_replace_dialog], rax

    mov  edi, GTK_ORIENTATION_VERTICAL
    mov  esi, 8
    CCALL gtk_box_new
    mov  [rbp-16], rax
    mov  rdi, [rbp-16]
    ICALL apply_dialog_box_margins

    CCALL gtk_entry_new                       ; "Find what:" entry
    mov  [rel g_replace_find_entry], rax
    mov  rdi, [rbp-16]
    lea  rsi, [rel lbl_find_what]
    mov  rdx, [rel g_replace_find_entry]
    ICALL append_label_entry_row

    CCALL gtk_entry_new                        ; "Replace with:" entry
    mov  [rel g_replace_with_entry], rax
    mov  rdi, [rbp-16]
    lea  rsi, [rel lbl_replace_with]
    mov  rdx, [rel g_replace_with_entry]
    ICALL append_label_entry_row

    ; pressing Enter in the "Find what:" entry acts like Find Next
    mov  rdi, [rel g_replace_find_entry]
    lea  rsi, [rel sig_activate]
    lea  rdx, [rel on_replace_dialog_find_next]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    ; the button row: Find Next, Replace, Replace All, Cancel
    mov  edi, GTK_ORIENTATION_HORIZONTAL
    mov  esi, 8
    CCALL gtk_box_new
    mov  [rbp-24], rax

    lea  rdi, [rel lbl_find_next_btn]           ; "_Find Next"
    CCALL gtk_button_new_with_mnemonic
    mov  [rbp-32], rax
    mov  rdi, [rbp-32]
    lea  rsi, [rel sig_clicked]
    lea  rdx, [rel on_replace_dialog_find_next]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data
    mov  rdi, [rbp-24]
    mov  rsi, [rbp-32]
    CCALL gtk_box_append

    lea  rdi, [rel lbl_replace_btn]              ; "_Replace"
    CCALL gtk_button_new_with_mnemonic
    mov  [rbp-32], rax
    mov  rdi, [rbp-32]
    lea  rsi, [rel sig_clicked]
    lea  rdx, [rel on_replace_dialog_replace]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data
    mov  rdi, [rbp-24]
    mov  rsi, [rbp-32]
    CCALL gtk_box_append

    lea  rdi, [rel lbl_replace_all_btn]           ; "Replace _All"
    CCALL gtk_button_new_with_mnemonic
    mov  [rbp-32], rax
    mov  rdi, [rbp-32]
    lea  rsi, [rel sig_clicked]
    lea  rdx, [rel on_replace_dialog_replace_all]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data
    mov  rdi, [rbp-24]
    mov  rsi, [rbp-32]
    CCALL gtk_box_append

    lea  rdi, [rel lbl_cancel_btn]                 ; "_Cancel"
    CCALL gtk_button_new_with_mnemonic
    mov  [rbp-32], rax
    mov  rdi, [rbp-32]
    lea  rsi, [rel sig_clicked]
    lea  rdx, [rel on_dialog_cancel_clicked]          ; the shared cancel handler
    mov  rcx, [rbp-8]                                    ; user_data = this dialog
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data
    mov  rdi, [rbp-24]
    mov  rsi, [rbp-32]
    CCALL gtk_box_append

    mov  rdi, [rbp-16]                    ; arg1 = content box
    mov  rsi, [rbp-24]                      ; arg2 = the finished button row
    CCALL gtk_box_append

    mov  rdi, [rbp-8]                            ; arg1 = the dialog window
    mov  rsi, [rbp-16]                             ; arg2 = the finished content box
    CCALL gtk_window_set_child

    leave
    ret

; void on_replace_dialog_sync_texts(void) -- copies both entry widgets'
; text into g_find_text / g_replace_text. Called before every Replace
; dialog action (Find Next, Replace, Replace All), so those always act on
; whatever's currently typed rather than a stale remembered value.
on_replace_dialog_sync_texts:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- each gtk_editable_get_text result is only
    ; needed once, immediately, as the following strcopy_bounded's source

    mov  rdi, [rel g_replace_find_entry]
    CCALL gtk_editable_get_text        ; borrowed pointer, owned by the entry
    mov  rsi, rax
    lea  rdi, [rel g_find_text]
    mov  rdx, FIND_TEXT_SIZE
    ICALL strcopy_bounded

    mov  rdi, [rel g_replace_with_entry]
    CCALL gtk_editable_get_text
    mov  rsi, rax
    lea  rdi, [rel g_replace_text]
    mov  rdx, FIND_TEXT_SIZE
    ICALL strcopy_bounded

    pop  rbp
    ret

; void on_replace_dialog_find_next(GtkWidget*, gpointer) -- the Replace
; dialog's own Find Next button/Enter-in-entry handler.
on_replace_dialog_find_next:
    push rbp
    mov  rbp, rsp
    ICALL on_replace_dialog_sync_texts    ; pick up whatever's currently typed in both entries
    ICALL find_next                          ; then search using g_find_text
    pop  rbp
    ret

; void on_replace_dialog_replace(GtkWidget*, gpointer) -- the Replace button.
on_replace_dialog_replace:
    push rbp
    mov  rbp, rsp
    ICALL on_replace_dialog_sync_texts
    ICALL do_replace_one
    pop  rbp
    ret

; void on_replace_dialog_replace_all(GtkWidget*, gpointer) -- the Replace All button.
on_replace_dialog_replace_all:
    push rbp
    mov  rbp, rsp
    ICALL on_replace_dialog_sync_texts
    ICALL do_replace_all
    pop  rbp
    ret

; void on_replace_activate(GSimpleAction*, GVariant*, gpointer)
; Edit > Replace...: opens the dialog, pre-filling the "Find what:" entry
; the same way Find does (the "Replace with:" entry is left as-is/empty,
; since there's no equivalent "last replacement" concept worth
; remembering the way the search term is).
on_replace_activate:
    push rbp
    mov  rbp, rsp
    ICALL ensure_replace_dialog

    mov  rdi, [rel g_replace_find_entry]
    lea  rsi, [rel g_find_text]
    CCALL gtk_editable_set_text

    mov  rdi, [rel g_replace_dialog]
    CCALL gtk_window_present

    mov  rdi, [rel g_replace_find_entry]
    CCALL gtk_widget_grab_focus

    pop  rbp
    ret

; =========================================================================
; Go To Line dialog
; =========================================================================

; GtkWidget *ensure_goto_dialog(void) -- same lazy-build-once pattern,
; with a GtkSpinButton (a numeric entry with up/down steppers) instead of
; a plain text entry, and OK/Cancel buttons instead of Find Next/Cancel.
ensure_goto_dialog:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=dialog [rbp-16]=content box [rbp-24]=button row [rbp-32]=scratch for whichever button we're building
    mov  rax, [rel g_goto_dialog]
    test rax, rax
    jz   .build
    leave
    ret
.build:
    lea  rdi, [rel title_goto]
    ICALL new_dialog
    mov  [rbp-8], rax
    mov  [rel g_goto_dialog], rax

    mov  edi, GTK_ORIENTATION_VERTICAL
    mov  esi, 8
    CCALL gtk_box_new
    mov  [rbp-16], rax
    mov  rdi, [rbp-16]
    ICALL apply_dialog_box_margins

    ; gtk_spin_button_new_with_range(min, max, step) takes three DOUBLES
    ; -- all three go in XMM0/XMM1/XMM2 per the SysV ABI's float-argument
    ; sequence, with NO integer-register arguments at all for this call.
    movsd xmm0, [rel dq_one]          ; arg1 = min = 1.0 (line numbers are 1-based)
    movsd xmm1, [rel dq_million]      ; arg2 = max = 1,000,000.0 (a generous ceiling, not tied to the actual document length)
    movsd xmm2, [rel dq_one]          ; arg3 = step = 1.0 (the up/down steppers move by whole lines)
    CCALL gtk_spin_button_new_with_range   ; GtkWidget *gtk_spin_button_new_with_range(double min, double max, double step)
    mov  [rel g_goto_spin], rax

    mov  rdi, [rbp-16]                       ; arg1 = content box
    lea  rsi, [rel lbl_line_number]            ; arg2 = "Line number:"
    mov  rdx, [rel g_goto_spin]                  ; arg3 = the spin button just created
    ICALL append_label_entry_row                    ; builds and appends the "Line number: [__]" row (the helper works fine with a GtkSpinButton in the "entry" slot -- both are just GtkWidget*)

    ; pressing Enter in the spin button acts like clicking OK
    mov  rdi, [rel g_goto_spin]
    lea  rsi, [rel sig_activate]
    lea  rdx, [rel on_goto_ok]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    ; the button row: OK, Cancel
    mov  edi, GTK_ORIENTATION_HORIZONTAL
    mov  esi, 8
    CCALL gtk_box_new
    mov  [rbp-24], rax

    lea  rdi, [rel lbl_ok_btn]              ; "_OK"
    CCALL gtk_button_new_with_mnemonic
    mov  [rbp-32], rax
    mov  rdi, [rbp-32]
    lea  rsi, [rel sig_clicked]
    lea  rdx, [rel on_goto_ok]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data
    mov  rdi, [rbp-24]
    mov  rsi, [rbp-32]
    CCALL gtk_box_append

    lea  rdi, [rel lbl_cancel_btn]           ; "_Cancel"
    CCALL gtk_button_new_with_mnemonic
    mov  [rbp-32], rax
    mov  rdi, [rbp-32]
    lea  rsi, [rel sig_clicked]
    lea  rdx, [rel on_dialog_cancel_clicked]    ; the shared cancel handler
    mov  rcx, [rbp-8]                              ; user_data = this dialog
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data
    mov  rdi, [rbp-24]
    mov  rsi, [rbp-32]
    CCALL gtk_box_append

    mov  rdi, [rbp-16]                    ; arg1 = content box
    mov  rsi, [rbp-24]                      ; arg2 = the finished button row
    CCALL gtk_box_append

    mov  rdi, [rbp-8]                            ; arg1 = the dialog window
    mov  rsi, [rbp-16]                             ; arg2 = the finished content box
    CCALL gtk_window_set_child

    leave
    ret

; void on_goto_ok(GtkWidget *widget, gpointer user_data)
; The Go To Line dialog's OK button / Enter-in-spin-button handler:
; reads the requested line number, jumps the cursor there, scrolls it
; into view, and hides the dialog.
on_goto_ok:
    push rbp
    mov  rbp, rsp
    sub  rsp, 96                  ; [rbp-96..-17] = a GtkTextIter (80 bytes)

    ; --- read the requested line number, clamped to a valid (0-based) index ---
    mov  rdi, [rel g_goto_spin]
    CCALL gtk_spin_button_get_value_as_int   ; int gtk_spin_button_get_value_as_int(GtkSpinButton*) -- the 1-based line number the user entered
    dec  eax                                    ; -> 0-based, since GTK's own line-index functions are 0-based
    cmp  eax, 0
    jge  .nonneg                                  ; still >= 0 after decrementing? (i.e. the user actually entered >= 1, which the spin button's own min=1.0 already guarantees, but this is a cheap belt-and-suspenders check)
    xor  eax, eax                                   ; otherwise clamp to 0 rather than passing a negative line index to GTK
.nonneg:
    mov  r10d, eax                    ; stash the (validated) 0-based line index -- no call happens between here and its use two lines below, so a plain scratch register is fine, unlike values that need to survive an intervening CCALL/ICALL

    ; --- get an iterator at the start of that line ------------------------
    mov  rdi, [rel g_buffer]           ; arg1 = buffer
    lea  rsi, [rbp-96]                   ; arg2 = &iter (out-param)
    mov  edx, r10d                         ; arg3 = the 0-based line number
    CCALL gtk_text_buffer_get_iter_at_line    ; gboolean gtk_text_buffer_get_iter_at_line(GtkTextBuffer*, GtkTextIter*, int line_number) -- fills iter; if line_number is past the end of the document, GTK clamps to the last line rather than erroring, so no failure handling is needed here

    ; --- move the cursor there and make sure it's visible -----------------
    mov  rdi, [rel g_buffer]             ; arg1 = buffer
    lea  rsi, [rbp-96]                     ; arg2 = &iter
    CCALL gtk_text_buffer_place_cursor        ; collapses the selection to that position

    mov  rdi, [rel g_textview]              ; arg1 = the text view
    lea  rsi, [rbp-96]                        ; arg2 = &iter to scroll to
    pxor xmm0, xmm0                              ; within_margin = 0.0 (same pattern as find_next's scroll call above)
    xor  edx, edx                                  ; use_align = FALSE
    pxor xmm1, xmm1                                  ; xalign = 0.0 (unused)
    pxor xmm2, xmm2                                    ; yalign = 0.0 (unused)
    CCALL gtk_text_view_scroll_to_iter

    ; --- close the dialog -----------------------------------------------
    mov  rdi, [rel g_goto_dialog]
    mov  esi, FALSE
    CCALL gtk_widget_set_visible

    leave
    ret

; void on_goto_activate(GSimpleAction*, GVariant*, gpointer)
; Edit > Go To...: opens the dialog, pre-filled with the cursor's CURRENT
; line number (so OK-without-changing-anything is a harmless no-op jump
; to where you already were).
on_goto_activate:
    push rbp
    mov  rbp, rsp
    sub  rsp, 96                  ; [rbp-96..-17] = a GtkTextIter (80 bytes)

    ICALL ensure_goto_dialog          ; build the dialog if this is the first time

    ; --- find the cursor's current line ------------------------------------
    mov  rdi, [rel g_buffer]
    CCALL gtk_text_buffer_get_insert     ; the mark tracking the cursor
    mov  rdx, rax                          ; arg3 (mark) for the next call -- captured now, before rdi/rsi below (rax itself untouched by those loads)
    mov  rdi, [rel g_buffer]                ; arg1 = buffer
    lea  rsi, [rbp-96]                        ; arg2 = &iter (out-param)
    CCALL gtk_text_buffer_get_iter_at_mark       ; fills iter with the cursor's position

    lea  rdi, [rbp-96]                    ; arg1 = &iter
    CCALL gtk_text_iter_get_line             ; int gtk_text_iter_get_line(const GtkTextIter*) -- 0-based line index
    inc  eax                                   ; -> 1-based, matching what the spin button (min=1.0) and a human both expect

    ; --- pre-fill the spin button with it -----------------------------------
    mov  rdi, [rel g_goto_spin]              ; arg1 = the spin button
    cvtsi2sd xmm0, eax                         ; arg2 = the line number, converted from a 32-bit int (eax) to a double in xmm0 -- gtk_spin_button_set_value takes a double, not an int
    CCALL gtk_spin_button_set_value              ; void gtk_spin_button_set_value(GtkSpinButton*, double)

    mov  rdi, [rel g_goto_dialog]
    CCALL gtk_window_present                       ; show/raise/focus the dialog

    mov  rdi, [rel g_goto_spin]
    CCALL gtk_widget_grab_focus                       ; put the cursor in the spin button's own entry, ready to type a different line number

    leave
    ret
