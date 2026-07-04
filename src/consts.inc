; consts.inc -- shared constants: GLib/GObject/GTK4/libadwaita enum values,
; flags and struct layouts. Values are taken directly from the installed
; system headers (gtk-4.0, libadwaita-1, glib-2.0) rather than guessed --
; see the comment above each block for the header it was checked against.

; ---- gboolean --------------------------------------------------------
TRUE                        equ 1
FALSE                       equ 0
NULL                        equ 0

; ---- gio/gapplication.h: GApplicationFlags ----------------------------
G_APPLICATION_DEFAULT_FLAGS equ 0
G_APPLICATION_HANDLES_OPEN  equ 4

; ---- gobject/gsignal.h: GConnectFlags ---------------------------------
G_CONNECT_DEFAULT           equ 0
G_CONNECT_AFTER             equ 1
G_CONNECT_SWAPPED           equ 2

; ---- gtk/gtkenums.h: GtkOrientation ------------------------------------
GTK_ORIENTATION_HORIZONTAL  equ 0
GTK_ORIENTATION_VERTICAL    equ 1

; ---- gtk/gtkenums.h: GtkWrapMode ---------------------------------------
GTK_WRAP_NONE                equ 0
GTK_WRAP_CHAR                equ 1
GTK_WRAP_WORD                equ 2
GTK_WRAP_WORD_CHAR            equ 3

; ---- gtk/gtkenums.h: GtkPolicyType (scrollbar policy) -------------------
GTK_POLICY_ALWAYS            equ 0
GTK_POLICY_AUTOMATIC         equ 1
GTK_POLICY_NEVER             equ 2
GTK_POLICY_EXTERNAL          equ 3

; ---- struct sizes/offsets, verified with `sizeof`/`offsetof` against
;      the real installed headers on this machine (see gtktextiter.h,
;      gio/gactionmap.h) -- DO NOT change without re-checking. ----------

; GtkTextIter is an opaque, but ABI-fixed-size, struct meant for
; stack allocation. sizeof(GtkTextIter) == 80 on this system/ABI.
GTK_TEXT_ITER_SIZE           equ 80

; struct _GActionEntry { const gchar *name; activate_fn; const gchar
;   *parameter_type; const gchar *state; change_state_fn; gsize padding[3]; }
GACTION_ENTRY_SIZE           equ 64
GACTION_ENTRY_NAME            equ 0
GACTION_ENTRY_ACTIVATE        equ 8
GACTION_ENTRY_PARAM_TYPE      equ 16
GACTION_ENTRY_STATE           equ 24
GACTION_ENTRY_CHANGE_STATE    equ 32
; bytes 40..64 are reserved padding, must be zeroed

; GdkRGBA { float red, green, blue, alpha; }
GDK_RGBA_SIZE                 equ 16

; ---- bits/fcntl-linux.h: open() flags (stable x86-64 Linux values) ------
O_RDONLY                      equ 0
O_WRONLY                      equ 1
O_RDWR                        equ 2
O_CREAT                       equ 64     ; 0100 octal
O_TRUNC                       equ 512    ; 01000 octal

; ---- unistd.h: lseek() whence -------------------------------------------
SEEK_SET                      equ 0
SEEK_CUR                      equ 1
SEEK_END                      equ 2

; default mode for newly created files: rw-r--r--
FILE_CREATE_MODE              equ 420    ; 0644 octal

; window-title scratch buffer; 1024 comfortably covers a 255-byte (max
; POSIX filename) basename plus the " - UnbloatedPad" suffix.
TITLE_BUF_SIZE                 equ 1024

; ---- gtk/gtktextiter.h: GtkTextSearchFlags ------------------------------
GTK_TEXT_SEARCH_TEXT_ONLY      equ 2

; last-search-term scratch buffer (Edit > Find / Find Next / Replace)
FIND_TEXT_SIZE                  equ 256

; ---- gtk/gtkenums.h: GtkAlign -------------------------------------------
GTK_ALIGN_START                 equ 1

; ---- adw-style-manager.h: AdwColorScheme --------------------------------
ADW_COLOR_SCHEME_DEFAULT        equ 0
ADW_COLOR_SCHEME_FORCE_LIGHT    equ 1
ADW_COLOR_SCHEME_FORCE_DARK     equ 4

; ---- gtk/gtkstyleprovider.h: style provider priority --------------------
GTK_STYLE_PROVIDER_PRIORITY_APPLICATION equ 600

FONT_CSS_BUF_SIZE                equ 512
STATUS_BUF_SIZE                  equ 64
FONT_DESC_STR_SIZE                equ 128

; position of the Dark Mode item within the View submenu (Status Bar=0,
; Dark Mode=1) -- on_dark_mode_activate rewrites the item at this index
; in place to swap its label between "Dark Mode" and "Light Mode"
DARK_MODE_MENU_INDEX               equ 1

; ---- gtk/gtkaboutdialog.h: GtkLicense (reused by AdwAboutDialog) --------
GTK_LICENSE_APACHE_2_0             equ 16

; ---- adw-alert-dialog.h: AdwResponseAppearance --------------------------
ADW_RESPONSE_DESTRUCTIVE           equ 2

; pending action to run once an unsaved-changes prompt is answered
PENDING_NONE  equ 0
PENDING_NEW   equ 1
PENDING_OPEN  equ 2

; readlink("/proc/self/exe", ...) scratch buffer -- 4096 is PATH_MAX on
; Linux; readlink() itself doesn't NUL-terminate or reserve room for a
; suffix, so callers appending after it (window.asm's icon search-path
; setup) pass a shorter byte budget than this to readlink and rely on the
; rest of the buffer as headroom.
EXE_PATH_BUF_SIZE  equ 4096
PENDING_QUIT  equ 3

; ---- glib/gmessages.h: GLogLevelFlags -----------------------------------
G_LOG_LEVEL_WARNING  equ 1 << 4

; error-dialog/log detail scratch buffer (errdlg.asm): holds "<path>: <reason>".
; Sized for PATH_MAX (4096) plus 128 bytes of headroom for the separator and
; strerror()'s message; errdlg.asm caps its first strcopy_bounded call at
; ERROR_BUF_SIZE-128 (reserving that fixed tail) rather than computing the
; exact remaining space, same generous-fixed-budget style as build_title in
; fileio.asm.
ERROR_BUF_SIZE  equ 4096 + 128

; ---- gtk/print/gtkprintoperation.h: GtkPrintOperationAction -------------
GTK_PRINT_OPERATION_ACTION_PRINT_DIALOG  equ 0

; ---- gtk/print/gtkprintoperation.h: GtkPrintOperationResult -------------
GTK_PRINT_OPERATION_RESULT_ERROR  equ 0
GTK_PRINT_OPERATION_RESULT_APPLY  equ 1
