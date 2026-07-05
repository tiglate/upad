; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; printing.asm -- File > Page Setup... and File > Print..., via
; GtkPrintRunPageSetupDialogAsync and GtkPrintOperation (both plain GTK4
; APIs, not GTK 4.10+ -- these predate the newer async Gtk*Dialog family
; used elsewhere in this codebase, and there is no simpler replacement:
; GtkPrintOperation's begin-print/draw-page signals are still the
; standard way an app renders its own content to a printer).
;
; Page Setup just remembers a GtkPageSetup (g_page_setup) and a
; GtkPrintSettings (g_print_settings) across repeated Print/Page Setup
; invocations, same idea as format.asm's g_font_dialog caching.
;
; Print does real pagination: the whole document is laid out ONCE as a
; single PangoLayout (wrapped to the page width), then on_print_begin
; walks its lines with a PangoLayoutIter, accumulating each line's height
; until it would overflow the page, recording a "this line starts a new
; page" break each time -- same algorithm as GTK's own printing demo.
; on_print_draw_page then re-walks the iterator to whichever line range
; belongs to the requested page and draws just those lines, offset so the
; page's own first line lands at the top.
;
; NEW for this codebase: gtk_print_context_get_width/get_height return
; `double`, and cairo_move_to/cairo_set_source_rgb take `double` args --
; the first real floating-point traffic in this program (see callconv.inc
; for how that interacts with CCALL, which is unaffected: floats go into
; XMM0/XMM1/... directly, no macro involvement).
;
; Only one print job is ever in flight at a time (there is exactly one
; window/document), so the per-job PangoLayout and page-break array are
; kept as plain globals rather than threaded through as GtkPrintOperation
; user_data -- same simplifying assumption as g_font_dialog's single
; cached instance.

%include "consts.inc"    ; GTK_TEXT_ITER_SIZE, FALSE, G_CONNECT_DEFAULT, GTK_PRINT_OPERATION_ACTION_PRINT_DIALOG, GTK_PRINT_OPERATION_RESULT_*
%include "callconv.inc"  ; CCALL/ICALL macros
%include "extern.inc"    ; extern declarations for every GTK/GLib/Pango/cairo call used below

global on_page_setup_activate  ; "win.page-setup" GAction handler (actions.asm)
global on_print_activate       ; "win.print" GAction handler

extern g_window         ; main.asm -- parent for the page-setup/print dialogs
extern g_buffer         ; main.asm -- the text buffer Print reads from
extern g_font_desc_str  ; format.asm -- the last Format > Font... pick, as Pango text form ("Monospace Bold 12"); empty string if never picked
extern report_error     ; errdlg.asm -- shows an error dialog and logs, called if the print job itself fails

section .rodata
    default_print_font_str  db "Monospace 11", 0   ; same default Format > Font itself opens on when g_font_desc_str is still empty
    job_name_str             db "UnbloatedPad Document", 0

    sig_begin_print  db "begin-print", 0
    sig_draw_page    db "draw-page", 0
    sig_end_print    db "end-print", 0

    err_msg_print     db "Could not print", 0
    err_detail_print  db "The print job could not be completed. Check the printer connection and try again.", 0

    align 8
    pango_scale_dbl  dq 1024.0    ; PANGO_SCALE -- Pango measures everything in 1/1024ths of a layout unit; used to convert the print context's double-precision pixel sizes into the plain gint Pango wants, and back

section .bss
    align 8
    g_print_settings       resq 1  ; GtkPrintSettings*, lazily created by ensure_print_settings, reused across every Page Setup/Print this run
    g_page_setup           resq 1  ; GtkPageSetup*, NULL until Page Setup has been used at least once (Print tolerates NULL here -- it just means "use the printer's own default")

    ; per-print-job state, valid only between on_print_begin and
    ; on_print_end (there is only ever one job in flight -- see file header)
    g_print_job_layout      resq 1   ; PangoLayout* for the whole document, built fresh in on_print_begin, freed in on_print_end
    g_print_page_breaks     resq 1   ; g_malloc'd gint array: page_breaks[i] = the (0-based) line index where page i+1 begins
    g_print_page_break_count resq 1  ; how many entries of the array above are valid (n_pages = this + 1)
    g_print_line_count       resq 1  ; pango_layout_get_line_count's result, cached for on_print_draw_page's last-page end bound

section .text

; -------------------------------------------------------------------------
; void ensure_print_settings(void) -- lazily builds g_print_settings once;
; a no-op on every later call, same shape as format.asm's ensure_font_dialog.
; -------------------------------------------------------------------------
ensure_print_settings:
    push rbp
    mov  rbp, rsp
    mov  rax, [rel g_print_settings]
    test rax, rax
    jnz  .done
    CCALL gtk_print_settings_new     ; GtkPrintSettings *gtk_print_settings_new(void)
    mov  [rel g_print_settings], rax
.done:
    pop  rbp
    ret

; -------------------------------------------------------------------------
; void on_page_setup_done(GtkPageSetup *page_setup, gpointer data)
; The GtkPageSetupDoneFunc for gtk_print_run_page_setup_dialog_async below.
;
; page_setup is NULL when the user cancels the dialog on its very first
; use this run (i.e. when the page_setup we originally passed in was
; itself NULL, since g_page_setup hadn't been set yet) -- GTK passes back
; exactly what was given it in that case, rather than a fresh default.
; Confirmed with gdb: $rdi == 0x0 at entry on Cancel. This installed
; libgtk-4 apparently has its internal g_return_if_fail NULL/type checks
; compiled out, so calling gtk_page_setup_copy(NULL) unconditionally
; segfaults instead of just logging a critical warning -- hence the
; explicit check below, rather than trusting GTK to reject it gracefully.
; -------------------------------------------------------------------------
on_page_setup_done:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = our own independent copy of the incoming page_setup -- the incoming pointer itself is only borrowed (GTK's own docs mark it transfer-none), so it isn't safe to just stash the raw pointer and assume it outlives this callback

    test rdi, rdi
    jz   .done            ; Cancel -- nothing was picked, leave g_page_setup exactly as it was

    CCALL gtk_page_setup_copy       ; GtkPageSetup *gtk_page_setup_copy(GtkPageSetup*) -- rdi is already this function's own incoming page_setup argument; rax = a new, independently-owned copy
    mov  [rbp-8], rax

    mov  rax, [rel g_page_setup]      ; the previous one, if any
    test rax, rax
    jz   .store
    mov  rdi, rax
    CCALL g_object_unref
.store:
    mov  rax, [rbp-8]
    mov  [rel g_page_setup], rax

.done:
    leave
    ret

; void on_page_setup_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
on_page_setup_activate:
    push rbp
    mov  rbp, rsp
    ICALL ensure_print_settings        ; gtk_print_run_page_setup_dialog_async wants a real GtkPrintSettings, not NULL

    mov  rdi, [rel g_window]                     ; arg1 = parent
    mov  rsi, [rel g_page_setup]                 ; arg2 = page_setup -- NULL the first time this run, which is explicitly valid (GTK builds a default)
    mov  rdx, [rel g_print_settings]             ; arg3 = settings
    lea  rcx, [rel on_page_setup_done]           ; arg4 = done_cb
    xor  r8, r8                                  ; arg5 = data = NULL
    CCALL gtk_print_run_page_setup_dialog_async  ; void gtk_print_run_page_setup_dialog_async(GtkWindow*, GtkPageSetup*, GtkPrintSettings*, GtkPageSetupDoneFunc, gpointer) -- shows the dialog, returns immediately

    pop  rbp
    ret

; -------------------------------------------------------------------------
; void on_print_begin(GtkPrintOperation *operation, GtkPrintContext *context, gpointer user_data)
; Lays out the whole document as one PangoLayout wrapped to the page
; width, then walks its lines to decide where each page break falls.
; -------------------------------------------------------------------------
on_print_begin:
    push rbp
    mov  rbp, rsp
    sub  rsp, 288
    ; [rbp-8]   = operation (needed again at the very end, for set_n_pages)
    ; [rbp-16]  = context
    ; [rbp-24]  = layout (also stashed into g_print_job_layout for the other two signal handlers)
    ; [rbp-32]  = text (owned, from gtk_text_buffer_get_text -- freed right after pango_layout_set_text copies it)
    ; [rbp-40]  = font description (owned -- freed right after pango_layout_set_font_description copies it)
    ; [rbp-48]  = page_width_units (Pango units, from get_width() * 1024)
    ; [rbp-56]  = page_height_units (Pango units, from get_height() * 1024)
    ; [rbp-64]  = line_count
    ; [rbp-72]  = breaks (g_malloc'd gint array, upper-bounded at one break per line)
    ; [rbp-80]  = break_count (accumulator)
    ; [rbp-88]  = iter (PangoLayoutIter*)
    ; [rbp-96]  = line_index (loop counter)
    ; [rbp-104] = page_height_accum (loop accumulator, Pango units)
    ; [rbp-112] = y0 (out-param scratch for pango_layout_iter_get_line_yrange)
    ; [rbp-120] = y1 (out-param scratch, same call)
    ; [rbp-128] = line_height (y1 - y0 for the current line)
    ; [rbp-200..-121] = start iter (80 bytes, GTK_TEXT_ITER_SIZE)
    ; [rbp-280..-201] = end iter (80 bytes)

    mov  [rbp-8], rdi   ; operation
    mov  [rbp-16], rsi  ; context

    ; --- extract the whole buffer's text (same technique as fileio.asm's write_buffer_to_file) ---
    mov  rdi, [rel g_buffer]
    lea  rsi, [rbp-200]  ; &start iter
    lea  rdx, [rbp-280]  ; &end iter
    CCALL gtk_text_buffer_get_bounds

    mov  rdi, [rel g_buffer]
    lea  rsi, [rbp-200]
    lea  rdx, [rbp-280]
    mov  ecx, FALSE
    CCALL gtk_text_buffer_get_text     ; rax = owned string
    mov  [rbp-32], rax

    ; --- build the layout, sized/fonted for this print context -------------
    mov  rdi, [rbp-16]                           ; context
    CCALL gtk_print_context_create_pango_layout  ; PangoLayout *gtk_print_context_create_pango_layout(GtkPrintContext*) -- rax = a new layout, ours (full ownership)
    mov  [rbp-24], rax
    mov  [rel g_print_job_layout], rax    ; also stash globally -- on_print_draw_page/on_print_end need it after this function returns

    mov  rdi, [rbp-24]           ; layout
    mov  rsi, [rbp-32]           ; text
    mov  edx, -1                 ; length = -1 (NUL-terminated)
    CCALL pango_layout_set_text  ; copies the text internally, same convention as gtk_window_set_title etc.

    mov  rdi, [rbp-32]                                ; done with our own copy now
    CCALL g_free

    ; --- font: the last Format > Font pick, or the same default it opens on ---
    movzx eax, byte [rel g_font_desc_str]
    test al, al
    jnz  .have_font
    lea  rdi, [rel default_print_font_str]
    jmp  .parse_font
.have_font:
    lea  rdi, [rel g_font_desc_str]
.parse_font:
    CCALL pango_font_description_from_string   ; rax = a new description, ours
    mov  [rbp-40], rax

    mov  rdi, [rbp-24]                       ; layout
    mov  rsi, [rbp-40]                       ; desc
    CCALL pango_layout_set_font_description  ; copies the description internally

    mov  rdi, [rbp-40]
    CCALL pango_font_description_free                     ; done with our own copy

    ; --- page width -> Pango units (float math: only place in this program that does) ---
    mov  rdi, [rbp-16]                 ; context
    CCALL gtk_print_context_get_width  ; double gtk_print_context_get_width(GtkPrintContext*) -- returns in XMM0
    mulsd xmm0, [rel pango_scale_dbl]  ; xmm0 *= 1024.0
    cvttsd2si eax, xmm0                ; truncate to Pango's plain gint width unit
    movsxd rax, eax
    mov  [rbp-48], rax

    mov  rdi, [rbp-24]            ; layout
    mov  esi, [rbp-48]            ; width
    CCALL pango_layout_set_width  ; void pango_layout_set_width(PangoLayout*, int) -- wraps the text to fit the printable page width

    ; --- page height -> Pango units, same conversion ------------------------
    mov  rdi, [rbp-16]
    CCALL gtk_print_context_get_height
    mulsd xmm0, [rel pango_scale_dbl]
    cvttsd2si eax, xmm0
    movsxd rax, eax
    mov  [rbp-56], rax

    ; --- how many wrapped lines resulted? ------------------------------------
    mov  rdi, [rbp-24]
    CCALL pango_layout_get_line_count
    movsxd rax, eax
    mov  [rbp-64], rax

    ; --- allocate the page-break array (upper bound: one break per line) ----
    mov  rax, [rbp-64]
    imul rax, 4
    test rax, rax
    jnz  .alloc_breaks
    mov  rax, 4                                ; defensive floor -- g_malloc(0) is legal but there's no reason to rely on it
.alloc_breaks:
    mov  rdi, rax
    CCALL g_malloc
    mov  [rbp-72], rax
    mov  [rel g_print_page_breaks], rax

    ; --- walk every line, deciding where each page break falls --------------
    mov  qword [rbp-80], 0   ; break_count = 0
    mov  qword [rbp-96], 0   ; line_index = 0
    mov  qword [rbp-104], 0  ; page_height_accum = 0

    mov  rdi, [rbp-24]           ; layout
    CCALL pango_layout_get_iter  ; PangoLayoutIter *pango_layout_get_iter(PangoLayout*) -- rax = a new iter, ours to free
    mov  [rbp-88], rax

.line_loop:
    mov  rdi, [rbp-88]                       ; iter
    lea  rsi, [rbp-112]                      ; &y0
    lea  rdx, [rbp-120]                      ; &y1
    CCALL pango_layout_iter_get_line_yrange  ; void pango_layout_iter_get_line_yrange(PangoLayoutIter*, int *y0, int *y1) -- the vertical band belonging to the current line, layout-relative

    mov  eax, [rbp-120]  ; y1
    sub  eax, [rbp-112]  ; - y0 = this line's height
    movsxd rax, eax
    mov  [rbp-128], rax                   ; line_height

    mov  rax, [rbp-104]  ; page_height_accum
    add  rax, [rbp-128]  ; + line_height
    cmp  rax, [rbp-56]   ; > page_height_units ?
    jle  .fits

    ; doesn't fit -- this line starts a new page
    mov  rax, [rbp-72]       ; breaks
    mov  rcx, [rbp-80]       ; break_count
    mov  edx, [rbp-96]       ; line_index (32-bit)
    mov  [rax + rcx*4], edx  ; breaks[break_count] = line_index
    inc  qword [rbp-80]      ; break_count++
    mov  rax, [rbp-128]
    mov  [rbp-104], rax                                        ; page_height_accum = line_height (this line is now the new page's first)
    jmp  .advance

.fits:
    mov  rax, [rbp-104]
    add  rax, [rbp-128]
    mov  [rbp-104], rax               ; page_height_accum += line_height

.advance:
    inc  qword [rbp-96]                 ; line_index++
    mov  rdi, [rbp-88]
    CCALL pango_layout_iter_next_line      ; gboolean -- FALSE once there's no next line
    test eax, eax
    jnz  .line_loop

    mov  rdi, [rbp-88]
    CCALL pango_layout_iter_free

    ; --- publish the results for on_print_draw_page/on_print_end -----------
    mov  rax, [rbp-80]
    mov  [rel g_print_page_break_count], rax
    mov  rax, [rbp-64]
    mov  [rel g_print_line_count], rax

    mov  rdi, [rbp-8]   ; operation
    mov  rax, [rbp-80]  ; break_count
    inc  rax            ; + 1 = n_pages (always >= 1)
    mov  esi, eax
    CCALL gtk_print_operation_set_n_pages    ; void gtk_print_operation_set_n_pages(GtkPrintOperation*, int)

    leave
    ret

; -------------------------------------------------------------------------
; void on_print_draw_page(GtkPrintOperation *operation, GtkPrintContext *context, gint page_nr, gpointer user_data)
; Draws just the lines belonging to page_nr, using the single whole-document
; layout on_print_begin built (g_print_job_layout) and the page breaks it
; recorded (g_print_page_breaks).
; -------------------------------------------------------------------------
on_print_draw_page:
    push rbp
    mov  rbp, rsp
    sub  rsp, 112
    ; [rbp-8]   = context
    ; [rbp-16]  = page_nr
    ; [rbp-24]  = start_line (0-based, inclusive)
    ; [rbp-32]  = end_line (0-based, exclusive)
    ; [rbp-40]  = iter (PangoLayoutIter*)
    ; [rbp-48]  = line_index (loop counter)
    ; [rbp-56]  = page_top_y (this page's first line's y0, Pango units -- subtracted from every baseline drawn so the page's own content starts at the top)
    ; [rbp-64]  = cr (cairo_t*, borrowed from the context)
    ; [rbp-72]  = y0 (out-param scratch)
    ; [rbp-80]  = y1 (out-param scratch)
    ; [rbp-96]  = the current PangoLayoutLine* (borrowed) -- needs its own slot since two CCALLs (get_baseline, cairo_move_to) happen before it's used

    mov  [rbp-8], rsi              ; context
    movsxd rax, edx
    mov  [rbp-16], rax               ; page_nr

    ; --- start_line: 0 for the first page, else breaks[page_nr-1] ----------
    mov  rax, [rbp-16]
    test rax, rax
    jnz  .have_prev_break
    mov  qword [rbp-24], 0
    jmp  .find_end
.have_prev_break:
    mov  rcx, [rel g_print_page_breaks]
    mov  rdx, rax
    dec  rdx
    movsxd rax, dword [rcx + rdx*4]
    mov  [rbp-24], rax

.find_end:
    ; --- end_line: breaks[page_nr] if there is one, else the last line ------
    mov  rax, [rbp-16]
    cmp  rax, [rel g_print_page_break_count]
    jge  .last_page
    mov  rcx, [rel g_print_page_breaks]
    movsxd rax, dword [rcx + rax*4]
    mov  [rbp-32], rax
    jmp  .have_bounds
.last_page:
    mov  rax, [rel g_print_line_count]
    mov  [rbp-32], rax
.have_bounds:

    ; --- the cairo context to draw into, black text -------------------------
    mov  rdi, [rbp-8]
    CCALL gtk_print_context_get_cairo_context     ; cairo_t *gtk_print_context_get_cairo_context(GtkPrintContext*) -- borrowed, valid for this signal call only
    mov  [rbp-64], rax

    mov  rdi, [rbp-64]
    pxor xmm0, xmm0
    pxor xmm1, xmm1
    pxor xmm2, xmm2
    CCALL cairo_set_source_rgb          ; void cairo_set_source_rgb(cairo_t*, double r, double g, double b) -- (0,0,0) = black

    ; --- walk the shared layout's own iterator up to start_line -------------
    mov  rdi, [rel g_print_job_layout]
    CCALL pango_layout_get_iter
    mov  [rbp-40], rax
    mov  qword [rbp-48], 0

.skip_loop:
    mov  rax, [rbp-48]
    cmp  rax, [rbp-24]
    jge  .at_start
    mov  rdi, [rbp-40]
    CCALL pango_layout_iter_next_line
    inc  qword [rbp-48]
    jmp  .skip_loop

.at_start:
    mov  rdi, [rbp-40]
    lea  rsi, [rbp-72]
    lea  rdx, [rbp-80]
    CCALL pango_layout_iter_get_line_yrange     ; page_top_y = this page's first line's y0
    mov  eax, [rbp-72]
    movsxd rax, eax
    mov  [rbp-56], rax

.draw_loop:
    mov  rax, [rbp-48]
    cmp  rax, [rbp-32]
    jge  .done_drawing

    mov  rdi, [rbp-40]
    CCALL pango_layout_iter_get_line_readonly     ; PangoLayoutLine* -- borrowed, valid as long as the layout/iter are
    mov  [rbp-96], rax

    mov  rdi, [rbp-40]
    CCALL pango_layout_iter_get_baseline             ; int pango_layout_iter_get_baseline(PangoLayoutIter*) -- Pango units, relative to the WHOLE document's top
    movsxd rax, eax
    sub  rax, [rbp-56]                 ; -> relative to THIS PAGE's top instead
    cvtsi2sd xmm1, rax                 ; y, as a double, in Pango units
    divsd xmm1, [rel pango_scale_dbl]  ; -> cairo/layout units
    pxor xmm0, xmm0                    ; x = 0.0 (left edge of the printable area)

    mov  rdi, [rbp-64]   ; cr
    CCALL cairo_move_to  ; void cairo_move_to(cairo_t*, double x, double y) -- positions the NEXT show_layout_line call at this line's baseline

    mov  rdi, [rbp-64]                  ; cr
    mov  rsi, [rbp-96]                  ; line
    CCALL pango_cairo_show_layout_line  ; void pango_cairo_show_layout_line(cairo_t*, PangoLayoutLine*)

    inc  qword [rbp-48]
    mov  rdi, [rbp-40]
    CCALL pango_layout_iter_next_line
    jmp  .draw_loop

.done_drawing:
    mov  rdi, [rbp-40]
    CCALL pango_layout_iter_free

    leave
    ret

; -------------------------------------------------------------------------
; void on_print_end(GtkPrintOperation *operation, GtkPrintContext *context, gpointer user_data)
; Frees the per-job PangoLayout and page-break array on_print_begin built.
; -------------------------------------------------------------------------
on_print_end:
    push rbp
    mov  rbp, rsp

    mov  rdi, [rel g_print_job_layout]
    CCALL g_object_unref
    mov  qword [rel g_print_job_layout], 0

    mov  rdi, [rel g_print_page_breaks]
    CCALL g_free
    mov  qword [rel g_print_page_breaks], 0

    pop  rbp
    ret

; -------------------------------------------------------------------------
; void on_print_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
; File > Print: builds a GtkPrintOperation, wires the three signals above,
; and runs it with the standard print dialog. gtk_print_operation_run
; (with the default allow-async=FALSE) runs its own nested main loop and
; returns only once the user completes/cancels the dialog -- this is the
; ordinary, documented way to use GtkPrintOperation, unlike every other
; dialog in this codebase (GtkFileDialog/GtkFontDialog/...) which are all
; truly async; there is no async variant of running a GtkPrintOperation
; that doesn't add its own separate complexity (the allow-async property
; plus a "done" signal), which isn't needed here.
; -------------------------------------------------------------------------
on_print_activate:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=the GtkPrintOperation  [rbp-16]=scratch (a fresh GtkPrintSettings copy, only used on the RESULT_APPLY path)  [rbp-24]=the GtkPrintOperationResult from run()
    ICALL ensure_print_settings

    CCALL gtk_print_operation_new     ; GtkPrintOperation *gtk_print_operation_new(void)
    mov  [rbp-8], rax

    mov  rdi, [rbp-8]
    mov  rsi, [rel g_page_setup]         ; may be NULL (Page Setup never opened this run) -- explicitly valid, means "use the printer's own default"
    CCALL gtk_print_operation_set_default_page_setup

    mov  rdi, [rbp-8]
    mov  rsi, [rel g_print_settings]
    CCALL gtk_print_operation_set_print_settings

    mov  rdi, [rbp-8]
    lea  rsi, [rel job_name_str]
    CCALL gtk_print_operation_set_job_name

    ; --- connect the three signals that do the actual pagination/drawing ---
    mov  rdi, [rbp-8]
    lea  rsi, [rel sig_begin_print]
    lea  rdx, [rel on_print_begin]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    mov  rdi, [rbp-8]
    lea  rsi, [rel sig_draw_page]
    lea  rdx, [rel on_print_draw_page]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    mov  rdi, [rbp-8]
    lea  rsi, [rel sig_end_print]
    lea  rdx, [rel on_print_end]
    xor  ecx, ecx
    xor  r8, r8
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    ; --- show the print dialog and run the job ------------------------------
    mov  rdi, [rbp-8]
    mov  esi, GTK_PRINT_OPERATION_ACTION_PRINT_DIALOG
    mov  rdx, [rel g_window]
    xor  ecx, ecx                  ; arg4 = error = NULL -- only the return value is inspected below, no GError parsing needed
    CCALL gtk_print_operation_run  ; GtkPrintOperationResult gtk_print_operation_run(GtkPrintOperation*, GtkPrintOperationAction, GtkWindow*, GError**)
    movsxd rax, eax
    mov  [rbp-24], rax

    mov  rax, [rbp-24]
    cmp  rax, GTK_PRINT_OPERATION_RESULT_ERROR
    jne  .check_apply
    lea  rdi, [rel err_msg_print]
    lea  rsi, [rel err_detail_print]
    ICALL report_error                          ; errdlg.asm
    jmp  .cleanup

.check_apply:
    mov  rax, [rbp-24]
    cmp  rax, GTK_PRINT_OPERATION_RESULT_APPLY
    jne  .cleanup

    ; persist the (possibly printer/settings-changed) print settings for next time
    mov  rdi, [rbp-8]
    CCALL gtk_print_operation_get_print_settings   ; borrowed -- see gtk_print_settings_copy below
    test rax, rax
    jz   .cleanup
    mov  rdi, rax
    CCALL gtk_print_settings_copy                      ; GtkPrintSettings *gtk_print_settings_copy(GtkPrintSettings*) -- our own independent, owned copy
    mov  [rbp-16], rax

    mov  rax, [rel g_print_settings]
    test rax, rax
    jz   .store_new_settings
    mov  rdi, rax
    CCALL g_object_unref
.store_new_settings:
    mov  rax, [rbp-16]
    mov  [rel g_print_settings], rax

.cleanup:
    mov  rdi, [rbp-8]
    CCALL g_object_unref                    ; drop our reference on the operation -- by the time run() returns (synchronously), it's entirely done with all three signals

    leave
    ret
