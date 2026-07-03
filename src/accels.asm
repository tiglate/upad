; accels.asm -- keyboard accelerators for actions that don't already have a
; GTK built-in default binding. (Cut/Copy/Paste/Undo/Select-All are bound
; automatically by GtkTextView itself since they route through GTK's own
; "clipboard.*"/"text.undo"/"selection.*" widget actions -- see
; editops.asm -- so those need nothing here.)
;
; GTK accelerator strings use gtk_accelerator_parse() syntax:
; "<Control>", "<Shift>", "<Alt>" modifier prefixes (composable, e.g.
; "<Control><Shift>s") followed by a key name -- either a lowercase
; letter or a named key like "F3"/"F5". gtk_application_set_accels_for_action
; takes an *array* of such strings per action (so an action could have
; more than one binding), NULL-terminated; every action here only ever
; needs one, so every array below is just {the one string, NULL}.

%include "consts.inc"          ; G_APPLICATION_HANDLES_OPEN etc. (via consts.inc's other constants, unused directly here but kept for consistency with every other file's include block)
%include "callconv.inc"        ; CCALL/ICALL macros
%include "extern.inc"          ; extern gtk_application_set_accels_for_action

global setup_accels             ; called once from window.asm's ensure_main_window

extern g_app                    ; the AdwApplication*/GtkApplication* (main.asm) -- accelerators are registered on the application, not any one window

section .rodata
    ; --- the accelerator (keystroke) for each action, in GTK's own
    ;     gtk_accelerator_parse() text syntax --------------------------
    a_new         db "<Control>n", 0
    a_open        db "<Control>o", 0
    a_save        db "<Control>s", 0
    a_save_as     db "<Control><Shift>s", 0
    a_quit        db "<Control>q", 0
    a_find        db "<Control>f", 0
    a_find_next   db "F3", 0              ; classic Notepad's Find Next shortcut
    a_replace     db "<Control>h", 0
    a_goto        db "<Control>g", 0
    a_time_date   db "F5", 0               ; classic Notepad's Time/Date shortcut

    ; --- the detailed action name each accelerator applies to ----------
    ; ("win." for window-scoped actions registered in actions.asm's
    ; win_actions table, "app." for the one application-scoped action)
    d_new         db "win.new", 0
    d_open        db "win.open", 0
    d_save        db "win.save", 0
    d_save_as     db "win.save-as", 0
    d_quit        db "app.quit", 0
    d_find        db "win.find", 0
    d_find_next   db "win.find-next", 0
    d_replace     db "win.replace", 0
    d_goto        db "win.go-to-line", 0
    d_time_date   db "win.insert-time-date", 0

section .data
    align 8
    ; gtk_application_set_accels_for_action's third argument is
    ; `const char * const *accels` -- a NULL-terminated array of
    ; accelerator strings. Each of these pairs is exactly that array,
    ; one accelerator followed by the required NULL terminator.
    accel_new       dq a_new,       0
    accel_open      dq a_open,      0
    accel_save      dq a_save,      0
    accel_save_as   dq a_save_as,   0
    accel_quit      dq a_quit,      0
    accel_find      dq a_find,      0
    accel_find_next dq a_find_next, 0
    accel_replace   dq a_replace,   0
    accel_goto      dq a_goto,      0
    accel_time_date dq a_time_date, 0

section .text

; void set_accel(const char *detailed_action_name, const char *const *accels)
; Thin wrapper so setup_accels below reads as one line per shortcut
; instead of three: loads g_app as the implicit first argument to
; gtk_application_set_accels_for_action, forwarding the two args we were
; given as its 2nd and 3rd.
set_accel:
    push rbp                      ; save caller's frame pointer
    mov  rbp, rsp                 ; establish our frame (no locals needed -- everything fits in registers with no intervening calls)

    ; Reorder incoming (rdi=detailed_action_name, rsi=accels) into the
    ; callee's (rdi=app, rsi=detailed_action_name, rdx=accels). Order
    ; matters here: rdx must be set from the OLD rsi before rsi itself
    ; gets overwritten with the OLD rdi, and rdi must be set from
    ; g_app (a fresh load, not derived from the old rdi) -- so do the
    ; "derived from old register" moves first, in an order where nothing
    ; reads a register that's already been clobbered by an earlier move
    ; in this same sequence.
    mov  rdx, rsi                 ; arg3 (accels) = old rsi -- captured before rsi is reused below
    mov  rsi, rdi                 ; arg2 (detailed_action_name) = old rdi -- captured before rdi is overwritten below
    mov  rdi, [rel g_app]         ; arg1 (app) -- safe to load now, doesn't depend on any register we just touched

    CCALL gtk_application_set_accels_for_action   ; void gtk_application_set_accels_for_action(GtkApplication*, const char *detailed_action_name, const char *const *accels)

    pop  rbp                      ; restore caller's frame pointer
    ret

; void setup_accels(void)
; Registers every keyboard shortcut this program defines explicitly.
; Called once, from window.asm, after the window/actions already exist
; (accelerators can technically be set before the action does, but there's
; no reason to -- this just keeps the ordering obviously safe).
setup_accels:
    push rbp
    mov  rbp, rsp
    ; rsp is 16-aligned here (entry 8, -8 for push rbp = 0); no locals
    ; needed, and every ICALL below is itself alignment-safe.

    lea  rdi, [rel d_new]              ; "win.new"
    lea  rsi, [rel accel_new]          ; {"<Control>n", NULL}
    ICALL set_accel
    lea  rdi, [rel d_open]             ; "win.open"
    lea  rsi, [rel accel_open]         ; {"<Control>o", NULL}
    ICALL set_accel
    lea  rdi, [rel d_save]             ; "win.save"
    lea  rsi, [rel accel_save]         ; {"<Control>s", NULL}
    ICALL set_accel
    lea  rdi, [rel d_save_as]          ; "win.save-as"
    lea  rsi, [rel accel_save_as]      ; {"<Control><Shift>s", NULL}
    ICALL set_accel
    lea  rdi, [rel d_quit]             ; "app.quit"
    lea  rsi, [rel accel_quit]         ; {"<Control>q", NULL}
    ICALL set_accel
    lea  rdi, [rel d_find]             ; "win.find"
    lea  rsi, [rel accel_find]         ; {"<Control>f", NULL}
    ICALL set_accel
    lea  rdi, [rel d_find_next]        ; "win.find-next"
    lea  rsi, [rel accel_find_next]    ; {"F3", NULL}
    ICALL set_accel
    lea  rdi, [rel d_replace]          ; "win.replace"
    lea  rsi, [rel accel_replace]      ; {"<Control>h", NULL}
    ICALL set_accel
    lea  rdi, [rel d_goto]             ; "win.go-to-line"
    lea  rsi, [rel accel_goto]         ; {"<Control>g", NULL}
    ICALL set_accel
    lea  rdi, [rel d_time_date]        ; "win.insert-time-date"
    lea  rsi, [rel accel_time_date]    ; {"F5", NULL}
    ICALL set_accel

    pop  rbp
    ret
