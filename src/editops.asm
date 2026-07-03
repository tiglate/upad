; editops.asm -- Undo, Cut, Copy, Paste, Delete, Select All, and Time/Date.
;
; The first six all reduce to invoking one of GTK4's own built-in text
; widget actions ("clipboard.cut", "text.undo", ...) on g_textview via
; gtk_widget_activate_action_variant -- the same mechanism the widget's
; own default Ctrl+X/Ctrl+Z/etc. keybindings use internally, so behaviour
; (interaction with selection, undo grouping, ...) matches exactly. Rather
; than writing six nearly-identical GSimpleAction handlers, one shared
; handler (on_textop_activate) is registered six times with the widget
; action name passed through as the GSimpleAction's user_data -- see
; register_textop below for how that per-registration string gets there.

%include "consts.inc"          ; G_CONNECT_DEFAULT
%include "callconv.inc"        ; CCALL/ICALL macros
%include "extern.inc"          ; extern g_simple_action_new/g_action_map_add_action/gtk_widget_activate_action_variant/time/localtime/strftime/gtk_text_buffer_insert_at_cursor

global setup_textops                  ; called once from actions.asm's setup_win_actions
global on_insert_time_date_activate    ; registered directly in actions.asm's win_actions table (it's a normal, non-shared GActionEntry, unlike the six below)

extern g_window                  ; main.asm -- action map the six text-op actions get registered onto
extern g_textview                ; main.asm -- the widget whose built-in actions we're invoking
extern g_buffer                  ; main.asm -- where Time/Date inserts its text

section .rodata
    sig_activate     db "activate", 0     ; GObject signal name, reused for all six g_signal_connect_data calls below

    ; Each pair here is (our own GAction name, GTK's built-in widget
    ; action name it maps to). The GAction name becomes "win.<name>" in
    ; menu.asm/accels.asm; the widget action name is what actually gets
    ; invoked on g_textview via gtk_widget_activate_action_variant.
    n_undo   db "undo", 0
    w_undo   db "text.undo", 0
    n_cut    db "cut", 0
    w_cut    db "clipboard.cut", 0
    n_copy   db "copy", 0
    w_copy   db "clipboard.copy", 0
    n_paste  db "paste", 0
    w_paste  db "clipboard.paste", 0
    n_delete db "delete", 0
    w_delete db "selection.delete", 0
    n_selall db "select-all", 0
    w_selall db "selection.select-all", 0

    time_fmt db "%c", 0          ; strftime format: locale default date+time representation (e.g. "Thu 02 Jul 2026 11:04:00 PM -03")

section .text

; void on_textop_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
; Shared by all six text-widget actions registered below. user_data (the
; GSimpleAction's own, set at registration time in register_textop) is
; the widget action name string to invoke -- e.g. for the Undo action,
; user_data is a pointer to "text.undo".
on_textop_activate:
    push rbp                      ; save caller's frame pointer
    mov  rbp, rsp                  ; establish frame (no locals -- everything needed is already in a register or global)
    mov  rdi, [rel g_textview]     ; arg1 = widget = the text view
    mov  rsi, rdx                  ; arg2 = action name = user_data (the incoming 3rd signal arg, rdx) -- e.g. "clipboard.cut"
    xor  edx, edx                  ; arg3 = GVariant *args = NULL (none of these six built-in actions take a parameter)
    CCALL gtk_widget_activate_action_variant   ; gboolean gtk_widget_activate_action_variant(GtkWidget*, const char *name, GVariant *args) -- return value (found-and-activated?) ignored, these are always present on a GtkTextView
    pop  rbp
    ret

; void register_textop(const char *gio_action_name, const char *widget_action_name)
; Builds one GSimpleAction named gio_action_name, connects its "activate"
; signal to the shared handler above (passing widget_action_name through
; as user_data), and adds it to the window's action map. Doing this via
; g_simple_action_new + g_signal_connect_data (one call per action)
; instead of the batch g_action_map_add_action_entries used elsewhere
; (actions.asm) is what lets six actions share exactly one handler
; function -- GActionEntry's user_data is fixed per *table*, not
; per-entry, so the batch API can't parameterize six entries this way.
register_textop:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; two local slots: [rbp-8]=the new GSimpleAction*, [rbp-16]=widget_action_name (must survive several calls, so it can't stay in a caller-saved register)
    mov  [rbp-16], rsi            ; stash widget_action_name (incoming arg2) before rsi gets reused below

    xor  esi, esi                 ; arg2 = parameter_type = NULL (none of these six take a GVariant parameter)
    CCALL g_simple_action_new     ; GSimpleAction *g_simple_action_new(const gchar *name, const GVariantType *parameter_type) -- arg1 (name) is still our own incoming rdi, untouched so far
    mov  [rbp-8], rax             ; the new action, owned by us until g_action_map_add_action below takes its own ref

    ; connect "activate" -> on_textop_activate, with widget_action_name as user_data
    mov  rdi, [rbp-8]             ; arg1 = instance = the new action
    lea  rsi, [rel sig_activate]  ; arg2 = "activate"
    lea  rdx, [rel on_textop_activate]   ; arg3 = callback
    mov  rcx, [rbp-16]            ; arg4 = user_data = widget_action_name (this is the whole point of doing it this way instead of the batch API)
    xor  r8, r8                   ; arg5 = destroy_data = NULL
    mov  r9d, G_CONNECT_DEFAULT   ; arg6 = connect flags = 0
    CCALL g_signal_connect_data

    ; register it on the window's action map so "win.<name>" resolves to it
    mov  rdi, [rel g_window]      ; arg1 = action map = main window
    mov  rsi, [rbp-8]             ; arg2 = the action
    CCALL g_action_map_add_action  ; void g_action_map_add_action(GActionMap*, GAction*) -- takes its own reference

    ; drop our own reference -- the window's action map now owns the one that matters
    mov  rdi, [rbp-8]
    CCALL g_object_unref

    leave                          ; mov rsp, rbp; pop rbp
    ret

; void on_insert_time_date_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
; Classic Notepad's F5: inserts the current date/time as text at the
; cursor. Three libc calls build the formatted string (time -> localtime
; -> strftime), then one GTK call inserts it -- no string concatenation
; needed since strftime formats directly into our buffer.
on_insert_time_date_activate:
    push rbp
    mov  rbp, rsp
    sub  rsp, 96                  ; [rbp-8] = time_t value (8 bytes); [rbp-96..-9] = formatted-string buffer (87 bytes usable, rounded up to keep the frame a multiple of 16)

    ; time_t now = time(NULL)
    xor  edi, edi                 ; arg1 = NULL (we don't need the value written through a pointer -- the return value is enough)
    CCALL time                     ; time_t time(time_t *tloc) -- rax = current time_t
    mov  [rbp-8], rax             ; stash it: localtime below needs a *pointer* to a time_t, so it has to live somewhere addressable

    ; struct tm *tm = localtime(&now)
    lea  rdi, [rbp-8]             ; arg1 = &now
    CCALL localtime                ; rax = struct tm* -- points into a static/thread-local buffer glibc owns; we never touch its fields directly, just hand the pointer straight to strftime below
    ; rax (the struct tm*) is still valid here -- no call has happened
    ; since localtime returned, so nothing has had a chance to clobber it

    ; strftime(buf, 87, "%c", tm)
    lea  rdi, [rbp-96]             ; arg1 = destination buffer
    mov  esi, 87                    ; arg2 = max size
    lea  rdx, [rel time_fmt]        ; arg3 = "%c" format string
    mov  rcx, rax                   ; arg4 = struct tm* (still in rax from localtime, moved into position last since rdi/rsi/rdx don't depend on it)
    CCALL strftime                   ; size_t strftime(char *s, size_t max, const char *format, const struct tm *tm) -- fills buf, NUL-terminated; return value (length) unused since we pass -1 (NUL-terminated) below rather than an exact count

    ; gtk_text_buffer_insert_at_cursor(buffer, buf, -1)
    mov  rdi, [rel g_buffer]        ; arg1 = buffer
    lea  rsi, [rbp-96]              ; arg2 = the formatted text
    mov  edx, -1                     ; arg3 = len = -1, meaning "NUL-terminated, compute the length yourself"
    CCALL gtk_text_buffer_insert_at_cursor   ; void gtk_text_buffer_insert_at_cursor(GtkTextBuffer*, const char *text, int len)

    leave
    ret

; void setup_textops(void) -- call once, after g_window and g_textview exist
; Registers all six built-in-text-widget-action wrappers via register_textop.
setup_textops:
    push rbp
    mov  rbp, rsp
    ; rsp is 16-aligned here (entry 8, -8 for push rbp = 0); no locals of
    ; our own needed, and every ICALL below is alignment-safe on its own.

    lea  rdi, [rel n_undo]         ; gio name "undo"
    lea  rsi, [rel w_undo]         ; -> widget action "text.undo"
    ICALL register_textop
    lea  rdi, [rel n_cut]          ; "cut"
    lea  rsi, [rel w_cut]          ; -> "clipboard.cut"
    ICALL register_textop
    lea  rdi, [rel n_copy]         ; "copy"
    lea  rsi, [rel w_copy]         ; -> "clipboard.copy"
    ICALL register_textop
    lea  rdi, [rel n_paste]        ; "paste"
    lea  rsi, [rel w_paste]        ; -> "clipboard.paste"
    ICALL register_textop
    lea  rdi, [rel n_delete]       ; "delete"
    lea  rsi, [rel w_delete]       ; -> "selection.delete"
    ICALL register_textop
    lea  rdi, [rel n_selall]       ; "select-all"
    lea  rsi, [rel w_selall]       ; -> "selection.select-all"
    ICALL register_textop

    pop  rbp
    ret
