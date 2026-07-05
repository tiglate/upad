; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; encoding.asm -- transcodes a file's bytes to UTF-8 on load if they
; aren't already valid UTF-8, and asks (once, on the first Save/Save As
; after opening such a file) whether to keep writing it back out in its
; original encoding or convert it to UTF-8 going forward.
;
; GtkTextBuffer requires UTF-8 (gtk_text_buffer_set_text asserts on
; anything else, silently doing nothing on a validation failure -- no
; crash, no GError, no signal, just an empty buffer -- which used to be
; this program's entire behavior on a non-UTF-8 file). Source encodings
; are recognized in this order, tracked in g_doc_source_encoding:
;
;   - UTF-16 (LE or BE): detected by its 2-byte byte-order mark (FF FE or
;     FE FF) -- a real, unambiguous signal, unlike guessing an 8-bit
;     charset. This is exactly what Windows Notepad's own "Unicode" save
;     option produces, so it's a common thing to actually run into.
;   - Anything else that isn't valid UTF-8: handed to uchardet (a small
;     statistical charset sniffer, the same one Firefox/LibreOffice use)
;     for a guess, which is then fed straight to g_convert as its
;     from_codeset -- uchardet's whole design goal is returning
;     iconv-compatible names, so no translation table of our own is
;     needed between the two. The guessed name is remembered in
;     g_doc_charset_name (DOC_ENCODING_OTHER), not just a fixed enum
;     value, since it could be any charset iconv knows about. If
;     uchardet has no confident verdict at all (returns ""), or its
;     guess doesn't actually decode, Windows-1252 is the last-resort
;     fallback -- a safe default since it's a strict superset of
;     Latin-1/ISO-8859-1 for every printable character, and is what the
;     overwhelming majority of "old Windows/DOS 8-bit text file" turns
;     out to actually be in practice (also what web browsers default to
;     for undeclared legacy 8-bit text). See CLAUDE.md's Known
;     limitations for what's still not handled (UTF-32, and a build
;     without uchardet-detectable confidence on short/ambiguous files).
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
;
; A correctness note that shaped every g_convert call below: this file
; never uses strlen() on a converted result, only g_convert's own
; bytes_written out-param. UTF-16 text is full of embedded 0x00 bytes --
; every Basic Latin character's high byte is zero -- so strlen() would
; silently truncate at the first one. Legacy 8-bit output could in theory
; contain a genuine embedded NUL too (rare, but possible), so the same
; discipline applies there for consistency even though it isn't the
; common case that would actually hit it.
;
; uchardet_t (opaque, from libuchardet) is a plain C handle, not a
; GObject -- built/torn down with uchardet_new/uchardet_delete, not
; g_object_new/g_object_unref, and none of its calls go through CCALL's
; PLT convention any differently than GTK/GLib's own C ABI calls do.

%include "consts.inc"          ; TRUE/FALSE, DOC_ENCODING_*, CHARSET_NAME_SIZE, ADW_RESPONSE_DESTRUCTIVE (unused here, kept for consistency), G_CONNECT_DEFAULT (unused directly, adw_alert_dialog_choose doesn't need it)
%include "callconv.inc"        ; CCALL/ICALL macros; see its own comment for g_convert's 7th (stack) argument and the indirect-call pattern used below
%include "extern.inc"          ; extern g_utf8_validate/g_convert/uchardet_*/adw_alert_dialog_*/memcpy/g_free/strcmp

global reset_encoding_state         ; called from fileio.asm's on_new_activate, and internally by decode_and_load_into_buffer below
global decode_and_load_into_buffer  ; called from fileio.asm's read_file_to_buffer
global encode_for_save              ; called from fileio.asm's write_buffer_to_file
global ensure_encoding_resolved     ; called from fileio.asm (on_save_activate, on_save_finished) and unsaved.asm's Save response

extern g_window                       ; main.asm -- parent for the encoding-choice dialog
extern g_buffer                        ; main.asm -- decode_and_load_into_buffer's target
extern report_error                     ; errdlg.asm -- shown if even the fallback encodings can't decode/encode
extern strcopy_bounded                   ; fileio.asm -- bounded string copy, reused here to capture uchardet's answer and to seed the Windows-1252 fallback name

section .rodata
    charset_utf8         db "UTF-8", 0
    charset_windows1252  db "WINDOWS-1252", 0
    charset_utf16le      db "UTF-16LE", 0    ; the explicit (not bare "UTF-16") codeset names -- neither strips/adds a BOM itself, which is exactly why we handle the BOM ourselves on both ends
    charset_utf16be      db "UTF-16BE", 0

    heading_str  db "Save in original encoding?", 0  ; i18n:
    body_str     db "This file wasn't opened as UTF-8 text. Choose whether to save it back in its original encoding, or convert the document to UTF-8.", 0  ; i18n:

    ; AdwAlertDialog response IDs (matched via strcmp in on_encoding_response
    ; below) paired with their button labels -- same shape as unsaved.asm's
    ; own alert dialog. The response IDs themselves are internal, never
    ; shown -- only the _lbl_* button labels are user-visible/translatable.
    resp_cancel  db "cancel", 0
    lbl_cancel   db "_Cancel", 0  ; i18n:
    resp_keep    db "keep", 0
    lbl_keep     db "_Keep Original Encoding", 0  ; i18n:
    resp_utf8    db "utf8", 0
    lbl_utf8     db "_Convert to UTF-8", 0  ; i18n:

    err_msg_decode    db "Could not open file", 0  ; i18n:
    err_detail_decode db "This file's contents don't look like valid UTF-8 or UTF-16 text, and uchardet couldn't identify (or guessed wrong about) whatever legacy 8-bit encoding it might be.", 0  ; i18n:
    err_msg_encode    db "Could not save file", 0  ; i18n:
    err_detail_encode db "This document contains characters that can't be converted back to the encoding it was originally opened with. Nothing was saved -- try again and choose to convert to UTF-8 instead.", 0  ; i18n:

section .bss
    align 8
    g_doc_needs_encoding_choice resq 1  ; TRUE if this document was transcoded from a non-UTF-8 encoding on load and Save/Save As haven't asked (and gotten an answer) about it yet this session
    g_doc_source_encoding       resq 1  ; a DOC_ENCODING_* constant: what to transcode back to on save if the user chooses "keep" (DOC_ENCODING_UTF8 for a document that was always plain UTF-8 -- meaning "just write UTF-8", the same as choosing "convert" ever does)
    g_doc_charset_name          resb CHARSET_NAME_SIZE  ; only meaningful when g_doc_source_encoding == DOC_ENCODING_OTHER -- the iconv codeset name uchardet detected (or "WINDOWS-1252", if it had no verdict or its guess didn't decode)
    g_encoding_continue_fn      resq 1  ; stashed across the async prompt below -- whatever the caller wanted to happen once the encoding is settled

section .text

; void reset_encoding_state(void) -- call whenever a document's identity
; changes (New, or the start of every Open/command-line load) so stale
; encoding state from a PREVIOUS document never leaks into the next one.
reset_encoding_state:
    push rbp
    mov  rbp, rsp
    mov  qword [rel g_doc_needs_encoding_choice], FALSE
    mov  qword [rel g_doc_source_encoding], DOC_ENCODING_UTF8
    pop  rbp
    ret

; -------------------------------------------------------------------------
; void decode_and_load_into_buffer(const char *raw, gsize raw_len)
; Checks for a UTF-16 byte-order mark first (an unambiguous signal, unlike
; guessing an 8-bit charset); failing that, validates raw as UTF-8 and
; loads it as-is if it already is (the common case); failing THAT, hands
; the bytes to uchardet and tries whatever it guesses, falling back to
; Windows-1252 if uchardet has no verdict or its guess doesn't actually
; decode (see file header for the full fallback chain). Whichever
; non-UTF-8 path is taken, marks g_doc_needs_encoding_choice so a later
; Save/Save As asks what to do about it. If nothing above can make sense
; of the bytes, reports an error the same way a failed open()/read()
; would and leaves the buffer untouched.
; -------------------------------------------------------------------------
decode_and_load_into_buffer:
    push rbp
    mov  rbp, rsp
    sub  rsp, 80
    ; [rbp-8]=raw  [rbp-16]=raw_len  [rbp-24]=converted UTF-8 text (owned once set, must g_free)  [rbp-32]=its exact length (from bytes_written, NOT strlen -- see file header)  [rbp-40]=the from_codeset chosen by the BOM check below, only used on that path  [rbp-48]=bytes_written out-param scratch for g_convert  [rbp-56]=the uchardet_t handle, only used on the no-BOM/not-UTF-8 path

    mov  [rbp-8], rdi
    mov  [rbp-16], rsi

    ICALL reset_encoding_state       ; every freshly-loaded document starts assuming plain UTF-8; corrected below if it isn't

    ; --- check for a UTF-16 byte-order mark first -- far more reliable than any heuristic ---
    mov  rax, [rbp-16]
    cmp  rax, 2
    jl   .no_bom                     ; too short to hold a 2-byte BOM

    mov  rdi, [rbp-8]
    movzx eax, byte [rdi]
    movzx ecx, byte [rdi+1]
    cmp  al, 0xFF
    jne  .check_utf16be
    cmp  cl, 0xFE
    jne  .no_bom
    mov  qword [rel g_doc_source_encoding], DOC_ENCODING_UTF16LE
    lea  rax, [rel charset_utf16le]
    mov  [rbp-40], rax
    jmp  .decode_utf16
.check_utf16be:
    cmp  al, 0xFE
    jne  .no_bom
    cmp  cl, 0xFF
    jne  .no_bom
    mov  qword [rel g_doc_source_encoding], DOC_ENCODING_UTF16BE
    lea  rax, [rel charset_utf16be]
    mov  [rbp-40], rax
    ; falls through to .decode_utf16

.decode_utf16:
    ; iconv's explicit UTF-16LE/UTF-16BE codecs don't strip a leading BOM
    ; themselves (verified empirically: they decode it as an ordinary
    ; U+FEFF character), so skip the 2 BOM bytes ourselves first
    sub  rsp, 16                        ; g_convert's 7th (stack) argument + padding, see callconv.inc
    mov  qword [rsp], 0                   ; arg7 = error = NULL, not inspected (matches this codebase's convention elsewhere)
    mov  rdi, [rbp-8]
    add  rdi, 2                             ; arg1 = str = raw + 2 (past the BOM)
    mov  rsi, [rbp-16]
    sub  rsi, 2                              ; arg2 = len = raw_len - 2
    lea  rdx, [rel charset_utf8]               ; arg3 = to_codeset
    mov  rcx, [rbp-40]                            ; arg4 = from_codeset (UTF-16LE or UTF-16BE, chosen above)
    xor  r8, r8                                     ; arg5 = bytes_read = NULL (unused)
    lea  r9, [rbp-48]                                 ; arg6 = &bytes_written
    CCALL g_convert                                     ; gchar *g_convert(const gchar*, gssize, const gchar*, const gchar*, gsize*, gsize*, GError**) -- rax = new UTF-8 string, ours to free; or NULL on failure
    add  rsp, 16
    jmp  .have_conversion_result

.no_bom:
    ; --- no recognized BOM -- try plain UTF-8 first --------------------------
    mov  rdi, [rbp-8]                  ; arg1 = str
    mov  rsi, [rbp-16]                   ; arg2 = max_len
    xor  edx, edx                          ; arg3 = end = NULL (not needed)
    CCALL g_utf8_validate                     ; gboolean g_utf8_validate(const gchar*, gssize, const gchar**)
    test eax, eax
    jnz  .already_utf8

    ; --- not valid UTF-8 either -- ask uchardet what it thinks this is --------
    CCALL uchardet_new                    ; uchardet_t uchardet_new(void) -- rax = a new detector handle, ours to delete
    mov  [rbp-56], rax

    mov  rdi, [rbp-56]              ; arg1 = ud
    mov  rsi, [rbp-8]                 ; arg2 = data = raw
    mov  rdx, [rbp-16]                  ; arg3 = len = raw_len
    CCALL uchardet_handle_data              ; int uchardet_handle_data(uchardet_t, const char*, size_t) -- return value not checked: an internal failure here just means uchardet_get_charset below comes back "" the same as "no verdict", handled identically either way

    mov  rdi, [rbp-56]
    CCALL uchardet_data_end                   ; void uchardet_data_end(uchardet_t) -- tells it there's no more data coming, so it commits to its best guess

    mov  rdi, [rbp-56]
    CCALL uchardet_get_charset                 ; const char *uchardet_get_charset(uchardet_t) -- borrowed pointer, valid only until uchardet_delete below (or "" -- not NULL -- if it never reached a verdict)
    lea  rdi, [rel g_doc_charset_name]            ; copy it into OUR OWN buffer right now, while it's still valid -- uchardet_delete invalidates it
    mov  rsi, rax
    mov  rdx, CHARSET_NAME_SIZE
    ICALL strcopy_bounded                            ; NUL-terminates; a zero-length ("") source copies cleanly to an empty g_doc_charset_name too

    mov  rdi, [rbp-56]
    CCALL uchardet_delete                        ; done with the detector now that its answer has been copied out

    movzx eax, byte [rel g_doc_charset_name]  ; peek at the first byte -- "" (no verdict) means uchardet never became confident enough to name anything
    test al, al
    jnz  .try_detected_charset

    ; --- no verdict at all -- go straight to the Windows-1252 fallback --------
    lea  rdi, [rel charset_windows1252]
    lea  rsi, [rel g_doc_charset_name]
    mov  rdx, CHARSET_NAME_SIZE
    ICALL strcopy_bounded

.try_detected_charset:
    mov  qword [rel g_doc_source_encoding], DOC_ENCODING_OTHER
    sub  rsp, 16
    mov  qword [rsp], 0                   ; arg7 = error = NULL
    mov  rdi, [rbp-8]                       ; arg1 = str
    mov  rsi, [rbp-16]                        ; arg2 = len
    lea  rdx, [rel charset_utf8]                ; arg3 = to_codeset = "UTF-8"
    lea  rcx, [rel g_doc_charset_name]            ; arg4 = from_codeset -- uchardet's guess, or the Windows-1252 fallback set above
    xor  r8, r8                                     ; arg5 = bytes_read = NULL
    lea  r9, [rbp-48]                                 ; arg6 = &bytes_written
    CCALL g_convert
    add  rsp, 16
    test rax, rax
    jnz  .have_conversion_result             ; success -- join the shared tail below

    ; --- that guess didn't actually decode -- if it wasn't already Windows-1252, try that as the last resort ---
    lea  rdi, [rel g_doc_charset_name]
    lea  rsi, [rel charset_windows1252]
    CCALL strcmp
    test eax, eax
    jnz  .try_windows1252_fallback   ; different name -- worth a second attempt
    xor  eax, eax                     ; already was Windows-1252 -- no different fallback left; rax=NULL so .have_conversion_result reports .decode_failed
    jmp  .have_conversion_result

.try_windows1252_fallback:
    lea  rdi, [rel charset_windows1252]
    lea  rsi, [rel g_doc_charset_name]
    mov  rdx, CHARSET_NAME_SIZE
    ICALL strcopy_bounded

    sub  rsp, 16
    mov  qword [rsp], 0                   ; arg7 = error = NULL
    mov  rdi, [rbp-8]
    mov  rsi, [rbp-16]
    lea  rdx, [rel charset_utf8]
    lea  rcx, [rel g_doc_charset_name]        ; now "WINDOWS-1252"
    xor  r8, r8
    lea  r9, [rbp-48]
    CCALL g_convert
    add  rsp, 16
    ; falls through to .have_conversion_result -- success or final failure both handled there

.have_conversion_result:
    test rax, rax
    jz   .decode_failed
    mov  [rbp-24], rax
    mov  rax, [rbp-48]
    mov  [rbp-32], rax                   ; the exact converted length, from bytes_written above

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
    lea  rdi, [rel err_msg_decode]  ; arg1 = msgid
    CCALL gettext
    mov  [rbp-24], rax                ; stash the translated op_summary -- reusing this slot since the "converted text" it normally holds is never set on this failure path
    lea  rdi, [rel err_detail_decode]
    CCALL gettext
    mov  rsi, rax               ; arg2 = translated detail
    mov  rdi, [rbp-24]            ; arg1 = translated op_summary
    ICALL report_error                  ; errdlg.asm
.done:
    leave
    ret

; -------------------------------------------------------------------------
; gboolean encode_for_save(char *utf8_text, gsize utf8_len, char **out_text, gsize *out_len)
; Takes ownership of utf8_text (may free it). Converts back to whatever
; g_doc_source_encoding says the document's original encoding was:
; DOC_ENCODING_UTF8 (the common case: no ambiguity, or the user already
; chose to convert) just passes utf8_text/utf8_len straight through
; unchanged. DOC_ENCODING_OTHER/UTF16LE/UTF16BE convert instead (the
; UTF-16 cases via convert_utf8_to_utf16_with_bom below, which also
; restores the 2-byte BOM so the file round-trips byte-for-byte;
; DOC_ENCODING_OTHER converts to whatever iconv codeset name is
; currently in g_doc_charset_name -- uchardet's detected guess, or the
; Windows-1252 fallback, whichever decode_and_load_into_buffer settled on).
;
; On success, *out_text/*out_len point at a buffer the CALLER now owns
; (must g_free exactly once) -- either utf8_text itself unchanged (the
; UTF-8 case) or a new buffer (any other case, with utf8_text already
; freed). Returns FALSE (utf8_text already freed, an error already
; reported) if a conversion was needed but failed -- e.g. a character
; with no representation in that charset, such as an emoji or CJK
; character typed into a document that started out as a legacy
; Western-European file. The caller should skip writing anything:
; there's nothing left to write, and writing partial/wrong bytes would
; be worse than not writing at all.
; -------------------------------------------------------------------------
encode_for_save:
    push rbp
    mov  rbp, rsp
    sub  rsp, 64                  ; [rbp-8]=utf8_text  [rbp-16]=utf8_len  [rbp-24]=out_text (the caller's out-param address)  [rbp-32]=out_len (ditto)  [rbp-40]=the g_convert result  [rbp-48]=bytes_written out-param scratch -- both only used on the DOC_ENCODING_OTHER path

    mov  [rbp-8], rdi
    mov  [rbp-16], rsi
    mov  [rbp-24], rdx
    mov  [rbp-32], rcx

    mov  rax, [rel g_doc_source_encoding]
    cmp  rax, DOC_ENCODING_OTHER
    je   .convert_other
    cmp  rax, DOC_ENCODING_UTF16LE
    je   .convert_utf16le
    cmp  rax, DOC_ENCODING_UTF16BE
    je   .convert_utf16be

    ; --- DOC_ENCODING_UTF8 (the common case): no conversion needed, pass straight through ---
    mov  rax, [rbp-24]                ; *out_text = utf8_text (unchanged)
    mov  rdx, [rbp-8]
    mov  [rax], rdx
    mov  rax, [rbp-32]                ; *out_len = utf8_len (unchanged)
    mov  rdx, [rbp-16]
    mov  [rax], rdx
    mov  eax, TRUE
    leave
    ret

.convert_other:
    sub  rsp, 16                        ; g_convert's 7th (stack) argument + padding
    mov  qword [rsp], 0                   ; arg7 = error = NULL
    mov  rdi, [rbp-8]                       ; arg1 = str = utf8_text
    mov  rsi, [rbp-16]                        ; arg2 = len = utf8_len
    lea  rdx, [rel g_doc_charset_name]          ; arg3 = to_codeset -- whatever decode_and_load_into_buffer settled on (uchardet's guess, or Windows-1252)
    lea  rcx, [rel charset_utf8]                  ; arg4 = from_codeset
    xor  r8, r8                                     ; arg5 = bytes_read = NULL
    lea  r9, [rbp-48]                                 ; arg6 = &bytes_written -- see file header for why not strlen()
    CCALL g_convert
    add  rsp, 16
    mov  [rbp-40], rax                  ; stash the (possibly NULL) converted pointer

    mov  rdi, [rbp-8]                     ; the ORIGINAL utf8_text -- done with it either way, free it now
    CCALL g_free

    mov  rax, [rbp-40]
    test rax, rax
    jz   .convert_failed

    mov  rdx, [rbp-24]                ; *out_text = the new text (no BOM for Windows-1252)
    mov  [rdx], rax
    mov  rdx, [rbp-32]                  ; *out_len = the exact converted length, from bytes_written above
    mov  rax, [rbp-48]
    mov  [rdx], rax
    mov  eax, TRUE
    leave
    ret

.convert_utf16le:
    xor  r8d, r8d                        ; arg5 = is_big_endian = FALSE
    jmp  .convert_utf16_dispatch
.convert_utf16be:
    mov  r8d, TRUE                        ; arg5 = is_big_endian = TRUE
.convert_utf16_dispatch:
    mov  rdi, [rbp-8]                       ; arg1 = utf8_text
    mov  rsi, [rbp-16]                        ; arg2 = utf8_len
    mov  rdx, [rbp-24]                          ; arg3 = out_text
    mov  rcx, [rbp-32]                            ; arg4 = out_len
    ; arg5 (is_big_endian) already set by whichever branch above
    ICALL convert_utf8_to_utf16_with_bom            ; below -- propagates its own TRUE/FALSE return straight through as ours
    leave
    ret

.convert_failed:
    lea  rdi, [rel err_msg_encode]  ; arg1 = msgid
    CCALL gettext
    mov  [rbp-8], rax                 ; stash the translated op_summary -- reusing this slot, utf8_text (its usual contents) has already been freed above on this path
    lea  rdi, [rel err_detail_encode]
    CCALL gettext
    mov  rsi, rax               ; arg2 = translated detail
    mov  rdi, [rbp-8]              ; arg1 = translated op_summary
    ICALL report_error                  ; errdlg.asm
    xor  eax, eax
    leave
    ret

; -------------------------------------------------------------------------
; gboolean convert_utf8_to_utf16_with_bom(char *utf8_text, gsize utf8_len, char **out_text, gsize *out_len, int is_big_endian)
; Shared helper behind encode_for_save's UTF-16LE/UTF-16BE branches.
; Converts utf8_text to raw UTF-16 (the requested endianness, via
; g_convert with the explicit *LE/*BE codeset name, which never adds a
; BOM of its own), then g_malloc's a new buffer 2 bytes larger and writes
; the matching 2-byte BOM in front of the converted data, so the file
; this becomes round-trips with the same BOM the original had. Same
; ownership contract as encode_for_save itself.
; -------------------------------------------------------------------------
convert_utf8_to_utf16_with_bom:
    push rbp
    mov  rbp, rsp
    sub  rsp, 80
    ; [rbp-8]=utf8_text  [rbp-16]=utf8_len  [rbp-24]=out_text  [rbp-32]=out_len  [rbp-40]=is_big_endian
    ; [rbp-48]=to_codeset (chosen below)  [rbp-56]=g_convert's result (raw UTF-16, no BOM, owned)
    ; [rbp-64]=its exact byte length (from bytes_written)  [rbp-72]=the final BOM+data buffer (owned)

    mov  [rbp-8], rdi
    mov  [rbp-16], rsi
    mov  [rbp-24], rdx
    mov  [rbp-32], rcx
    mov  [rbp-40], r8

    mov  rax, [rbp-40]
    test rax, rax
    jz   .use_le
    lea  rax, [rel charset_utf16be]
    mov  [rbp-48], rax
    jmp  .have_codeset
.use_le:
    lea  rax, [rel charset_utf16le]
    mov  [rbp-48], rax
.have_codeset:

    sub  rsp, 16                        ; g_convert's 7th (stack) argument + padding
    mov  qword [rsp], 0                   ; arg7 = error = NULL
    mov  rdi, [rbp-8]                       ; arg1 = str = utf8_text
    mov  rsi, [rbp-16]                        ; arg2 = len = utf8_len
    mov  rdx, [rbp-48]                          ; arg3 = to_codeset (UTF-16LE or UTF-16BE)
    lea  rcx, [rel charset_utf8]                  ; arg4 = from_codeset
    xor  r8, r8                                     ; arg5 = bytes_read = NULL
    lea  r9, [rbp-64]                                 ; arg6 = &bytes_written -- MUST use this, not strlen: UTF-16 output for ordinary Latin text is full of embedded 0x00 bytes, which strlen would stop at (see file header)
    CCALL g_convert
    add  rsp, 16
    mov  [rbp-56], rax                  ; stash the (possibly NULL) result

    mov  rdi, [rbp-8]                     ; the ORIGINAL utf8_text -- done with it either way, free it now
    CCALL g_free

    mov  rax, [rbp-56]
    test rax, rax
    jz   .convert_failed

    ; --- g_malloc a buffer 2 bytes bigger, for the BOM we're about to add ---
    mov  rax, [rbp-64]                 ; the exact converted length
    add  rax, 2
    mov  rdi, rax
    CCALL g_malloc                        ; gpointer g_malloc(gsize) -- aborts on OOM, no failure check needed (same reasoning as elsewhere in this codebase)
    mov  [rbp-72], rax

    ; --- write the 2-byte BOM, matching whichever endianness we converted to ---
    mov  rdi, [rbp-72]
    mov  rax, [rbp-40]                    ; is_big_endian
    test rax, rax
    jz   .write_le_bom
    mov  byte [rdi], 0xFE                    ; UTF-16BE BOM: FE FF
    mov  byte [rdi+1], 0xFF
    jmp  .bom_written
.write_le_bom:
    mov  byte [rdi], 0xFF                    ; UTF-16LE BOM: FF FE
    mov  byte [rdi+1], 0xFE
.bom_written:

    ; --- copy the converted UTF-16 bytes right after the BOM ---
    mov  rdi, [rbp-72]
    add  rdi, 2                              ; arg1 = dest = combined buffer, past the BOM
    mov  rsi, [rbp-56]                         ; arg2 = src = the converted UTF-16 bytes
    mov  rdx, [rbp-64]                           ; arg3 = n = their exact length
    CCALL memcpy                                    ; void *memcpy(void *dest, const void *src, size_t n)

    mov  rdi, [rbp-56]                    ; done with the (BOM-less) converted buffer now that it's been copied
    CCALL g_free

    mov  rdx, [rbp-24]                    ; *out_text = the combined (BOM + data) buffer
    mov  rax, [rbp-72]
    mov  [rdx], rax
    mov  rdx, [rbp-32]                       ; *out_len = converted length + 2 (the BOM)
    mov  rax, [rbp-64]
    add  rax, 2
    mov  [rdx], rax
    mov  eax, TRUE
    leave
    ret

.convert_failed:
    lea  rdi, [rel err_msg_encode]  ; arg1 = msgid
    CCALL gettext
    mov  [rbp-8], rax                 ; stash the translated op_summary -- reusing this slot, utf8_text (its usual contents) has already been freed above on this path
    lea  rdi, [rel err_detail_encode]
    CCALL gettext
    mov  rsi, rax               ; arg2 = translated detail
    mov  rdi, [rbp-8]              ; arg1 = translated op_summary
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

    lea  rdi, [rel heading_str]  ; arg1 = msgid
    CCALL gettext
    mov  [rbp-8], rax             ; stash the translated heading across the next gettext call
    lea  rdi, [rel body_str]
    CCALL gettext
    mov  rsi, rax                  ; arg2 = translated body
    mov  rdi, [rbp-8]                ; arg1 = translated heading
    CCALL adw_alert_dialog_new                ; AdwAlertDialog *adw_alert_dialog_new(const char *heading, const char *body)
    mov  [rbp-8], rax                            ; now the dialog itself -- the translated heading was only needed for this one call

    lea  rdi, [rel lbl_cancel]  ; arg1 = msgid -- response IDs (resp_cancel/keep/utf8) are internal, never shown, so only the label needs translating
    CCALL gettext
    mov  rdx, rax                 ; arg3 = translated label
    mov  rdi, [rbp-8]               ; arg1 = dialog
    lea  rsi, [rel resp_cancel]       ; arg2 = response id
    CCALL adw_alert_dialog_add_response
    lea  rdi, [rel lbl_keep]
    CCALL gettext
    mov  rdx, rax
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_keep]
    CCALL adw_alert_dialog_add_response
    lea  rdi, [rel lbl_utf8]
    CCALL gettext
    mov  rdx, rax
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_utf8]
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
    jz   .resolved                 ; "keep" -- leave g_doc_source_encoding exactly as decode_and_load_into_buffer set it
    mov  qword [rel g_doc_source_encoding], DOC_ENCODING_UTF8   ; the only other non-cancel response is "utf8" -- convert going forward
.resolved:
    mov  qword [rel g_doc_needs_encoding_choice], FALSE   ; resolved -- don't ask again this session
    mov  r10, [rel g_encoding_continue_fn]                  ; loaded into r10, not rax/rcx -- the register about to be zeroed (matching ICALL's own convention, see ensure_encoding_resolved's own indirect call) must not be the one holding the call target
    xor  eax, eax
    call r10
.done:
    leave
    ret
