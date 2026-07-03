; unsaved.asm -- tracks whether the buffer has unsaved changes and, when
; it does, interposes an AdwAlertDialog (Save/Discard/Cancel) in front of
; New, Open, and Quit (both the menu items and the window's own titlebar
; close button) before letting any of them actually proceed.
;
; New/Open/Quit's real implementations (on_new_activate/on_open_activate
; in fileio.asm, on_quit_activate in actions.asm) are unchanged and still
; do the actual work -- this file only decides *whether* and *when* to
; call them, via request_close()/perform_pending(). The core idea: every
; entry point that might discard unsaved work (on_new_requested,
; on_open_requested, on_quit_requested, on_window_close_request) doesn't
; act directly -- it records WHICH action it wants (a PENDING_* constant,
; in g_pending_action) and calls request_close(), which either runs it
; immediately (buffer is clean) or shows the prompt and lets
; on_unsaved_response decide once the user answers.
;
; Known scope limit: if the user picks "Save" from the prompt and there is
; no current file yet, saving itself needs its own dialog (Save As, which
; is async). Rather than chain a continuation through that second async
; step, the pending New/Open/Quit is simply dropped in that one case --
; the user saves, then re-issues New/Open/Quit themselves, now with
; nothing unsaved to prompt about.

%include "consts.inc"          ; PENDING_NONE/PENDING_NEW/PENDING_OPEN/PENDING_QUIT, ADW_RESPONSE_DESTRUCTIVE, G_CONNECT_DEFAULT, TRUE/FALSE
%include "callconv.inc"        ; CCALL/ICALL macros
%include "extern.inc"          ; extern declarations for every GTK/GLib/libadwaita/libc call used below

global mark_dirty                ; called by on_buffer_changed below, and (indirectly documented) nowhere else -- the buffer's own "changed" signal is the only thing that should ever mark it dirty
global clear_dirty               ; called from fileio.asm after every successful New/Open/Save, and from this file's own on_unsaved_response after a successful Save-from-prompt
global setup_unsaved_tracking    ; called once from window.asm, after g_window/g_buffer both exist
global on_new_requested          ; registered in actions.asm's win_actions table IN PLACE OF fileio.asm's on_new_activate
global on_open_requested         ; same, in place of on_open_activate
global on_quit_requested         ; registered in actions.asm's app_actions table in place of calling on_quit_activate directly

extern g_window                   ; main.asm -- parent for the alert dialog, and the window whose close-request we intercept
extern g_buffer                    ; main.asm -- whose "changed" signal drives mark_dirty
extern g_current_path               ; fileio.asm -- read here to decide "Save" vs "Save As" when the prompt's Save response is chosen
extern on_new_activate               ; fileio.asm -- the REAL New implementation, called once request_close has decided it's safe
extern on_open_activate              ; fileio.asm -- the REAL Open implementation
extern on_save_as_activate           ; fileio.asm -- fallback when "Save" is chosen but there's no current path yet
extern write_buffer_to_file          ; fileio.asm -- used directly when "Save" is chosen and there IS a current path (no need for a picker)
extern on_quit_activate               ; actions.asm -- the REAL Quit implementation (unconditional g_application_quit)

section .rodata
    sig_changed       db "changed", 0            ; GtkTextBuffer's own "the content changed" signal
    sig_close_request db "close-request", 0        ; GtkWindow's "titlebar X was clicked" signal

    heading_str  db "Save changes?", 0
    body_str     db "This document has unsaved changes. If you close without saving, those changes will be lost.", 0

    ; AdwAlertDialog response IDs (arbitrary strings we choose, matched
    ; against adw_alert_dialog_choose_finish's return value with strcmp
    ; in on_unsaved_response below) paired with their button labels.
    resp_cancel  db "cancel", 0
    lbl_cancel   db "_Cancel", 0
    resp_discard db "discard", 0
    lbl_discard  db "_Discard", 0
    resp_save    db "save", 0
    lbl_save     db "_Save", 0

section .bss
    align 8
    g_dirty          resq 1     ; 1 = the buffer has unsaved changes, 0 = it doesn't (starts at 0 -- a fresh empty document has nothing to lose)
    g_pending_action resq 1     ; a PENDING_* constant naming what to do once an in-progress prompt is answered; PENDING_NONE when no prompt is showing

section .text

; void mark_dirty(void) -- the whole function is one instruction; not
; worth a stack frame for something this simple with no calls inside it.
mark_dirty:
    mov  qword [rel g_dirty], 1
    ret

; void clear_dirty(void) -- same reasoning, no frame needed.
clear_dirty:
    mov  qword [rel g_dirty], 0
    ret

; void on_buffer_changed(GtkTextBuffer *buffer, gpointer user_data)
; GtkTextBuffer's "changed" signal fires on every edit (typing, paste,
; programmatic insert/delete alike) -- connected once in
; setup_unsaved_tracking below.
on_buffer_changed:
    push rbp
    mov  rbp, rsp
    ICALL mark_dirty
    pop  rbp
    ret

; void perform_pending(intptr_t kind)
; Actually runs one of New/Open/Quit's real implementations, once it's
; been decided (by request_close or on_unsaved_response) that it's safe
; to do so. Always clears g_pending_action first, since by the time this
; runs, whatever was pending is either about to happen or (for an
; unrecognized/PENDING_NONE kind) was never going to.
perform_pending:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = kind (the incoming arg, saved since it's compared against three different constants below, awkward to keep re-deriving from a register that calls might clobber)
    mov  [rbp-8], rdi

    mov  qword [rel g_pending_action], PENDING_NONE   ; whatever was pending is about to be resolved one way or another

    mov  rax, [rbp-8]
    cmp  rax, PENDING_NEW
    jne  .chk_open
    ICALL on_new_activate           ; the real File > New
    jmp  .done
.chk_open:
    cmp  rax, PENDING_OPEN
    jne  .chk_quit
    ICALL on_open_activate           ; the real File > Open (shows the picker -- itself async, but that's fine, we're just kicking it off)
    jmp  .done
.chk_quit:
    cmp  rax, PENDING_QUIT
    jne  .done                        ; not NEW, OPEN, or QUIT -- i.e. PENDING_NONE reached here somehow; nothing to do
    ICALL on_quit_activate              ; the real Quit (g_application_quit)
.done:
    leave
    ret

; void on_unsaved_response(GObject *dialog, GAsyncResult *res, gpointer user_data)
; The GAsyncReadyCallback for adw_alert_dialog_choose (see request_close
; below) -- fires once the user picks Cancel, Discard, or Save (or
; dismisses the dialog some other way, e.g. Escape, which
; set_close_response below maps to the same string as Cancel).
on_unsaved_response:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the response id string returned by GTK (a borrowed pointer into GTK's own internal string table -- one of resp_cancel/resp_discard/resp_save's OWN bytes, actually, since those are exactly what we registered as the valid response ids)

    ; dialog (rdi) and res (rsi) already positioned for *_finish(self, result)
    ; -- this callback's own incoming args line up exactly with what
    ; adw_alert_dialog_choose_finish wants
    CCALL adw_alert_dialog_choose_finish    ; const char *adw_alert_dialog_choose_finish(AdwAlertDialog*, GAsyncResult*) -- rax = whichever response id string matched the button/key the user used
    mov  [rbp-8], rax

    mov  rdi, [rbp-8]                 ; arg1 = the response id we got back
    lea  rsi, [rel resp_discard]        ; arg2 = "discard"
    CCALL strcmp                          ; int strcmp(const char*, const char*) -- 0 means equal
    test eax, eax
    jz   .discard

    mov  rdi, [rbp-8]                 ; arg1 = the response id
    lea  rsi, [rel resp_save]           ; arg2 = "save"
    CCALL strcmp
    test eax, eax
    jz   .save

    ; anything else (specifically: "cancel", which set_close_response
    ; below also maps Escape/the dialog's own close button to) -- drop
    ; the pending action entirely, the user changed their mind
    mov  qword [rel g_pending_action], PENDING_NONE
    jmp  .done

.discard:
    ; proceed with whatever was pending, throwing away the unsaved changes
    mov  rdi, [rel g_pending_action]
    ICALL perform_pending
    jmp  .done

.save:
    mov  rax, [rel g_current_path]      ; is there already a file to save to?
    test rax, rax
    jz   .save_as                          ; no -- fall through to the Save As path below
    mov  rdi, rax                            ; arg = the current path
    ICALL write_buffer_to_file                 ; write synchronously, no picker needed
    ICALL clear_dirty                            ; the save succeeded (write_buffer_to_file doesn't report failure, so this is optimistic -- matches its own documented silent-failure behavior, see fileio.asm)
    mov  rdi, [rel g_pending_action]              ; now safe to proceed with the originally-requested New/Open/Quit
    ICALL perform_pending
    jmp  .done
.save_as:
    ICALL on_save_as_activate     ; async Save As -- see file header note: the pending New/Open/Quit is
                                   ; NOT chained after this completes, it's simply dropped here
    mov  qword [rel g_pending_action], PENDING_NONE

.done:
    leave
    ret

; void request_close(intptr_t kind) -- run `kind` (a PENDING_* constant)
; now if the buffer is clean, otherwise ask first. This is the single
; entry point every "might discard unsaved work" action funnels through.
request_close:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the AdwAlertDialog we build, only used on the "ask first" path

    mov  rax, [rel g_dirty]
    test rax, rax
    jnz  .prompt                   ; dirty -- need to ask first
    ICALL perform_pending          ; clean -- rdi already = kind (this function's own incoming argument, untouched by the test above), just do it
    leave
    ret

.prompt:
    mov  [rel g_pending_action], rdi   ; remember what we're asking permission for -- on_unsaved_response reads this once the user answers

    ; --- build the alert dialog: heading, body, three responses --------
    lea  rdi, [rel heading_str]        ; arg1 = "Save changes?"
    lea  rsi, [rel body_str]             ; arg2 = the longer explanation
    CCALL adw_alert_dialog_new              ; AdwAlertDialog *adw_alert_dialog_new(const char *heading, const char *body)
    mov  [rbp-8], rax

    mov  rdi, [rbp-8]                          ; arg1 = self
    lea  rsi, [rel resp_cancel]                  ; arg2 = id = "cancel"
    lea  rdx, [rel lbl_cancel]                     ; arg3 = label = "_Cancel"
    CCALL adw_alert_dialog_add_response              ; void adw_alert_dialog_add_response(AdwAlertDialog*, const char *id, const char *label)
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_discard]                       ; id = "discard"
    lea  rdx, [rel lbl_discard]                          ; label = "_Discard"
    CCALL adw_alert_dialog_add_response
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_save]                              ; id = "save"
    lea  rdx, [rel lbl_save]                                 ; label = "_Save"
    CCALL adw_alert_dialog_add_response

    ; make "Discard" visually stand out as the dangerous option (styled
    ; e.g. in red by libadwaita), so it isn't mistaken for the safe default
    mov  rdi, [rbp-8]                          ; arg1 = self
    lea  rsi, [rel resp_discard]                 ; arg2 = which response = "discard"
    mov  edx, ADW_RESPONSE_DESTRUCTIVE             ; arg3 = appearance
    CCALL adw_alert_dialog_set_response_appearance    ; void adw_alert_dialog_set_response_appearance(AdwAlertDialog*, const char*, AdwResponseAppearance)

    ; "Save" is the safest/most expected choice -- make it the default
    ; (e.g. what pressing Enter activates)
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_save]
    CCALL adw_alert_dialog_set_default_response         ; void adw_alert_dialog_set_default_response(AdwAlertDialog*, const char*)

    ; Escape / the dialog's own close affordance should behave exactly
    ; like clicking Cancel, not like silently discarding
    mov  rdi, [rbp-8]
    lea  rsi, [rel resp_cancel]
    CCALL adw_alert_dialog_set_close_response             ; void adw_alert_dialog_set_close_response(AdwAlertDialog*, const char*)

    ; --- show it (async) --------------------------------------------------
    mov  rdi, [rbp-8]                      ; arg1 = self
    mov  rsi, [rel g_window]                 ; arg2 = parent
    xor  edx, edx                              ; arg3 = cancellable = NULL
    lea  rcx, [rel on_unsaved_response]          ; arg4 = callback
    xor  r8, r8                                    ; arg5 = user_data = NULL
    CCALL adw_alert_dialog_choose                     ; void adw_alert_dialog_choose(AdwAlertDialog*, GtkWidget *parent, GCancellable*, GAsyncReadyCallback, gpointer) -- shows the dialog, returns immediately; on_unsaved_response fires later once answered

    leave
    ret

; ---- GAction handlers wired up in place of fileio.asm's/actions.asm's
;      direct New/Open/Quit handlers -- see actions.asm ----------------------

; void on_new_requested(GSimpleAction*, GVariant*, gpointer) -- registered
; as "win.new"'s activate callback instead of fileio.asm's on_new_activate.
on_new_requested:
    push rbp
    mov  rbp, rsp
    mov  edi, PENDING_NEW
    ICALL request_close
    pop  rbp
    ret

; void on_open_requested(GSimpleAction*, GVariant*, gpointer) -- registered
; as "win.open"'s activate callback.
on_open_requested:
    push rbp
    mov  rbp, rsp
    mov  edi, PENDING_OPEN
    ICALL request_close
    pop  rbp
    ret

; void on_quit_requested(GSimpleAction*, GVariant*, gpointer) -- registered
; as "app.quit"'s activate callback instead of calling on_quit_activate directly.
on_quit_requested:
    push rbp
    mov  rbp, rsp
    mov  edi, PENDING_QUIT
    ICALL request_close
    pop  rbp
    ret

; gboolean on_window_close_request(GtkWindow *window, gpointer user_data)
; Closing via the titlebar bypasses the "quit" action entirely (GTK's
; default behavior for a plain window-close is to just destroy it), so it
; needs the same dirty check applied directly here rather than being able
; to reuse on_quit_requested's GAction-shaped entry point.
on_window_close_request:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- everything here is either the global g_dirty or
    ; an immediate constant

    mov  rax, [rel g_dirty]
    test rax, rax
    jz   .allow                      ; nothing unsaved -- nothing to ask about

    mov  edi, PENDING_QUIT
    ICALL request_close                ; dirty -- this will show the prompt (g_dirty being nonzero here guarantees request_close takes its "ask first" branch, not the immediate one)
    mov  eax, TRUE                ; block the default close; perform_pending
                                   ; will g_application_quit once resolved
    jmp  .ret
.allow:
    mov  eax, FALSE               ; nothing unsaved -- let the default
                                   ; close (and normal app shutdown) proceed
.ret:
    pop  rbp
    ret

; void setup_unsaved_tracking(void) -- call once, after g_window and
; g_buffer both exist.
setup_unsaved_tracking:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- both g_signal_connect_data calls below are
    ; independent, nothing from the first needs to survive into the second

    ; every edit dirties the document
    mov  rdi, [rel g_buffer]                  ; arg1 = instance = the text buffer
    lea  rsi, [rel sig_changed]                 ; arg2 = "changed"
    lea  rdx, [rel on_buffer_changed]             ; arg3 = callback
    xor  ecx, ecx                                  ; arg4 = user_data = NULL
    xor  r8, r8                                     ; arg5 = destroy_data = NULL
    mov  r9d, G_CONNECT_DEFAULT                       ; arg6 = flags = 0
    CCALL g_signal_connect_data

    ; the titlebar close button needs its own dirty check (see
    ; on_window_close_request's own comment for why it can't just reuse
    ; on_quit_requested)
    mov  rdi, [rel g_window]                    ; arg1 = instance = the main window
    lea  rsi, [rel sig_close_request]              ; arg2 = "close-request"
    lea  rdx, [rel on_window_close_request]          ; arg3 = callback
    xor  ecx, ecx                                      ; arg4 = user_data = NULL
    xor  r8, r8                                         ; arg5 = destroy_data = NULL
    mov  r9d, G_CONNECT_DEFAULT
    CCALL g_signal_connect_data

    pop  rbp
    ret
