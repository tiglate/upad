; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; fileio.asm -- New/Open/Save/Save As. File content itself moves through a
; single open()/lseek()/read()/close() or open()/write()/close() sequence
; via the raw POSIX calls (same shape as the original's CreateFileA/
; ReadFile/WriteFile path); GtkFileDialog (GTK 4.10+, async) only supplies
; the picked path. GtkTextBuffer requires UTF-8, but files in the wild
; often aren't -- encoding.asm handles transcoding on both ends (see
; read_file_to_buffer/write_buffer_to_file below), so this file itself
; never has to think about charsets directly.
;
; GtkFileDialog's open()/save() calls are asynchronous: they show the
; picker and return immediately, then invoke a GAsyncReadyCallback once
; the user actually picks something (or cancels). That's why there are
; four "activate" entry points here instead of two: on_open_activate and
; on_save_as_activate just show the dialog and return; the real work
; (reading/writing bytes) happens later, in on_open_finished and
; on_save_finished, once GLib calls back into us. Save itself can ALSO
; turn async on demand now: if the document's encoding hasn't been
; resolved yet (encoding.asm), the actual write waits behind a Convert/
; Keep-original/Cancel prompt -- see finish_save_current_path and
; ensure_encoding_resolved.

%include "consts.inc"          ; O_RDONLY/O_WRONLY/O_CREAT/O_TRUNC, SEEK_SET/SEEK_END, FILE_CREATE_MODE, FALSE, TITLE_BUF_SIZE
%include "callconv.inc"        ; CCALL/ICALL macros
%include "extern.inc"          ; extern declarations for every GTK/GLib/libc call used below

global on_new_activate          ; "win.new" GAction handler (actually reached via unsaved.asm's dirty-check wrapper, but this is the real implementation)
global on_open_activate         ; "win.open" GAction handler (same -- reached via unsaved.asm's wrapper)
global on_save_activate         ; "win.save" GAction handler
global on_save_as_activate      ; "win.save-as" GAction handler; also called directly by on_save_activate when there's no current path yet, and by unsaved.asm when the user picks "Save" on the unsaved-changes prompt with no path
global update_window_title      ; reused by window.asm (initial title) and unsaved.asm indirectly through the functions here
global strcopy_bounded          ; tiny bounded string-copy helper, reused by finddlg.asm/format.asm/statusbar.asm for their own string building
global write_buffer_to_file     ; reused by unsaved.asm's "Save" response and window.asm's on_open_signal is NOT this one (that reads) -- see read_file_to_buffer below
global read_file_to_buffer      ; reused by window.asm's on_open_signal (command-line file open)
global finish_save_current_path ; the continuation on_save_activate/on_save_finished (below) and unsaved.asm's Save response all pass to encoding.asm's ensure_encoding_resolved
global g_current_path           ; reused (read/written) by unsaved.asm and window.asm

extern g_window                      ; main.asm -- parent for the file-picker dialogs, target of gtk_window_set_title
extern g_buffer                      ; main.asm -- the text buffer New/Open/Save all operate on
extern clear_dirty                   ; unsaved.asm -- called after every successful New/Open/Save so the unsaved-changes prompt won't fire needlessly
extern g_dirty                       ; unsaved.asm -- read by build_title below to decide whether to prepend the unsaved-changes marker
extern report_file_error             ; errdlg.asm -- shows an error dialog and logs, called at every open()/lseek()/read()/write() failure below
extern reset_encoding_state          ; encoding.asm -- called on New, and internally by decode_and_load_into_buffer on every Open
extern decode_and_load_into_buffer   ; encoding.asm -- UTF-8 validation/transcoding, called from read_file_to_buffer below
extern encode_for_save               ; encoding.asm -- the reverse conversion (if needed), called from write_buffer_to_file below
extern ensure_encoding_resolved      ; encoding.asm -- gates the actual save behind a Convert/Keep-original prompt if the document's encoding hasn't been settled yet

section .rodata
    open_dlg_title  db "Open File", 0  ; i18n:
    save_dlg_title  db "Save File As", 0  ; i18n:
    untitled_str    db "Untitled", 0   ; i18n: window title (before title_suffix, NOT translated -- brand name) when there's no current file
    title_suffix    db " - UnbloatedPad", 0            ; appended after a filename or untitled_str -- deliberately NOT translatable (brand name)
    empty_str       db 0                                ; New needs *some* non-NULL pointer for "clear the buffer", even though the length passed is 0

    err_msg_open    db "Could not open file", 0  ; i18n: read_file_to_buffer's open() failed
    err_msg_read    db "Could not read file", 0  ; i18n: read_file_to_buffer's lseek()/read() failed after a successful open()
    err_msg_save    db "Could not save file", 0  ; i18n: write_buffer_to_file's open()/write() failed

    ; U+25CF BLACK CIRCLE (UTF-8: E2 97 8F) + a trailing space, prepended to
    ; the window title while unsaved.asm's g_dirty is set; written as raw
    ; bytes rather than a literal character so the result doesn't depend on
    ; this source file's own encoding.
    dirty_marker    db 0xE2, 0x97, 0x8F, " ", 0

section .bss
    align 8
    g_current_path  resq 1          ; heap gchar* from g_file_get_path, or 0 if the document has never been saved/opened from a real file ("Untitled")
    g_title_buf     resb TITLE_BUF_SIZE   ; scratch buffer build_title formats the window title into

section .text

; -------------------------------------------------------------------------
; char *strcopy_bounded(char *dest, const char *src, size_t max)
; Copies up to max-1 bytes of the NUL-terminated src into dest, always
; NUL-terminates. Returns a pointer to the NUL terminator written into
; dest (so callers can chain a second bounded copy right after it, by
; using the returned pointer as the next call's `dest`).
; -------------------------------------------------------------------------
strcopy_bounded:
    push rbp                      ; save caller's frame pointer
    mov  rbp, rsp                 ; establish frame (no locals -- this is a tight byte-copy loop using only its own arguments)
.loop:
    dec  rdx                      ; one fewer byte of budget left
    jz   .term                    ; hit the max (leaving room for the NUL) -- stop, even if src has more
    mov  al, [rsi]                ; al = next source byte
    test al, al                   ; is it the source's own NUL terminator?
    jz   .term                    ; yes -- stop, we're done copying real characters
    mov  [rdi], al                ; write the byte to dest
    inc  rdi                      ; advance dest
    inc  rsi                      ; advance src
    jmp  .loop                    ; and copy the next byte
.term:
    mov  byte [rdi], 0            ; always NUL-terminate dest, whichever way the loop above exited
    mov  rax, rdi                 ; return value = pointer to that NUL (so a caller can immediately append more text right there)
    pop  rbp
    ret

; -------------------------------------------------------------------------
; char *build_title(const char *basename_or_null)
; Formats g_title_buf as "[marker]Untitled - UnbloatedPad" (NULL) or
; "[marker]<basename> - UnbloatedPad", and returns a pointer to it. [marker]
; is "● " when unsaved.asm's g_dirty is set, otherwise nothing -- this is
; the one place that actually assembles the title string, so it's also the
; one place that needs to know about the unsaved-changes flag. g_title_buf
; is a single static 1KiB scratch buffer -- comfortably covers the marker
; plus a max-length (255 byte) POSIX filename plus the fixed suffix, and
; the title is consumed immediately by gtk_window_set_title, so there's no
; reentrancy concern (nothing else needs g_title_buf to still hold a
; previous result by the time this is called again).
; -------------------------------------------------------------------------
build_title:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = basename_or_null (stashed since the marker is written first, before rdi's argument is needed again)
    mov  [rbp-8], rdi

    ; --- prepend the unsaved-changes marker, if any ---------------------
    lea  rdi, [rel g_title_buf]      ; dest = start of the scratch buffer
    mov  rax, [rel g_dirty]           ; unsaved.asm
    test rax, rax
    jz   .have_dest                    ; not dirty -- dest stays at the very start, nothing to prepend
    lea  rsi, [rel dirty_marker]         ; src = "● "
    mov  rdx, 16
    ICALL strcopy_bounded
    mov  rdi, rax                        ; dest = continue right after the marker
.have_dest:

    mov  rax, [rbp-8]              ; was a basename given at all?
    test rax, rax
    jnz  .have_name                 ; yes -- go build "<basename> - UnbloatedPad"
    ; --- no file yet: "Untitled" (translated) + " - UnbloatedPad" (the
    ; brand name in title_suffix stays fixed across every language, same
    ; as the has-a-name path just below) ---------------------------------
    mov  [rbp-8], rdi               ; stash dest (currently either the buffer start or right after the marker) -- basename_or_null, NULL on this path, is no longer needed
    lea  rdi, [rel untitled_str]   ; arg1 = msgid = "Untitled"
    CCALL gettext
    mov  rsi, rax                    ; src = the translated word
    mov  rdi, [rbp-8]                  ; dest = restored
    mov  rdx, TITLE_BUF_SIZE          ; max = the whole buffer's size (generous fixed budget, same reasoning as below)
    ICALL strcopy_bounded
    mov  rdi, rax                        ; dest = continue right after "Untitled"
    lea  rsi, [rel title_suffix]           ; src = " - UnbloatedPad"
    mov  rdx, 32
    ICALL strcopy_bounded
    lea  rax, [rel g_title_buf]       ; return value = pointer to the buffer (strcopy_bounded's own return, the NUL position, isn't what callers of build_title want -- they want the start of the string)
    jmp  .done

.have_name:
    mov  rsi, [rbp-8]               ; the basename
    mov  rdx, TITLE_BUF_SIZE          ; max = the whole buffer
    ICALL strcopy_bounded              ; copies the basename in; rax = pointer to the NUL right after it
    ; rax = end of copied basename; 32 bytes is far more than the fixed
    ; 16-byte suffix needs, and TITLE_BUF_SIZE - 255 (max basename) still
    ; leaves hundreds of bytes of headroom, so this bound is always safe
    ; without computing the exact remaining space.
    mov  rdi, rax                    ; dest = continue right after the basename
    lea  rsi, [rel title_suffix]      ; src = " - UnbloatedPad"
    mov  rdx, 32
    ICALL strcopy_bounded
    lea  rax, [rel g_title_buf]        ; return value = start of the buffer again (not strcopy_bounded's own return this time either)

.done:
    leave
    ret

; -------------------------------------------------------------------------
; void update_window_title(void)
; Rebuilds and applies the window title from the current g_current_path.
; Called after every New/Open/Save that changes what "the current file"
; is, plus once at startup.
; -------------------------------------------------------------------------
update_window_title:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the basename we resolved (owned, must g_free), or 0 if there's no current path

    mov  rax, [rel g_current_path]
    test rax, rax                 ; is there a current file at all?
    jz   .untitled                 ; no -- basename stays 0/NULL, build_title below will produce "Untitled - ..."
    mov  rdi, rax                  ; arg1 = the path
    CCALL g_path_get_basename       ; gchar *g_path_get_basename(const gchar *file_name) -- rax = newly-allocated basename we now own
    mov  [rbp-8], rax
    jmp  .build
.untitled:
    mov  qword [rbp-8], 0

.build:
    mov  rdi, [rbp-8]              ; arg = basename_or_null
    ICALL build_title                ; rax = pointer to the freshly-formatted title in g_title_buf

    mov  rdi, [rel g_window]        ; arg1 = window
    mov  rsi, rax                    ; arg2 = the title string (still in rax, untouched since build_title returned)
    CCALL gtk_window_set_title        ; void gtk_window_set_title(GtkWindow*, const char*) -- GTK copies the string internally, so g_title_buf can be reused/overwritten freely afterward

    mov  rdi, [rbp-8]                 ; the basename we allocated above, if any
    test rdi, rdi
    jz   .done                          ; nothing to free if there was no current path
    CCALL g_free                         ; g_path_get_basename's return value is ours to free once gtk_window_set_title has copied what it needed
.done:
    leave
    ret

; -------------------------------------------------------------------------
; void read_file_to_buffer(const char *path)
; Reads path whole into g_buffer. Any open()/lseek()/read() failure leaves
; the text buffer untouched, shows an error dialog, and logs the failure
; (see errdlg.asm's report_file_error) instead of silently giving up.
;
; Sequence: open() for reading; lseek(SEEK_END) to find the size (then
; lseek back to 0, since SEEK_END leaves the file position at the end);
; g_malloc a same-size-plus-one buffer; one single read() call (not a
; retry loop -- see the note by the call below); hand the bytes straight
; to GtkTextBuffer; free the temporary buffer; close the file.
; -------------------------------------------------------------------------
read_file_to_buffer:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48                  ; [rbp-8]=fd (as a clean sign-extended 64-bit value)  [rbp-16]=file size (from lseek)  [rbp-24]=the temporary read buffer  [rbp-32]=path (stashed since rdi gets reused as open()'s own arg1 right below, but the error branches still need it)  [rbp-40]=saved errno (captured immediately after whichever syscall fails, before any cleanup call like close()/g_free() gets a chance to overwrite it)

    mov  [rbp-32], rdi              ; stash path before it's overwritten

    ; --- open(path, O_RDONLY, 0) ---------------------------------------
    ; arg1 (path) is already sitting in rdi, this function's own incoming argument
    mov  esi, O_RDONLY             ; arg2 = flags
    xor  edx, edx                   ; arg3 = mode (ignored without O_CREAT, but the libc wrapper still takes 3 args)
    CCALL open                       ; int open(const char *pathname, int flags, mode_t mode) -- returns a 32-bit fd or -1
    movsxd rax, eax                  ; sign-extend the 32-bit result into a clean 64-bit value -- only EAX is ABI-guaranteed meaningful after a call returning `int`, so this must happen before storing/comparing the full register
    mov  [rbp-8], rax                ; stash fd
    cmp  rax, 0
    jl   .open_failed                 ; open failed (fd < 0) -- nothing to close, nothing to free, just report it

    ; --- lseek(fd, 0, SEEK_END) to find the file's size -----------------
    mov  edi, [rbp-8]               ; arg1 = fd
    xor  esi, esi                    ; arg2 = offset = 0
    mov  edx, SEEK_END                ; arg3 = whence = SEEK_END
    CCALL lseek                        ; off_t lseek(int fd, off_t offset, int whence) -- returns the new (here: end-of-file) position, i.e. the file's size
    mov  [rbp-16], rax                  ; stash the size
    cmp  rax, 0
    jl   .read_failed_close_only         ; lseek failed -- close the (validly opened) fd and report it, nothing was allocated yet

    ; --- lseek(fd, 0, SEEK_SET) to rewind back to the start --------------
    mov  edi, [rbp-8]
    xor  esi, esi                    ; offset = 0
    xor  edx, edx                     ; whence = SEEK_SET (0) -- rewind to start
    CCALL lseek                        ; rewind to start
    cmp  rax, 0
    jl   .read_failed_close_only        ; rewind failed -- treat the same as any other read-side failure

    ; --- allocate a buffer exactly big enough (plus 1, defensively) ------
    mov  rdi, [rbp-16]               ; arg1 = size (the file's byte count from lseek above)
    inc  rdi                          ; +1 -- not strictly required since we pass an explicit length to gtk_text_buffer_set_text rather than relying on a NUL terminator, but cheap insurance
    CCALL g_malloc                     ; gpointer g_malloc(gsize n_bytes) -- aborts the process on OOM rather than returning NULL, so no failure check needed here
    mov  [rbp-24], rax                  ; stash the buffer pointer

    ; --- read(fd, buf, size) ----------------------------------------------
    ; files opened via a save-your-own-editor round trip are small enough
    ; in practice that we don't loop for partial reads; a partial read
    ; here just means a partial (never garbage) result, so this stays
    ; correct even in the rare case a single read() is interrupted early
    ; -- it just silently loads less text than the file actually has.
    mov  edi, [rbp-8]                 ; arg1 = fd
    mov  rsi, [rbp-24]                 ; arg2 = buffer
    mov  rdx, [rbp-16]                  ; arg3 = count = the file's size
    CCALL read                           ; ssize_t read(int fd, void *buf, size_t count) -- returns bytes actually read, or -1 on error
    cmp  rax, 0
    jl   .read_failed_free_and_close                  ; read failed -- skip loading anything into the buffer, free/close what we allocated/opened, and report it
    mov  rdx, rax                          ; rdx = actual bytes read (may be less than the file's size if the read was short, per the note above; 0 is valid too, for an empty file)

    ; --- decode (transcoding from a legacy encoding if it's not valid UTF-8) and load into the text buffer ---
    mov  rdi, [rbp-24]                   ; arg1 = the bytes we just read
    mov  rsi, rdx                          ; arg2 = length
    ICALL decode_and_load_into_buffer         ; encoding.asm -- validates UTF-8 (transcoding from Windows-1252 if needed) and sets the text buffer's contents itself; reports its own error (leaving the buffer untouched) if even that fallback fails

    mov  rdi, [rbp-24]                   ; the temporary read buffer -- always ours to free regardless of what decode_and_load_into_buffer did with ITS OWN (separate) buffer, since it never takes ownership of this one, only reads from it
    CCALL g_free                           ; GTK/g_convert both copy the bytes they need, so we don't hand off ownership
    mov  edi, [rbp-8]                     ; fd
    CCALL close                             ; int close(int fd) -- return value ignored, nothing useful to do if it fails
    jmp  .done

.open_failed:
    CCALL __errno_location                ; int *__errno_location(void) -- capture errno now, even though there's nothing to clean up on this path yet, to keep the same shape as the branches below
    mov  eax, [rax]
    mov  [rbp-40], eax
    lea  rdi, [rel err_msg_open]  ; arg1 = msgid
    CCALL gettext
    mov  rdi, rax                   ; arg1 = translated op_summary
    mov  rsi, [rbp-32]                ; arg2 = path (fresh from its own stack slot, untouched by the gettext call above)
    mov  edx, [rbp-40]                  ; arg3 = saved errno (same)
    ICALL report_file_error
    jmp  .done

.read_failed_close_only:
    CCALL __errno_location                ; captured before close() below gets a chance to overwrite errno
    mov  eax, [rax]
    mov  [rbp-40], eax
    mov  edi, [rbp-8]
    CCALL close
    lea  rdi, [rel err_msg_read]  ; arg1 = msgid
    CCALL gettext
    mov  rdi, rax                   ; arg1 = translated op_summary
    mov  rsi, [rbp-32]                ; arg2 = path
    mov  edx, [rbp-40]                  ; arg3 = saved errno
    ICALL report_file_error
    jmp  .done

.read_failed_free_and_close:
    CCALL __errno_location                ; captured before g_free()/close() below get a chance to overwrite errno
    mov  eax, [rax]
    mov  [rbp-40], eax
    mov  rdi, [rbp-24]
    CCALL g_free
    mov  edi, [rbp-8]
    CCALL close
    lea  rdi, [rel err_msg_read]  ; arg1 = msgid
    CCALL gettext
    mov  rdi, rax                   ; arg1 = translated op_summary
    mov  rsi, [rbp-32]                ; arg2 = path
    mov  edx, [rbp-40]                  ; arg3 = saved errno
    ICALL report_file_error
.done:
    leave
    ret

; -------------------------------------------------------------------------
; void write_buffer_to_file(const char *path)
; Writes the whole text buffer out to path (create/truncate). Any
; open()/write() failure shows an error dialog and logs it (see
; errdlg.asm's report_file_error) instead of silently giving up.
;
; Sequence: get the buffer's full text as one string (bounds + get_text);
; strlen it (GTK doesn't hand back a length alongside the string); open()
; for writing (creating/truncating as needed); one single write() call
; (see the note below); close(); free the text GTK gave us.
; -------------------------------------------------------------------------
write_buffer_to_file:
    push rbp
    mov  rbp, rsp
    sub  rsp, 208
    ; [rbp-8]=path (the incoming argument, saved immediately since every
    ;               call below is free to clobber rdi)
    ; [rbp-16]=fd (sign-extended, same reasoning as read_file_to_buffer)
    ; [rbp-24]=text (the buffer's full contents, as returned by GTK -- owned, must g_free)
    ; [rbp-32]=textlen (from strlen(text))
    ; [rbp-112..-33] = start iter (80 bytes, GTK_TEXT_ITER_SIZE)
    ; [rbp-192..-113] = end iter (80 bytes)
    ; [rbp-200]=saved errno, captured immediately after whichever syscall
    ;           below fails, before any cleanup call (close()/g_free()) can
    ;           overwrite it -- kept past the two iters rather than
    ;           interleaved, so none of their existing offsets had to move
    mov  [rbp-8], rdi

    ; --- get iterators spanning the whole buffer --------------------------
    mov  rdi, [rel g_buffer]              ; arg1 = buffer
    lea  rsi, [rbp-112]                    ; arg2 = &start (out-param)
    lea  rdx, [rbp-192]                     ; arg3 = &end (out-param)
    CCALL gtk_text_buffer_get_bounds         ; void gtk_text_buffer_get_bounds(GtkTextBuffer*, GtkTextIter *start, GtkTextIter *end) -- fills both to span the entire document

    ; --- extract the text between them as one string ----------------------
    mov  rdi, [rel g_buffer]               ; arg1 = buffer
    lea  rsi, [rbp-112]                     ; arg2 = &start
    lea  rdx, [rbp-192]                      ; arg3 = &end
    mov  ecx, FALSE                           ; arg4 = include_hidden_chars = FALSE (we want exactly what a human sees/typed)
    CCALL gtk_text_buffer_get_text             ; char *gtk_text_buffer_get_text(GtkTextBuffer*, const GtkTextIter *start, const GtkTextIter *end, gboolean include_hidden_chars) -- rax = newly-allocated string we now own
    mov  [rbp-24], rax

    ; --- find out how many bytes that actually is --------------------------
    mov  rdi, [rbp-24]                       ; arg1 = the text
    CCALL strlen                               ; size_t strlen(const char*) -- GTK's get_text doesn't hand back a length alongside the string, so this is the only way to get one
    mov  [rbp-32], rax

    ; --- transcode back to the document's original encoding, if the user chose to keep it (encoding.asm) ---
    mov  rdi, [rbp-24]                 ; arg1 = utf8_text -- encode_for_save takes ownership of this (see its own header comment)
    mov  rsi, [rbp-32]                   ; arg2 = utf8_len
    lea  rdx, [rbp-24]                     ; arg3 = &out_text -- written back into this SAME slot
    lea  rcx, [rbp-32]                       ; arg4 = &out_len -- ditto
    ICALL encode_for_save
    test eax, eax
    jz   .done                                 ; conversion failed -- encode_for_save already freed everything and reported the error; nothing left to write

    ; --- open(path, O_WRONLY|O_CREAT|O_TRUNC, 0644) -------------------------
    mov  rdi, [rbp-8]                         ; arg1 = path
    mov  esi, O_WRONLY | O_CREAT | O_TRUNC      ; arg2 = flags -- create it if it doesn't exist, truncate it if it does (we're always writing the WHOLE current buffer, never appending)
    mov  edx, FILE_CREATE_MODE                   ; arg3 = mode (rw-r--r--), only used if O_CREAT actually creates a new file
    CCALL open
    movsxd rax, eax                               ; sign-extend the 32-bit result before storing/comparing (see read_file_to_buffer for why)
    mov  [rbp-16], rax
    cmp  rax, 0
    jl   .open_failed                              ; open failed -- nothing to write or close, but we still own `text` and must free it (and report the failure)

    ; --- write(fd, text, textlen) -------------------------------------------
    ; single call, same reasoning as read(): our own files are never
    ; large enough in practice to need a partial-write retry loop. A
    ; short write (rax >= 0 but < textlen) still reports success here --
    ; only a hard failure (rax < 0) is treated as an error below.
    mov  edi, [rbp-16]                          ; arg1 = fd
    mov  rsi, [rbp-24]                            ; arg2 = text
    mov  rdx, [rbp-32]                             ; arg3 = textlen
    CCALL write                                      ; ssize_t write(int fd, const void *buf, size_t count) -- returns bytes actually written, or -1 on error
    cmp  rax, 0
    jl   .write_failed                                ; write failed -- close+free still needed, then report it

    mov  edi, [rbp-16]                            ; fd
    CCALL close                                     ; return value ignored
    mov  rdi, [rbp-24]                            ; the text GTK gave us
    CCALL g_free                                    ; always free it
    jmp  .done

.open_failed:
    CCALL __errno_location
    mov  eax, [rax]
    mov  [rbp-200], eax
    mov  rdi, [rbp-24]                            ; still own `text`, must free it regardless of the open failure
    CCALL g_free
    lea  rdi, [rel err_msg_save]  ; arg1 = msgid
    CCALL gettext
    mov  rdi, rax                   ; arg1 = translated op_summary
    mov  rsi, [rbp-8]                 ; arg2 = path
    mov  edx, [rbp-200]                 ; arg3 = saved errno
    ICALL report_file_error
    jmp  .done

.write_failed:
    CCALL __errno_location                        ; captured before close()/g_free() below get a chance to overwrite errno
    mov  eax, [rax]
    mov  [rbp-200], eax
    mov  edi, [rbp-16]
    CCALL close
    mov  rdi, [rbp-24]
    CCALL g_free
    lea  rdi, [rel err_msg_save]  ; arg1 = msgid
    CCALL gettext
    mov  rdi, rax                   ; arg1 = translated op_summary
    mov  rsi, [rbp-8]                 ; arg2 = path
    mov  edx, [rbp-200]                 ; arg3 = saved errno
    ICALL report_file_error

.done:
    leave
    ret

; -------------------------------------------------------------------------
; Action handlers -- signatures match GActionEntry's activate callback,
; void (*)(GSimpleAction *action, GVariant *parameter, gpointer user_data),
; except *_finished which match GAsyncReadyCallback,
; void (*)(GObject *source_object, GAsyncResult *res, gpointer user_data).
; -------------------------------------------------------------------------

; File > New. Clears the buffer, forgets the current path (so the
; document becomes "Untitled" again), retitles the window, and marks the
; document as no longer having unsaved changes.
on_new_activate:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- everything here is either a global or an
    ; immediate constant, nothing needs to survive across an unrelated call

    mov  rdi, [rel g_buffer]        ; arg1 = buffer
    lea  rsi, [rel empty_str]        ; arg2 = "" (a valid, non-NULL, zero-length string)
    xor  edx, edx                     ; arg3 = len = 0
    CCALL gtk_text_buffer_set_text     ; wipes the document

    mov  rdi, [rel g_current_path]      ; was there a previous file?
    test rdi, rdi
    jz   .no_free
    CCALL g_free                          ; yes -- release the path string we owned
.no_free:
    mov  qword [rel g_current_path], 0     ; either way, there is no current file now

    ICALL update_window_title                ; retitle to "Untitled - UnbloatedPad"
    ICALL clear_dirty                          ; a freshly-cleared buffer has no unsaved changes
    ICALL reset_encoding_state                   ; a fresh blank document is unambiguous UTF-8 -- no encoding question pending (encoding.asm)
    pop  rbp
    ret

; File > Open: shows the picker and returns immediately (async) --
; the actual file read happens in on_open_finished below, once the user
; picks something.
on_open_activate:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the GtkFileDialog object, needed across three calls below

    CCALL gtk_file_dialog_new       ; GtkFileDialog *gtk_file_dialog_new(void)
    mov  [rbp-8], rax

    lea  rdi, [rel open_dlg_title]  ; arg1 = msgid
    CCALL gettext
    mov  rsi, rax                     ; arg2 = translated title
    mov  rdi, [rbp-8]                    ; arg1 = self
    CCALL gtk_file_dialog_set_title

    mov  rdi, [rbp-8]                 ; arg1 = self
    mov  rsi, [rel g_window]           ; arg2 = parent window
    xor  edx, edx                       ; arg3 = cancellable = NULL (we never cancel this programmatically)
    lea  rcx, [rel on_open_finished]     ; arg4 = callback, invoked once the user picks a file or cancels
    xor  r8, r8                           ; arg5 = user_data = NULL
    CCALL gtk_file_dialog_open              ; void gtk_file_dialog_open(GtkFileDialog*, GtkWindow *parent, GCancellable*, GAsyncReadyCallback, gpointer) -- shows the dialog, returns immediately

    mov  rdi, [rbp-8]
    CCALL g_object_unref                     ; drop our reference -- the async op holds its own ref while running, so the dialog object itself stays alive until on_open_finished runs even though we're done with it here

    leave
    ret

; void on_open_finished(GObject *dialog, GAsyncResult *res, gpointer user_data)
; The GAsyncReadyCallback for gtk_file_dialog_open above -- fires once the
; user has picked a file (or cancelled/errored).
on_open_finished:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=the picked GFile* (or NULL)  [rbp-16]=its resolved filesystem path

    ; source (rdi) and res (rsi) are already positioned correctly for the
    ; *_finish(self, result, error) call -- this callback's own incoming
    ; args line up exactly with what gtk_file_dialog_open_finish wants as
    ; its first two arguments, so no register shuffling is needed.
    xor  edx, edx                 ; arg3 = error = NULL, we don't inspect it -- a NULL/error result and a user cancellation both just mean "nothing to do"
    CCALL gtk_file_dialog_open_finish   ; GFile *gtk_file_dialog_open_finish(GtkFileDialog*, GAsyncResult*, GError**) -- rax = the picked file, or NULL
    mov  [rbp-8], rax
    test rax, rax
    jz   .done                    ; cancelled or errored -- nothing to do

    mov  rdi, rax                   ; arg1 = the GFile
    CCALL g_file_get_path             ; gchar *g_file_get_path(GFile*) -- rax = a plain filesystem path string we now own
    mov  [rbp-16], rax

    mov  rdi, [rbp-16]                ; arg = path
    ICALL read_file_to_buffer            ; loads the file's contents into g_buffer

    ; take ownership of the path as the document's new current file --
    ; free whatever the old g_current_path pointed at first, if anything
    mov  rdi, [rel g_current_path]
    test rdi, rdi
    jz   .no_free_old
    CCALL g_free
.no_free_old:
    mov  rax, [rbp-16]                 ; the path we just resolved
    mov  [rel g_current_path], rax      ; now the document's current-file path

    ICALL update_window_title             ; retitle to "<basename> - UnbloatedPad"
    ICALL clear_dirty                      ; freshly-loaded content is not "unsaved changes"

    mov  rdi, [rbp-8]                       ; the GFile object itself
    CCALL g_object_unref                      ; we only needed its path; drop our reference to the GFile now that we have it
.done:
    leave
    ret

; void finish_save_current_path(void)
; Writes g_current_path and clears the unsaved-changes flag -- the shared
; continuation passed to encoding.asm's ensure_encoding_resolved by both
; on_save_activate's fast path and on_save_finished below (by the time
; either runs this, g_current_path already holds the right value in both
; cases), and reused (via its own small wrapper) by unsaved.asm's Save
; response too.
finish_save_current_path:
    push rbp
    mov  rbp, rsp
    mov  rdi, [rel g_current_path]
    ICALL write_buffer_to_file
    ICALL clear_dirty                       ; a successful save clears the unsaved-changes flag (write_buffer_to_file doesn't report failure back to us, so this is optimistic -- same documented behavior as everywhere else this pattern already appears)
    pop  rbp
    ret

; void on_save_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
; File > Save: writes directly to the current file if there is one;
; otherwise behaves exactly like Save As (there's nowhere to "just save" to yet).
on_save_activate:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- either branch below either delegates entirely
    ; (jumping to on_save_as_activate) or hands off to ensure_encoding_resolved

    mov  rax, [rel g_current_path]     ; is there a current file?
    test rax, rax
    jz   .no_path                       ; no -- fall through to Save As below
    lea  rdi, [rel finish_save_current_path]   ; encoding.asm's ensure_encoding_resolved calls this directly (synchronously) if the encoding is already settled, or once the user answers a Convert/Keep-original prompt otherwise
    ICALL ensure_encoding_resolved
    jmp  .done
.no_path:
    ICALL on_save_as_activate      ; rdi/rsi/rdx still hold the original (action, parameter, user_data) args this function was called with -- harmless to forward them, since on_save_as_activate doesn't read them anyway; this is effectively "Save with no current file behaves exactly like Save As"
.done:
    pop  rbp
    ret

; File > Save As: always shows the picker (even if there's already a
; current file -- that's the whole point of "Save As"), async just like
; Open above.
on_save_as_activate:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the GtkFileDialog object

    CCALL gtk_file_dialog_new
    mov  [rbp-8], rax

    lea  rdi, [rel save_dlg_title]  ; arg1 = msgid
    CCALL gettext
    mov  rsi, rax                     ; arg2 = translated title
    mov  rdi, [rbp-8]                    ; arg1 = self
    CCALL gtk_file_dialog_set_title

    mov  rdi, [rbp-8]                  ; arg1 = self
    mov  rsi, [rel g_window]            ; arg2 = parent window
    xor  edx, edx                        ; arg3 = cancellable = NULL
    lea  rcx, [rel on_save_finished]      ; arg4 = callback
    xor  r8, r8                            ; arg5 = user_data = NULL
    CCALL gtk_file_dialog_save               ; void gtk_file_dialog_save(GtkFileDialog*, GtkWindow *parent, GCancellable*, GAsyncReadyCallback, gpointer)

    mov  rdi, [rbp-8]
    CCALL g_object_unref                      ; same reasoning as on_open_activate -- the async op keeps its own ref alive

    leave
    ret

; void on_save_finished(GObject *dialog, GAsyncResult *res, gpointer user_data)
; The GAsyncReadyCallback for gtk_file_dialog_save above.
on_save_finished:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=the picked GFile* (or NULL)  [rbp-16]=its resolved filesystem path

    xor  edx, edx                 ; arg3 = error = NULL, same reasoning as on_open_finished
    CCALL gtk_file_dialog_save_finish   ; GFile *gtk_file_dialog_save_finish(GtkFileDialog*, GAsyncResult*, GError**)
    mov  [rbp-8], rax
    test rax, rax
    jz   .done                    ; cancelled or errored

    mov  rdi, rax                  ; arg1 = the GFile
    CCALL g_file_get_path            ; rax = the chosen path, owned by us
    mov  [rbp-16], rax

    ; take ownership of the path as the document's new current file,
    ; freeing whatever the old one was (if this "Save As" is replacing an
    ; already-saved document's path rather than giving "Untitled" one for
    ; the first time) -- none of this depends on whether the actual write
    ; below happens synchronously or after an encoding prompt
    mov  rdi, [rel g_current_path]
    test rdi, rdi
    jz   .no_free_old
    CCALL g_free
.no_free_old:
    mov  rax, [rbp-16]
    mov  [rel g_current_path], rax

    ICALL update_window_title           ; retitle to the new filename

    mov  rdi, [rbp-8]                       ; the GFile object itself -- we only needed its path, already extracted; safe to drop our reference now regardless of when the write itself happens
    CCALL g_object_unref

    lea  rdi, [rel finish_save_current_path]   ; writes g_current_path (now the new one) and clears the unsaved-changes flag, once the encoding (if ambiguous) is settled
    ICALL ensure_encoding_resolved
.done:
    leave
    ret
