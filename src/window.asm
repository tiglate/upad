; Copyright (c) 2026 Tiglate Pileser III (tiglate). Created with AI
; assistance. Licensed under the Apache License, Version 2.0; see
; LICENSE at the repo root for the full text.

; window.asm -- builds the main window (menu bar, text view, status bar)
; the first time GApplication fires either of the two signals it can
; start on, and dispatches both of them.

%include "consts.inc"    ; GTK_ORIENTATION_VERTICAL, GTK_POLICY_AUTOMATIC, GTK_WRAP_WORD_CHAR, TRUE
%include "callconv.inc"  ; CCALL/ICALL macros
%include "extern.inc"    ; extern declarations for every GTK call used below

global on_activate         ; connected to GApplication's "activate" signal in main.asm
global on_open_signal      ; connected to GApplication's "open" signal in main.asm
global ensure_main_window  ; also called directly by on_activate/on_open_signal below

extern g_app                   ; main.asm
extern g_window                ; main.asm
extern g_textview              ; main.asm
extern g_buffer                ; main.asm
extern g_scrolled              ; main.asm
extern g_box                   ; main.asm
extern setup_win_actions       ; actions.asm
extern setup_app_actions       ; actions.asm
extern build_menubar           ; menu.asm
extern update_window_title     ; fileio.asm
extern setup_accels            ; accels.asm
extern build_statusbar         ; statusbar.asm
extern setup_line_numbers      ; linenum.asm -- attaches the line-number gutter, after g_textview/g_scrolled both exist
extern init_dark_mode_state    ; format.asm
extern setup_unsaved_tracking  ; unsaved.asm
extern read_file_to_buffer     ; fileio.asm -- reused here for the "opened with a file argument" path
extern clear_dirty             ; unsaved.asm -- reused here for the same reason
extern g_current_path          ; fileio.asm -- reused here for the same reason
extern strcopy_bounded         ; fileio.asm -- reused here purely as a bounded string-append, for register_icon_search_path's path building

section .rodata
    ; Icon name looked up via the current GtkIconTheme -- resolves to
    ; icons/hicolor/scalable/apps/org.unbloatedpad.Editor.svg, either
    ; relative to this executable (register_icon_search_path below, for an
    ; uninstalled `make && ./upad` build) or under a system icon theme
    ; directory once installed (see the Makefile's `install`/`deb`
    ; targets). Deliberately the same string as main.asm's app_id_str and
    ; this project's .desktop file basename/Icon= key -- GTK and the
    ; desktop shell key icon-theme and window-manager lookups off that
    ; shared identifier, not a filename.
    app_icon_name_str  db "org.unbloatedpad.Editor", 0
    proc_self_exe_str  db "/proc/self/exe", 0
    ; Appended after this executable's own directory; register_icon_search_path.
    ; Deliberately "/icons", NOT "/icons/hicolor": gtk_icon_theme_add_search_path
    ; expects a directory that itself CONTAINS a theme-name subdirectory
    ; (mirroring how "/usr/share/icons" contains "hicolor/", "Adwaita/",
    ; etc.) -- it scans "<search_path>/hicolor/<size>/<context>/<icon>"
    ; itself, so passing ".../icons/hicolor" directly makes every lookup
    ; silently fail (verified empirically: has_icon() stayed false until
    ; this was pointed at the parent instead).
    icons_subdir_str   db "/icons", 0

section .bss
    align 8
    ; readlink("/proc/self/exe") result, truncated at the last '/' to drop
    ; this executable's own filename, then suffixed with icons_subdir_str
    ; -- see register_icon_search_path. EXE_PATH_BUF_SIZE (4096, PATH_MAX)
    ; comfortably covers both.
    g_exe_path_buf  resb EXE_PATH_BUF_SIZE

section .text

; void register_icon_search_path(void) -- makes <directory containing this
; executable>/icons an extra GtkIconTheme search path, so
; gtk_window_set_icon_name (called right after this, in ensure_main_window)
; can resolve "org.unbloatedpad.Editor" to
; icons/hicolor/scalable/apps/org.unbloatedpad.Editor.svg in the source
; tree even when the icon was never installed into a system icon theme
; location -- i.e. the ordinary `make && ./upad` dev loop, as opposed to
; `make install`/the .deb, which put it somewhere GTK's default search
; path already covers. Failing silently (leaving the search path
; unchanged) on any error here just means the icon falls back to whatever
; the system theme already provides -- never fatal to starting the app.
register_icon_search_path:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                        ; [rbp-8] = readlink's return value (byte count, or -1)

    lea  rdi, [rel proc_self_exe_str]  ; arg1 = "/proc/self/exe"
    lea  rsi, [rel g_exe_path_buf]     ; arg2 = dest buffer
    mov  rdx, EXE_PATH_BUF_SIZE - 32   ; arg3 = byte budget, deliberately short of the buffer's full size to leave room for icons_subdir_str's append below -- readlink doesn't NUL-terminate or know about that append, so this is on us
    CCALL readlink                     ; ssize_t readlink(const char *path, char *buf, size_t bufsiz)
    mov  [rbp-8], rax
    cmp  qword [rbp-8], 0
    jle  .done                               ; /proc/self/exe unreadable, or somehow resolved to a 0-length string -- give up quietly

    lea  rdi, [rel g_exe_path_buf]            ; NUL-terminate at the byte count readlink reported (it never does this itself)
    add  rdi, [rbp-8]
    mov  byte [rdi], 0

    lea  rdi, [rel g_exe_path_buf]  ; scan backward from that NUL for the last '/', the boundary
    mov  rcx, [rbp-8]               ; between this executable's directory and its own filename
.scan_for_slash:
    dec  rcx
    js   .done                                    ; ran off the front without finding '/' -- can't happen for a genuine absolute path, but bail rather than misread garbage as a directory
    cmp  byte [rdi + rcx], '/'
    jne  .scan_for_slash
    mov  byte [rdi + rcx], 0                        ; truncate the path there: directory only, no trailing slash, drops the executable's own basename

    lea  rdi, [rdi + rcx]             ; dest = the NUL just written, i.e. right after the directory
    lea  rsi, [rel icons_subdir_str]  ; src = "/icons"
    mov  rdx, 32                      ; budget -- 7 bytes incl. NUL actually needed, 32 is just a comfortable bound
    ICALL strcopy_bounded             ; fileio.asm -- reused purely as a bounded append

    CCALL gdk_display_get_default                          ; GdkDisplay *gdk_display_get_default(void)
    mov  rdi, rax
    CCALL gtk_icon_theme_get_for_display                     ; GtkIconTheme *gtk_icon_theme_get_for_display(GdkDisplay*)
    mov  rdi, rax
    lea  rsi, [rel g_exe_path_buf]        ; now "<exe dir>/icons"
    CCALL gtk_icon_theme_add_search_path  ; void gtk_icon_theme_add_search_path(GtkIconTheme*, const char *path)

.done:
    leave
    ret

; void on_activate(GApplication *app, gpointer user_data)
; Fires when the app is launched with no file arguments (a plain `upad`,
; or activating an already-running single instance with no new files).
on_activate:
    push rbp                  ; save caller's (GLib's signal-emission code) frame pointer
    mov  rbp, rsp             ; establish our frame -- no locals needed, this is a thin dispatcher
    ICALL ensure_main_window  ; build the window if this is the first signal to fire (no-op if on_open_signal beat us to it, e.g. a second "open" while running)
    mov  rdi, [rel g_window]  ; arg1 = the (now-guaranteed-to-exist) window
    CCALL gtk_window_present  ; void gtk_window_present(GtkWindow*) -- raises/focuses it
    pop  rbp
    ret

; void on_open_signal(GApplication *app, GFile **files, gint n_files,
;                      const gchar *hint, gpointer user_data)
; Fires instead of "activate" when launched with a file argument (e.g.
; `upad somefile.txt`, or a file manager "Open With" -- see the .desktop
; file's Exec=upad %F). g_app was created with G_APPLICATION_HANDLES_OPEN
; specifically so this signal exists at all (main.asm). `files` is a
; GFile** array of n_files entries; this editor only ever opens the
; first one, matching classic Notepad's own single-document model.
on_open_signal:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; three local slots: [rbp-8]=n_files [rbp-16]=files (the array pointer) [rbp-24]=path (once we've resolved files[0] to a filesystem path)

    ; n_files (incoming rdx) is a 32-bit gint -- only its low 32 bits are
    ; ABI-guaranteed meaningful, so sign-extend explicitly into a clean
    ; 64-bit value before storing it, rather than storing raw rdx (whose
    ; upper 32 bits could be anything).
    movsxd rax, edx     ; rax = sign-extended n_files
    mov  [rbp-8], rax   ; stash it
    mov  [rbp-16], rsi  ; stash `files` (incoming rsi) -- both must survive the ensure_main_window call below, which is free to clobber any caller-saved register

    ICALL ensure_main_window        ; build the window if this is the first signal to fire

    cmp  qword [rbp-8], 1  ; were we actually given at least one file?
    jl   .present          ; n_files < 1 -- nothing to open, just show the window

    ; --- resolve files[0] to a plain filesystem path -------------------
    mov  rax, [rbp-16]     ; rax = files (the GFile** array base)
    mov  rdi, [rax]        ; arg1 = files[0] (dereference: the first GFile* in the array)
    CCALL g_file_get_path  ; gchar *g_file_get_path(GFile*) -- rax = newly-allocated path string we now own
    mov  [rbp-24], rax     ; stash it -- read_file_to_buffer below needs it as an argument, and we need it again afterward to store into g_current_path

    ; --- load its contents into the (already-empty, freshly-built) buffer ---
    mov  rdi, [rbp-24]         ; arg1 = the path
    ICALL read_file_to_buffer  ; fileio.asm -- same routine File > Open uses once it has a path

    ; --- take ownership of the path as the document's current file ----
    ; (mirrors fileio.asm's on_open_finished: free whatever the old
    ; g_current_path was pointing at, if anything, before overwriting it)
    mov  rdi, [rel g_current_path]
    test rdi, rdi
    jz   .no_free_old
    CCALL g_free
.no_free_old:
    mov  rax, [rbp-24]              ; the path we resolved above
    mov  [rel g_current_path], rax  ; now the document's current-file path

    ICALL update_window_title  ; retitle the window to "<basename> - UnbloatedPad"
    ICALL clear_dirty          ; freshly-loaded content is not "unsaved changes"

.present:
    mov  rdi, [rel g_window]
    CCALL gtk_window_present           ; show/raise/focus the window either way
    leave
    ret

; void ensure_main_window(void) -- builds the window/menu/textview/status
; bar the first time it's called; a no-op on any later call (both
; "activate" and "open" can each be the first signal GApplication fires,
; and "open" can also fire again later for a second file while already
; running).
ensure_main_window:
    push rbp
    mov  rbp, rsp
    mov  rax, [rel g_window]          ; has the window already been built?
    test rax, rax
    jz   .build  ; no -- fall through to build it
    pop  rbp     ; yes -- nothing to do; note: no `leave` needed since we never allocated a frame (no `sub rsp`) on this early-return path
    ret
.build:
    ; --- the main window itself ----------------------------------------
    ; a plain GtkApplicationWindow, not AdwApplicationWindow: the latter
    ; refuses gtk_window_set_titlebar() outright (Adw wants its own
    ; AdwToolbarView/AdwHeaderBar content structure instead), which is more
    ; machinery than this classic-Notepad-style UI needs. AdwApplication
    ; still gives us the app-wide style manager for dark mode regardless
    ; of which window type it opens.
    mov  rdi, [rel g_app]             ; arg1 = application -- loaded from the global, NOT assumed to still be in rdi: this label runs from on_open_signal too, whose own rdi holds `app` but at a different argument position than a fresh call into this function would expect
    CCALL gtk_application_window_new  ; GtkWidget *gtk_application_window_new(GtkApplication*)
    mov  [rel g_window], rax          ; stash globally -- every other file in the program reads this

    mov  rdi, [rel g_window]
    mov  esi, 800                      ; width
    mov  edx, 600                      ; height
    CCALL gtk_window_set_default_size  ; void gtk_window_set_default_size(GtkWindow*, int width, int height)

    ; taskbar/dock/alt-tab icon -- an explicit call rather than relying
    ; solely on the shell resolving GApplication's app-id to this .desktop
    ; file's Icon= key, since that resolution isn't universal across
    ; window managers (e.g. plain X11 taskbars key off WM_CLASS/icon-name
    ; directly instead). ICALL'd first so the lookup below can find the
    ; icon even in an uninstalled build (see register_icon_search_path).
    ICALL register_icon_search_path
    mov  rdi, [rel g_window]
    lea  rsi, [rel app_icon_name_str]
    CCALL gtk_window_set_icon_name        ; void gtk_window_set_icon_name(GtkWindow*, const char *name)

    ; a plain GtkHeaderBar just for the standard minimize/maximize/close
    ; window controls -- the classic File/Edit/... menu bar built below is
    ; still the primary means of interacting with the app, not this bar
    CCALL gtk_header_bar_new       ; GtkWidget *gtk_header_bar_new(void) -- takes no arguments
    mov  rdi, [rel g_window]       ; arg1 = window
    mov  rsi, rax                  ; arg2 = the header bar just created (still in rax, untouched since the call above)
    CCALL gtk_window_set_titlebar  ; void gtk_window_set_titlebar(GtkWindow*, GtkWidget*)

    ; --- actions, accelerators, and the title (before any content exists --
    ;     none of these three need widgets built yet, only g_window) -------
    ICALL setup_win_actions    ; actions.asm -- registers every "win.*" GAction
    ICALL setup_app_actions    ; actions.asm -- registers "app.quit"
    ICALL setup_accels         ; accels.asm -- keyboard shortcuts for the actions just registered
    ICALL update_window_title  ; fileio.asm -- sets the initial "Untitled - UnbloatedPad" title (g_current_path is still NULL at this point)

    ; --- the top-level vertical layout: menu bar, then text area, then status bar ---
    mov  edi, GTK_ORIENTATION_VERTICAL
    xor  esi, esi      ; spacing = 0 (the pieces are visually distinct enough without extra gaps)
    CCALL gtk_box_new  ; GtkWidget *gtk_box_new(GtkOrientation, int spacing)
    mov  [rel g_box], rax

    ; a few pixels so nothing sits flush against the window's rounded corners
    mov  rdi, [rel g_box]
    mov  esi, 3
    CCALL gtk_widget_set_margin_start
    mov  rdi, [rel g_box]
    mov  esi, 3
    CCALL gtk_widget_set_margin_end
    mov  rdi, [rel g_box]
    mov  esi, 3
    CCALL gtk_widget_set_margin_top
    mov  rdi, [rel g_box]
    mov  esi, 3
    CCALL gtk_widget_set_margin_bottom

    ICALL build_menubar    ; menu.asm -- builds the File/Edit/Format/View/Help GtkPopoverMenuBar, returns it in rax
    mov  rdi, [rel g_box]  ; arg1 = parent = the layout box
    mov  rsi, rax          ; arg2 = child = the menu bar widget just built (still in rax)
    CCALL gtk_box_append   ; void gtk_box_append(GtkBox*, GtkWidget*) -- appends at the end (here: the top, since this is the first child)

    ; the View menu's Dark Mode item exists now (build_menubar just made
    ; it), so it's safe to read/correct its initial checked state to
    ; match whatever the desktop's actual current light/dark preference
    ; already is -- see format.asm for why that matters
    ICALL init_dark_mode_state

    ; --- the text editing widget itself ---------------------------------
    CCALL gtk_text_view_new                    ; GtkWidget *gtk_text_view_new(void)
    mov  [rel g_textview], rax

    mov  rdi, [rel g_textview]
    CCALL gtk_text_view_get_buffer              ; GtkTextBuffer *gtk_text_view_get_buffer(GtkTextView*) -- the model behind the view; almost every editing operation elsewhere in the program touches this, not g_textview directly
    mov  [rel g_buffer], rax

    mov  rdi, [rel g_textview]
    mov  esi, TRUE
    CCALL gtk_widget_set_vexpand                ; let the text view claim all extra vertical space in the box
    mov  rdi, [rel g_textview]
    mov  esi, TRUE
    CCALL gtk_widget_set_hexpand                 ; ... and all extra horizontal space too

    ; monospace + a small top/left margin reads as "classic Notepad", not
    ; a GNOME text widget default
    mov  rdi, [rel g_textview]
    mov  esi, TRUE
    CCALL gtk_text_view_set_monospace

    ; matches win.word-wrap's initial GActionEntry state ("true") in
    ; actions.asm -- if that default ever changes, this must change with it
    mov  rdi, [rel g_textview]
    mov  esi, GTK_WRAP_WORD_CHAR
    CCALL gtk_text_view_set_wrap_mode

    ; a little breathing room around the text itself, so it doesn't sit
    ; flush against the scrolled window's edge / the window's rounded corners
    ; (these four set the *text's* internal padding, distinct from the
    ; widget-level margins used elsewhere in this function -- GtkTextView
    ; has its own dedicated margin properties for exactly this)
    mov  rdi, [rel g_textview]
    mov  esi, 5
    CCALL gtk_text_view_set_left_margin
    mov  rdi, [rel g_textview]
    mov  esi, 5
    CCALL gtk_text_view_set_right_margin
    mov  rdi, [rel g_textview]
    mov  esi, 5
    CCALL gtk_text_view_set_top_margin
    mov  rdi, [rel g_textview]
    mov  esi, 5
    CCALL gtk_text_view_set_bottom_margin

    ; --- wrap the text view in a scrollable container -------------------
    CCALL gtk_scrolled_window_new                ; GtkWidget *gtk_scrolled_window_new(void)
    mov  [rel g_scrolled], rax

    mov  rdi, [rel g_scrolled]
    mov  esi, GTK_POLICY_AUTOMATIC  ; horizontal scrollbar: show only when needed
    mov  edx, GTK_POLICY_AUTOMATIC  ; vertical scrollbar: same
    CCALL gtk_scrolled_window_set_policy

    mov  rdi, [rel g_scrolled]
    mov  esi, TRUE
    CCALL gtk_widget_set_vexpand                   ; let the scrolled window (and thus the text area) fill available vertical space in g_box
    mov  rdi, [rel g_scrolled]
    mov  esi, TRUE
    CCALL gtk_widget_set_hexpand                    ; ... and horizontal space too

    mov  rdi, [rel g_scrolled]           ; arg1 = the scrolled window
    mov  rsi, [rel g_textview]           ; arg2 = child = the text view
    CCALL gtk_scrolled_window_set_child  ; void gtk_scrolled_window_set_child(GtkScrolledWindow*, GtkWidget*)

    mov  rdi, [rel g_box]       ; arg1 = parent = the layout box
    mov  rsi, [rel g_scrolled]  ; arg2 = child = the scrolled window (holding the text view)
    CCALL gtk_box_append        ; appended after the menu bar -- this becomes the middle of the three stacked pieces

    ; g_scrolled's vertical GtkAdjustment is one of the line-number
    ; gutter's redraw triggers, so this can only happen once g_scrolled
    ; exists (unlike most of the setup above, which only needs g_textview)
    ICALL setup_line_numbers                             ; linenum.asm -- attaches the gutter widget, on by default (matches win.line-numbers' initial GActionEntry state ("true") in actions.asm)

    ; --- the "Ln X, Col Y" status bar, last in the stack ------------------
    ICALL build_statusbar  ; statusbar.asm -- builds the label, wires up its own live-update signal, returns it in rax
    mov  rdi, [rel g_box]  ; arg1 = parent = the layout box
    mov  rsi, rax          ; arg2 = child = the status bar label (still in rax)
    CCALL gtk_box_append   ; appended last -- ends up at the bottom of the window

    ; --- attach the finished layout to the window, then wire up the ------
    ;     unsaved-changes-prompt machinery now that g_window/g_buffer exist --
    mov  rdi, [rel g_window]    ; arg1 = window
    mov  rsi, [rel g_box]       ; arg2 = child = the whole vertical stack
    CCALL gtk_window_set_child  ; void gtk_window_set_child(GtkWindow*, GtkWidget*)

    ICALL setup_unsaved_tracking                               ; unsaved.asm -- connects g_buffer's "changed" signal (dirty tracking) and g_window's "close-request" signal (the titlebar-X unsaved-changes prompt)

    leave                                                       ; mov rsp, rbp; pop rbp
    ret
