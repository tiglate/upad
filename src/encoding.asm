; encoding.asm -- transcodes a file's bytes to UTF-8 on load if they
; aren't already valid UTF-8, and asks (once, on the first Save/Save As
; after opening such a file) whether to keep writing it back out in its
; original encoding or convert it to UTF-8 going forward.
;
; GtkTextBuffer requires UTF-8 (gtk_text_buffer_set_text asserts on
; anything else, silently doing nothing on a validation failure -- no
; crash, no GError, no signal, just an empty buffer -- which used to be
; this program's entire behavior on a non-UTF-8 file). Real charset
; auto-detection (distinguishing Windows-1252 from Latin-1, Shift-JIS,
; KOI8-R, ...) is a much bigger undertaking than this handles: on any
; UTF-8 validation failure, this always assumes Windows-1252 -- a safe
; default, since it's a strict superset of Latin-1/ISO-8859-1 for every
; printable character, and is what the overwhelming majority of "old
; Windows/DOS text file that isn't UTF-8" turns out to actually be in
; practice (this is also what web browsers default to for undeclared
; legacy 8-bit text). See CLAUDE.md's Known limitations.
;
; The two entry points fileio.asm calls:
;   decode_and_load_into_buffer(raw, raw_len) -- on Open/command-line load
;   encode_for_save(utf8_text, utf8_len, &out_text, &out_len) -- on Save
;
; Save/Save As don't just silently pick an encoding, though -- the first
; time either is attempted on a document that was transcoded on load,
; ensure_encoding_resolved shows a Convert-to-UTF-8/Keep-original/Cancel
; prompt and defers the actual write (via a caller-supplied continuation
; function pointer -- see fileio.asm's finish_save_current_path and
; unsaved.asm's finish_save_and_resume_pending) until it's answered. The
; answer is remembered for the rest of that document's session, so later
; saves don't ask again.

%include "consts.inc"          ; TRUE/FALSE, ADW_RESPONSE_DESTRUCTIVE (unused here, kept for consistency), G_CONNECT_DEFAULT (unused directly, adw_alert_dialog_choose doesn't need it)
%include "callconv.inc"        ; CCALL/ICALL macros; see its own comment for g_convert's 7th (stack) argument and the indirect-call pattern used below
%include "extern.inc"          ; extern g_utf8_validate/g_convert/adw_alert_dialog_*/strlen/strcmp/g_free

global reset_encoding_state         ; called from fileio.asm's on_new_activate, and internally by decode_and_load_into_buffer below
global decode_and_load_into_buffer  ; called from fileio.asm's read_file_to_buffer
global encode_for_save              ; called from fileio.asm's write_buffer_to_file
global ensure_encoding_resolved     ; called from fileio.asm (on_save_activate, on_save_finished) and unsaved.asm's Save response

extern g_window                       ; main.asm -- parent for the encoding-choice dialog
extern g_buffer                        ; main.asm -- decode_and_load_into_buffer's target
extern report_error                     ; errdlg.asm -- shown if even the Windows-1252 fallback can't decode/encode

section .rodata
    charset_utf8         db "UTF-8", 0
    charset_windows1252  db "WINDOWS-1252", 0

    heading_str  db "Save in original encoding?", 0
    body_str     db "This file was opened from a non-UTF-8 encoding (Windows-1252) and converted for editing. Choose whether to save it back in that original encoding, or convert the document to UTF-8.", 0

    ; AdwAlertDialog response IDs (matched via strcmp in on_encoding_response
    ; below) paired with their button labels -- same shape as unsaved.asm's
    ; own alert dialog.
    resp_cancel  db "cancel", 0
    lbl_cancel   db "_Cancel", 0
    resp_keep    db "keep", 0
    lbl_keep     db "_Keep Original Encoding", 0
    resp_utf8    db "utf8", 0
    lbl_utf8     db "_Convert to UTF-8", 0

    err_msg_decode    db "Could not open file", 0
    err_detail_decode db "This file's contents don't look like valid UTF-8 or Windows-1252 text.", 0
    err_msg_encode    db "Could not save file", 0
    err_detail_encode db "This document contains characters that don't exist in the Windows-1252 encoding it was opened with. Nothing was saved -- try again and choose to convert to UTF-8 instead.", 0

section .bss
    align 8
    g_doc_needs_encoding_choice resq 1  ; TRUE if this document was transcoded from a non-UTF-8 encoding on load and Save/Save As haven't asked (and gotten an answer) about it yet this session
    g_doc_keep_native_encoding  resq 1  ; once resolved (or for a document that was always plain UTF-8, permanently FALSE): TRUE = write back out as Windows-1252 on save, FALSE = write UTF-8
    g_encoding_continue_fn      resq 1  ; stashed across the async prompt below -- whatever the caller wanted to happen once the encoding is settled

section .text

; void reset_encoding_state(void) -- call whenever a document's identity
; changes (New, or the start of every Open/command-line load) so stale
; encoding state from a PREVIOUS document never leaks into the next one.
reset_encoding_state:
    push rbp
    mov  rbp, rsp
    mov  qword [rel g_doc_needs_encoding_choice], FALSE
    mov  qword [rel g_doc_keep_native_encoding], FALSE
    pop  rbp
    ret

; -------------------------------------------------------------------------
; void decode_and_load_into_buffer(const char *raw, gsize raw_len)
; Validates raw as UTF-8; if it already is, loads it into g_buffer as-is
; (the common case, and the only thing this program did before this
; file existed). If not, transcodes it from Windows-1252 (see file header
; for why that specific fallback) and marks g_doc_needs_encoding_choice so
; a later Save/Save As asks what to do about it. If even that fallback
; can't make sense of the bytes (only happens for genuinely non-text/
; binary data), reports an error the same way a failed open()/read()
; would and leaves the buffer untouched.
; -------------------------------------------------------------------------
decode_and_load_into_buffer:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48                  ; [rbp-8]=raw  [rbp-16]=raw_len  [rbp-24]=converted UTF-8 text (only used on the non-UTF-8 path -- owned, must g_free)  [rbp-32]=its length

    mov  [rbp-8], rdi
    mov  [rbp-16], rsi

    ICALL reset_encoding_state       ; every freshly-loaded document starts assuming plain UTF-8; corrected below if it isn't

    mov  rdi, [rbp-8]                  ; arg1 = str
    mov  rsi, [rbp-16]                   ; arg2 = max_len
    xor  edx, edx                          ; arg3 = end = NULL (not needed)
    CCALL g_utf8_validate                     ; gboolean g_utf8_validate(const gchar*, gssize, const gchar**)
    test eax, eax
    jnz  .already_utf8

    ; --- not valid UTF-8 -- try Windows-1252 --------------------------------
    sub  rsp, 16                        ; g_convert's 7th (stack) argument + padding, see callconv.inc
    mov  qword [rsp], 0                   ; arg7 = error = NULL, not inspected (matches this codebase's convention elsewhere)
    mov  rdi, [rbp-8]                       ; arg1 = str
    mov  rsi, [rbp-16]                        ; arg2 = len
    lea  rdx, [rel charset_utf8]                ; arg3 = to_codeset = "UTF-8"
    lea  rcx, [rel charset_windows1252]           ; arg4 = from_codeset = "WINDOWS-1252"
    xor  r8, r8                                     ; arg5 = bytes_read = NULL (optional out-param, unused)
    xor  r9, r9                                       ; arg6 = bytes_written = NULL (optional out-param -- strlen() the NUL-terminated result instead)
    CCALL g_convert                                     ; gchar *g_convert(const gchar*, gssize, const gchar*, const gchar*, gsize*, gsize*, GError**) -- rax = new UTF-8 string, NUL-terminated, ours to free; or NULL on failure
    add  rsp, 16

    test rax, rax
    jz   .decode_failed
    mov  [rbp-24], rax

    mov  rdi, rax                    ; the converted string
    CCALL strlen                        ; size_t strlen(const char*)
    mov  [rbp-32], rax

    mov  qword [rel g_doc_needs_encoding_choice], TRUE   ; ask, later, whether to keep this encoding or convert on save

    mov  rdi, [rel g_buffer]
    mov  rsi, [rbp-24]
    mov  rdx, [rbp-32]
    CCALL gtk_text_buffer_set_text

    mov  rdi, [rbp-24]
    CCALL g_free
    jmp  .done

.already_utf8:
    mov  rdi, [rel g_buffer]
    mov  rsi, [rbp-8]
    mov  rdx, [rbp-16]
    CCALL gtk_text_buffer_set_text
    jmp  .done

.decode_failed:
    lea  rdi, [rel err_msg_decode]
    lea  rsi, [rel err_detail_decode]
    ICALL report_error                  ; errdlg.asm
.done:
    leave
    ret

; -------------------------------------------------------------------------
; gboolean encode_for_save(char *utf8_text, gsize utf8_len, char **out_text, gsize *out_len)
; Takes ownership of utf8_text (may free it). If g_doc_keep_native_encoding
; is FALSE (the common case: no ambiguity, or the user already chose to
; convert), *out_text/*out_len are just utf8_text/utf8_len unchanged -- the
; caller still owns exactly one buffer to free when done, same as always.
;
; If TRUE, converts utf8_text to Windows-1252 instead: on success,
; utf8_text is freed HERE and *out_text/*out_len point at a NEW buffer the
; caller now owns instead. On failure (some character in the document has
; no Windows-1252 representation -- e.g. an emoji or CJK character typed
; into a document that started out as a legacy Western-European file),
; utf8_text is ALSO freed here, an error is reported, and this returns
; FALSE -- the caller should skip writing anything: there's nothing left
; to write, and writing partial/wrong bytes would be worse than not
; writing at all.
; -------------------------------------------------------------------------
encode_for_save:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48                  ; [rbp-8]=utf8_text  [rbp-16]=utf8_len  [rbp-24]=out_text (the caller's out-param address)  [rbp-32]=out_len (ditto)  [rbp-40]=the g_convert result, only used on the conversion path

    mov  [rbp-8], rdi
    mov  [rbp-16], rsi
    mov  [rbp-24], rdx
    mov  [rbp-32], rcx

    mov  rax, [rel g_doc_keep_native_encoding]
    test rax, rax
    jnz  .convert

    ; --- common case: no native-encoding conversion needed, pass straight through ---
    mov  rax, [rbp-24]                ; *out_text = utf8_text (unchanged)
    mov  rdx, [rbp-8]
    mov  [rax], rdx
    mov  rax, [rbp-32]                ; *out_len = utf8_len (unchanged)
    mov  rdx, [rbp-16]
    mov  [rax], rdx
    mov  eax, TRUE
    leave
    ret

.convert:
    sub  rsp, 16                        ; g_convert's 7th (stack) argument + padding
    mov  qword [rsp], 0                   ; arg7 = error = NULL
    mov  rdi, [rbp-8]                       ; arg1 = str = utf8_text
    mov  rsi, [rbp-16]                        ; arg2 = len = utf8_len
    lea  rdx, [rel charset_windows1252]         ; arg3 = to_codeset
    lea  rcx, [rel charset_utf8]                  ; arg4 = from_codeset
    xor  r8, r8                                     ; arg5 = bytes_read = NULL
    xor  r9, r9                                       ; arg6 = bytes_written = NULL
    CCALL g_convert
    add  rsp, 16
    mov  [rbp-40], rax                  ; stash the (possibly NULL) converted pointer

    mov  rdi, [rbp-8]                     ; the ORIGINAL utf8_text -- done with it either way, free it now
    CCALL g_free

    mov  rax, [rbp-40]
    test rax, rax
    jz   .convert_failed

    mov  rdi, rax
    CCALL strlen
    mov  rdx, [rbp-32]              ; *out_len = strlen(new text)
    mov  [rdx], rax
    mov  rdx, [rbp-24]                ; *out_text = the new text
    mov  rax, [rbp-40]
    mov  [rdx], rax
    mov  eax, TRUE
    leave
    ret

.convert_failed:
    lea  rdi, [rel err_msg_encode]
    lea  rsi, [rel err_detail_encode]
    ICALL report_error                  ; errdlg.asm
    xor  eax, eax
    leave
    ret

; -------------------------------------------------------------------------
; void ensure_encoding_resolved(void (*continue_fn)(void))
; If the current document's encoding is already settled (either it was
; plain UTF-8 all along, or a previous Save/Save As this session already
; asked and got an answer), calls continue_fn() immediately. Otherwise
; shows a Convert-to-UTF-8/Keep-original-encoding/Cancel prompt and calls
; continue_fn() from its response callback once answered (or never, if
; cancelled) -- same async-gate shape as unsaved.asm's request_close.
; -------------------------------------------------------------------------
ensure_encoding_resolved:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the AdwAlertDialog we build, only used on the "ask" branch

    mov  rax, [rel g_doc_needs_encoding_choice]
    test rax, rax
    jnz  .prompt
    xor  eax, eax                   ; already resolved -- run the continuation right now. This is an indirect call through the register holding it (one of our own functions, just reached via a pointer instead of by name, so neither CCALL nor ICALL -- both take a symbol -- apply); zeroing AL first anyway just to match ICALL's own convention, though it's not load-bearing for a call to one of our own non-variadic functions
    call rdi
    leave
    ret

.prompt:
    mov  [rel g_encoding_continue_fn], rdi   ; remember it for on_encoding_response, below

    lea  rdi, [rel heading_str]
    lea  rsi, [rel body_str]
    CCALL adw_alert_dialog_new                ; AdwAlertDialog *adw_alert_dialog_new(const char *heading, const char *body)
    mov  [rbp-8], rax

    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_cancel]
    lea  rdx, [rel lbl_cancel]
    CCALL adw_alert_dialog_add_response
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_keep]
    lea  rdx, [rel lbl_keep]
    CCALL adw_alert_dialog_add_response
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_utf8]
    lea  rdx, [rel lbl_utf8]
    CCALL adw_alert_dialog_add_response

    ; "Convert to UTF-8" is the safer/more portable default -- what pressing Enter activates
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_utf8]
    CCALL adw_alert_dialog_set_default_response

    ; Escape / the dialog's own close affordance should behave exactly like Cancel
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_cancel]
    CCALL adw_alert_dialog_set_close_response

    mov  rdi, [rbp-8]                      ; arg1 = self
    mov  rsi, [rel g_window]                 ; arg2 = parent
    xor  edx, edx                              ; arg3 = cancellable = NULL
    lea  rcx, [rel on_encoding_response]         ; arg4 = callback
    xor  r8, r8                                    ; arg5 = user_data = NULL
    CCALL adw_alert_dialog_choose                     ; shows it (async), returns immediately

    leave
    ret

; void on_encoding_response(GObject *dialog, GAsyncResult *res, gpointer user_data)
; The GAsyncReadyCallback for adw_alert_dialog_choose above.
on_encoding_response:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the response id string

    ; dialog (rdi) and res (rsi) already positioned for *_finish(self, result)
    CCALL adw_alert_dialog_choose_finish   ; const char *adw_alert_dialog_choose_finish(AdwAlertDialog*, GAsyncResult*)
    mov  [rbp-8], rax

    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_cancel]
    CCALL strcmp
    test eax, eax
    jz   .done                  ; cancelled -- leave everything exactly as it was, don't run the continuation

    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_keep]
    CCALL strcmp
    test eax, eax
    jnz  .use_utf8
    mov  qword [rel g_doc_keep_native_encoding], TRUE
    jmp  .resolved
.use_utf8:
    mov  qword [rel g_doc_keep_native_encoding], FALSE
.resolved:
    mov  qword [rel g_doc_needs_encoding_choice], FALSE   ; resolved -- don't ask again this session
    mov  r10, [rel g_encoding_continue_fn]                  ; loaded into r10, not rax/rcx -- the register about to be zeroed (matching ICALL's own convention, see ensure_encoding_resolved's own indirect call) must not be the one holding the call target
    xor  eax, eax
    call r10
.done:
    leave
    ret
