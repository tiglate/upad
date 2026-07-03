; format.asm -- Format menu (Word Wrap, Font) and the Dark Mode half of the
; View menu. Word Wrap and Dark Mode both flip a boolean; Word Wrap uses
; GTK's own stateful-action/checkbox machinery via the shared
; toggle_bool_action helper, while Dark Mode deliberately does NOT (see
; the comment above on_dark_mode_activate for why) and manages its own
; boolean plus rewrites its own menu label instead. Font goes through the
; GTK 4.10+ async GtkFontDialog and applies the result as a small
; hand-built CSS rule (GtkTextView has no direct "set font" call in GTK4).

%include "consts.inc"          ; GTK_WRAP_*, ADW_COLOR_SCHEME_*, DARK_MODE_MENU_INDEX, FONT_CSS_BUF_SIZE, FONT_DESC_STR_SIZE, GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
%include "callconv.inc"        ; CCALL/ICALL macros
%include "extern.inc"          ; extern declarations for every GTK/GLib/libadwaita/Pango call used below

global on_word_wrap_activate     ; "win.word-wrap" GAction handler (actions.asm)
global on_font_activate          ; "win.font" GAction handler
global on_dark_mode_activate     ; "win.dark-mode" GAction handler
global toggle_bool_action        ; shared by statusbar.asm's on_status_bar_activate too
global itoa_decimal              ; shared by statusbar.asm's update_status_label too
global init_dark_mode_state       ; called once from window.asm, after the menu exists

extern g_window                    ; main.asm -- parent for the font-picker dialog
extern g_textview                  ; main.asm -- Word Wrap acts on this directly
extern strcopy_bounded              ; fileio.asm -- bounded string copy, reused here for building the font CSS string
extern g_view_menu                   ; menu.asm -- the View submenu, rewritten in place to swap the Dark Mode item's label

section .rodata
    ; the three pieces a font's CSS rule is assembled from, around the
    ; family name and point size which get inserted between them --
    ; produces e.g.: textview { font-family: "Monospace"; font-size: 11pt; }
    css_prefix          db 'textview { font-family: "', 0
    css_middle          db '"; font-size: ', 0
    css_suffix          db 'pt; }', 0
    lbl_dark_mode       db "Dark _Mode", 0            ; shown while currently light (click to go dark)
    lbl_light_mode      db "Light _Mode", 0            ; shown while currently dark (click to go light)
    act_dark_mode_detail db "win.dark-mode", 0
    default_font_str    db "Monospace 11", 0            ; opened when Format > Font... has never been used yet this run

section .bss
    align 8
    g_font_css_buf  resb FONT_CSS_BUF_SIZE      ; scratch buffer on_font_chosen formats the CSS rule into
    g_font_dialog   resq 1                       ; GtkFontDialog*, built once and cached (ensure_font_dialog) rather than recreated on every Format > Font...
    g_font_desc_str resb FONT_DESC_STR_SIZE      ; the last-picked font, remembered as Pango's own text form (e.g. "Monospace Bold 12"); empty string until first use
    g_dark_mode_on  resq 1                        ; our own tracked boolean -- 1 = currently forcing dark, 0 = currently forcing light (see on_dark_mode_activate for why this isn't a GAction's built-in state)

section .text

; -------------------------------------------------------------------------
; char *itoa_decimal(char *dest, int value)
; Writes the decimal digits of a non-negative int to dest (no sign
; handling needed anywhere this is used -- line/column numbers and point
; sizes are always >= 0), NUL-terminates, returns pointer to the NUL.
;
; Works in two passes since dividing by 10 naturally produces digits
; least-significant-first: first extract every digit into a small
; reversed scratch buffer, then copy them out in the correct
; (most-significant-first) order.
; -------------------------------------------------------------------------
itoa_decimal:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-32..-1] = up to 32 bytes of reversed-digit scratch (a 32-bit int needs at most 10 decimal digits, so this is comfortably oversized)
    mov  eax, esi                 ; eax = value (the number we're converting)
    xor  ecx, ecx                  ; ecx = digit count extracted so far, starts at 0
.extract:
    xor  edx, edx                  ; clear edx:eax's high half before dividing -- `div` uses the full edx:eax pair as the dividend
    mov  r10d, 10                   ; divisor
    div  r10d                        ; eax = eax/10 (quotient, becomes the remaining value), edx = eax%10 (the digit we just peeled off)
    add  dl, '0'                     ; turn the 0-9 digit into its ASCII character
    mov  [rbp + rcx - 32], dl         ; store it at scratch[ecx] -- least-significant digit ends up at index 0, next at index 1, etc.
    inc  ecx                          ; one more digit extracted
    test eax, eax                      ; anything left to divide?
    jnz  .extract                       ; yes -- extract the next digit
.copy:
    ; ecx currently holds the total digit count; walk it back down to 0,
    ; reading scratch[] from the END (most significant digit) toward the
    ; start, so the output comes out in normal reading order.
    dec  ecx                            ; ecx -> index of the next (more significant) digit to emit
    movzx edx, byte [rbp + rcx - 32]     ; dl = that digit's ASCII character
    mov  [rdi], dl                        ; write it to the caller's dest buffer
    inc  rdi                               ; advance dest
    test ecx, ecx                           ; reached index 0 yet (i.e. was this the last, least-significant digit)?
    jnz  .copy                               ; no -- emit the next one

    mov  byte [rdi], 0                       ; NUL-terminate
    mov  rax, rdi                             ; return value = pointer to that NUL (lets a caller chain more text right after, same convention as strcopy_bounded)
    leave
    ret

; -------------------------------------------------------------------------
; gboolean toggle_bool_action(GSimpleAction *action)
; Flips a stateful boolean GSimpleAction's state and returns the new
; value. Used by any Format/View toggle that's implemented as GTK's own
; checkable-menu-item machinery (Word Wrap here; View > Status Bar in
; statusbar.asm) -- Dark Mode below deliberately does NOT use this, see
; its own comment.
; -------------------------------------------------------------------------
toggle_bool_action:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=action (the incoming arg, saved since every call below is free to clobber rdi)  [rbp-16]=the action's old GVariant state  [rbp-24]=the flipped boolean value (0 or 1)
    mov  [rbp-8], rdi

    CCALL g_action_get_state       ; GVariant *g_action_get_state(GAction*) -- rdi already = action; rax = a NEW reference to its current state we now own
    mov  [rbp-16], rax

    mov  rdi, [rbp-16]              ; arg1 = the state GVariant
    CCALL g_variant_get_boolean       ; gboolean g_variant_get_boolean(GVariant*) -- returns exactly 0 or 1
    xor  eax, 1                        ; flip it: 0<->1 (safe bit-flip since the input is guaranteed to be exactly 0 or 1, not just "any nonzero value")
    mov  [rbp-24], rax                  ; stash the flipped value (zero-extended into the full qword by the 32-bit `xor eax,1` above)

    mov  rdi, [rbp-16]                    ; the state GVariant we fetched
    CCALL g_variant_unref                    ; done with it -- we already extracted the boolean we needed

    mov  edi, [rbp-24]                        ; arg1 = the flipped value
    CCALL g_variant_new_boolean                 ; GVariant *g_variant_new_boolean(gboolean) -- rax = a new floating-reference GVariant wrapping it
    mov  rsi, rax                                ; arg2 (for the call below) = that new GVariant -- captured now, before rdi gets reloaded
    mov  rdi, [rbp-8]                              ; arg1 = the action
    CCALL g_simple_action_set_state                  ; void g_simple_action_set_state(GSimpleAction*, GVariant*) -- consumes the floating reference; this is also what updates the menu item's checkbox rendering automatically

    mov  eax, [rbp-24]                                ; return value = the new boolean, so callers can apply their own side effect without re-querying the action
    leave
    ret

; void on_word_wrap_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
on_word_wrap_activate:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the new (post-toggle) boolean
    ICALL toggle_bool_action       ; rdi already = action (this function's own incoming arg1); flips the checkbox state, returns the new value in eax
    mov  [rbp-8], rax

    mov  rdi, [rel g_textview]      ; arg1 = the text view
    mov  eax, [rbp-8]                ; is word wrap now on or off?
    test eax, eax
    jz   .none
    mov  esi, GTK_WRAP_WORD_CHAR       ; on -> wrap at word boundaries (falling back to mid-word if a single word is wider than the view)
    jmp  .apply
.none:
    mov  esi, GTK_WRAP_NONE              ; off -> lines run off the edge, horizontal scrolling needed to see them
.apply:
    CCALL gtk_text_view_set_wrap_mode      ; void gtk_text_view_set_wrap_mode(GtkTextView*, GtkWrapMode)

    leave
    ret

; Dark Mode is a plain (stateless) action, not a checkbox: instead of a
; fixed label with a checkmark, the View menu item's *text* itself swaps
; between "Dark Mode" and "Light Mode" to name the mode a click switches
; to -- g_dark_mode_on is the state we track ourselves to know which.
;
; void relabel_dark_mode_item(void) -- rewrites the View menu's Dark Mode
; entry to match the current g_dark_mode_on. GMenu items aren't
; individually mutable in place, so "rewriting" one means removing it by
; its index and re-inserting a fresh one at the same index -- see
; DARK_MODE_MENU_INDEX in consts.inc for why that index is always 1.
relabel_dark_mode_item:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- everything below is a global or an immediate,
    ; and the two calls (remove, then insert) don't need anything from
    ; each other beyond g_view_menu/DARK_MODE_MENU_INDEX themselves

    mov  rdi, [rel g_view_menu]        ; arg1 = the View GMenu
    mov  esi, DARK_MODE_MENU_INDEX       ; arg2 = position = 1 (Status Bar is 0)
    CCALL g_menu_remove                    ; void g_menu_remove(GMenu*, gint position) -- deletes the current Dark/Light Mode item

    mov  rdi, [rel g_view_menu]         ; arg1 = the View GMenu (same menu, now one item shorter at this index)
    mov  esi, DARK_MODE_MENU_INDEX        ; arg2 = position = 1 again -- re-insert at the same spot
    mov  rax, [rel g_dark_mode_on]         ; which label matches "currently dark" vs "currently light"?
    test rax, rax
    jz   .relabel_dark                       ; currently light -> offer "Dark Mode" (the action a click takes)
    lea  rdx, [rel lbl_light_mode]            ; currently dark -> offer "Light Mode"
    jmp  .relabel
.relabel_dark:
    lea  rdx, [rel lbl_dark_mode]
.relabel:
    lea  rcx, [rel act_dark_mode_detail]       ; arg4 = detailed action name = "win.dark-mode" (unchanged either way -- only the label text differs)
    CCALL g_menu_insert                          ; void g_menu_insert(GMenu*, gint position, const gchar *label, const gchar *detailed_action)

    pop  rbp
    ret

; void init_dark_mode_state(void) -- call once at startup, after the menu
; is built. AdwStyleManager already follows the desktop's light/dark
; preference by default (ADW_COLOR_SCHEME_DEFAULT), so the app may well
; already be rendering dark before any menu click; this reads that actual
; state so our own bookkeeping -- and the menu label -- start correct
; instead of assuming "always starts light".
init_dark_mode_state:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- the two calls below chain directly through rax

    CCALL adw_style_manager_get_default   ; AdwStyleManager *adw_style_manager_get_default(void) -- the one global style manager instance, no args
    mov  rdi, rax                           ; arg1 = that manager, for the next call
    CCALL adw_style_manager_get_dark          ; gboolean adw_style_manager_get_dark(AdwStyleManager*) -- TRUE if the app is CURRENTLY rendering dark, taking the desktop's own preference into account
    movzx eax, al                              ; zero-extend the gboolean (only al is guaranteed meaningful) into a clean 32-bit value before widening further
    mov  [rel g_dark_mode_on], rax              ; that's our starting g_dark_mode_on -- not hardcoded to 0/light

    ICALL relabel_dark_mode_item                 ; make the menu label match whatever we just found (e.g. if the desktop is already dark, this fixes the label to say "Light Mode" instead of the build-time-hardcoded "Dark Mode")

    pop  rbp
    ret

; Known limitation: AdwStyleManager's FORCE_LIGHT reliably overrides the
; system preference only when the underlying GTK theme is Adwaita itself
; (which has a light+dark pair libadwaita can swap between). If the
; desktop's configured GTK theme is some other inherently-dark theme,
; there is no "light variant" for libadwaita to switch to, so forcing
; light may not fully take even though FORCE_DARK (additive styling)
; always does, and the menu label still updates correctly either way.
; This is standard behavior shared by GTK4/libadwaita apps generally, not
; specific to this one -- fixing it would mean overriding gtk-theme-name
; to plain Adwaita ourselves, which trades that reliability for the
; window no longer necessarily matching the rest of the desktop's theme.
on_dark_mode_activate:
    push rbp
    mov  rbp, rsp
    ; no locals needed -- g_dark_mode_on is a global, and the calls below
    ; don't need anything to survive across each other beyond that

    mov  rax, [rel g_dark_mode_on]     ; current state
    xor  rax, 1                          ; flip it (safe bit-flip -- this value is only ever written as exactly 0 or 1, by this line and by init_dark_mode_state's movzx above)
    mov  [rel g_dark_mode_on], rax        ; store the flipped state -- now "the new state" for everything below

    CCALL adw_style_manager_get_default    ; the one global style manager
    mov  rdi, rax                            ; arg1 = that manager
    mov  rax, [rel g_dark_mode_on]            ; the (already-flipped) new state
    test rax, rax
    jz   .light
    mov  esi, ADW_COLOR_SCHEME_FORCE_DARK        ; now dark -> force dark styling
    jmp  .apply
.light:
    mov  esi, ADW_COLOR_SCHEME_FORCE_LIGHT        ; now light -> force light styling (NOT ADW_COLOR_SCHEME_DEFAULT/"follow system": once the user has explicitly toggled, an explicit override is what matches their click, not silently falling back to whatever the system happens to prefer)
.apply:
    CCALL adw_style_manager_set_color_scheme        ; void adw_style_manager_set_color_scheme(AdwStyleManager*, AdwColorScheme) -- see the Known limitation note above for what this can't always override

    ICALL relabel_dark_mode_item                       ; update the menu item to now offer the OPPOSITE of what we just switched to

    leave
    ret

; -------------------------------------------------------------------------
; void on_font_chosen(GObject *dialog, GAsyncResult *res, gpointer user_data)
; The GAsyncReadyCallback for gtk_font_dialog_choose_font (see
; on_font_activate below). Once the user picks a font: extract its
; family+size, hand-build a CSS rule targeting the text view, load it as
; an application-priority style provider, and remember the pick (as
; Pango's own text form) so the next Font dialog opens pre-selected to it.
; -------------------------------------------------------------------------
on_font_chosen:
    push rbp
    mov  rbp, rsp
    sub  rsp, 48                  ; five local slots:
                                   ; [rbp-8]  = the picked PangoFontDescription* (or NULL)
                                   ; [rbp-16] = its family name (borrowed -- owned by the description, not us)
                                   ; [rbp-24] = its size, converted to whole points
                                   ; [rbp-32] = the GtkCssProvider we build from it
                                   ; [rbp-40] = the description's own text-form string (owned, must g_free) -- see the note further down for why this needs its own slot rather than reusing a register

    xor  edx, edx                 ; arg3 = error = NULL, not inspected
    CCALL gtk_font_dialog_choose_font_finish   ; PangoFontDescription *gtk_font_dialog_choose_font_finish(GtkFontDialog*, GAsyncResult*, GError**) -- source(rdi)/res(rsi) already positioned correctly, same as fileio.asm's *_finish calls
    mov  [rbp-8], rax
    test rax, rax
    jz   .done                    ; cancelled or errored -- nothing to apply

    ; --- pull the family name and point size out of the description ----
    mov  rdi, rax                   ; arg1 = the description
    CCALL pango_font_description_get_family   ; const char *pango_font_description_get_family(const PangoFontDescription*) -- borrowed pointer, valid as long as the description itself is (we free the description near the end of this function, after we're done needing this)
    mov  [rbp-16], rax

    mov  rdi, [rbp-8]                 ; arg1 = the description
    CCALL pango_font_description_get_size      ; gint pango_font_description_get_size(const PangoFontDescription*) -- Pango sizes are in 1024ths of a point, not whole points
    mov  ecx, eax                       ; stash the raw Pango size (32-bit) before the div below clobbers eax/edx
    xor  edx, edx                        ; clear the high half of the dividend for `div`
    mov  eax, ecx                         ; eax = the raw size again, now safe to divide
    mov  r10d, 1024
    div  r10d                              ; eax = points (integer division -- fractional points are simply dropped, matching classic Notepad's own integer-point font sizes)
    mov  [rbp-24], rax                       ; stash the whole-point size (zero-extended by the 32-bit division result)

    ; --- build the CSS rule: textview { font-family: "FAMILY"; font-size: Npt; } ---
    ; each strcopy_bounded/itoa_decimal call below returns a pointer to
    ; where it left off, chaining into the next call's `dest` -- same
    ; pattern as fileio.asm's build_title.
    lea  rdi, [rel g_font_css_buf]        ; dest = start of scratch buffer
    lea  rsi, [rel css_prefix]             ; src = 'textview { font-family: "'
    mov  rdx, 64
    ICALL strcopy_bounded
    mov  rdi, rax                            ; dest = continue right after the prefix
    mov  rsi, [rbp-16]                        ; src = the family name
    mov  rdx, 200                              ; generous bound -- family names are always far shorter than this
    ICALL strcopy_bounded
    mov  rdi, rax                               ; dest = continue after the family name
    lea  rsi, [rel css_middle]                   ; src = '"; font-size: '
    mov  rdx, 32
    ICALL strcopy_bounded
    mov  rdi, rax                                  ; dest = continue after that
    mov  esi, [rbp-24]                               ; value = the point size (32-bit load of the stashed size)
    ICALL itoa_decimal                                ; writes the digits
    mov  rdi, rax                                      ; dest = continue after the digits
    lea  rsi, [rel css_suffix]                           ; src = 'pt; }'
    mov  rdx, 16
    ICALL strcopy_bounded                                  ; g_font_css_buf now holds the complete CSS rule, NUL-terminated

    ; --- load it as a style provider ------------------------------------
    CCALL gtk_css_provider_new              ; GtkCssProvider *gtk_css_provider_new(void)
    mov  [rbp-32], rax

    mov  rdi, [rbp-32]                        ; arg1 = the provider
    lea  rsi, [rel g_font_css_buf]              ; arg2 = the CSS text we just built
    CCALL gtk_css_provider_load_from_string       ; void gtk_css_provider_load_from_string(GtkCssProvider*, const char*)

    CCALL gdk_display_get_default                  ; GdkDisplay *gdk_display_get_default(void) -- the one display this process is connected to
    mov  rdi, rax                                    ; arg1 = that display
    mov  rsi, [rbp-32]                                ; arg2 = the provider
    mov  edx, GTK_STYLE_PROVIDER_PRIORITY_APPLICATION   ; arg3 = priority -- high enough to override the theme's own textview styling, low enough that a user's own GTK_STYLE_PROVIDER_PRIORITY_USER CSS could still win
    CCALL gtk_style_context_add_provider_for_display       ; void gtk_style_context_add_provider_for_display(GdkDisplay*, GtkStyleProvider*, guint priority) -- applies globally to every "textview" selector match on this display, which in this single-window app means just our one text view

    mov  rdi, [rbp-32]                                       ; the provider
    CCALL g_object_unref                                        ; drop our own ref -- the display now holds its own, keeping the CSS rule live

    ; --- remember this pick as plain text ("Monospace Bold 12") so the -----
    ;     next Format > Font... opens pre-selected to it instead of blank ---
    mov  rdi, [rbp-8]                          ; arg1 = the description
    CCALL pango_font_description_to_string        ; char *pango_font_description_to_string(const PangoFontDescription*) -- rax = a NEWLY-ALLOCATED string we now own (distinct from get_family's borrowed pointer above)
    mov  [rbp-40], rax            ; preserve the owned pointer in its OWN stack slot -- strcopy_bounded below
                                   ; advances its own copy of it in rsi as it scans character by
                                   ; character, so by the time strcopy_bounded returns, rsi no
                                   ; longer points at the start of the allocation. Freeing THAT
                                   ; (moved-forward) pointer instead of the original would corrupt
                                   ; the heap -- this is exactly the bug that was caught and fixed
                                   ; during development, hence the extra slot instead of reusing a register.
    mov  rsi, rax                    ; src = the description's text form (still the original start, fine to hand to strcopy_bounded which will advance its OWN copy)
    lea  rdi, [rel g_font_desc_str]   ; dest = the persistent "remembered pick" buffer
    mov  rdx, FONT_DESC_STR_SIZE
    ICALL strcopy_bounded
    mov  rdi, [rbp-40]                   ; the ORIGINAL pointer from pango_font_description_to_string, read back from its dedicated slot -- NOT rsi/rax, which have both moved on
    CCALL g_free                            ; release the string pango_font_description_to_string allocated, now that we've copied what we need out of it

    mov  rdi, [rbp-8]                          ; the description itself
    CCALL pango_font_description_free             ; done with it entirely now

.done:
    leave
    ret

; gboolean filter_monospace(gpointer item, gpointer user_data)
; GtkFontDialog's font list isn't documented as being one specific Pango
; type, so this checks at runtime: if item is a PangoFontFace, resolve it
; to its family first; otherwise assume item is already a PangoFontFamily.
; Only monospace families pass -- keeps the picker relevant for a text
; editor and (fewer faces to enumerate/preview) shortens how long the
; dialog takes to open.
filter_monospace:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = item (the incoming arg, saved since the type-check call below is free to clobber rdi)
    mov  [rbp-8], rdi

    ; is `item` a PangoFontFace? (g_type_check_instance_is_a is the
    ; runtime equivalent of the PANGO_IS_FONT_FACE() macro)
    CCALL pango_font_face_get_type      ; GType pango_font_face_get_type(void) -- the numeric type ID for PangoFontFace
    mov  rsi, rax                          ; arg2 (for the next call) = that type ID -- captured now, before rdi is reloaded below
    mov  rdi, [rbp-8]                        ; arg1 = item
    CCALL g_type_check_instance_is_a            ; gboolean g_type_check_instance_is_a(GTypeInstance*, GType) -- TRUE if item really is (or derives from) a PangoFontFace
    test eax, eax
    jz   .is_family                                ; not a face -- assume it's already a PangoFontFamily

    ; it IS a face -- resolve it to its owning family first
    mov  rdi, [rbp-8]                                ; arg1 = the face
    CCALL pango_font_face_get_family                    ; PangoFontFamily *pango_font_face_get_family(PangoFontFace*) -- borrowed pointer
    mov  rdi, rax                                          ; use that family as the argument to the monospace check below
    jmp  .check
.is_family:
    mov  rdi, [rbp-8]                                        ; item was already a family -- use it directly
.check:
    CCALL pango_font_family_is_monospace                        ; gboolean pango_font_family_is_monospace(PangoFontFamily*) -- this IS the filter's actual TRUE/FALSE verdict, left in eax as our own return value
    leave
    ret

; void ensure_font_dialog(void) -- builds+caches g_font_dialog (with the
; monospace filter already installed) once; a no-op on later calls, which
; is also what keeps re-opening the picker fast after the first time.
ensure_font_dialog:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                  ; [rbp-8]=the new GtkFontDialog (only used on the build path)  [rbp-16]=the GtkCustomFilter we attach to it
    mov  rax, [rel g_font_dialog]
    test rax, rax
    jz   .build                    ; not built yet -- fall through
    leave                            ; already built -- nothing to do (still need `leave` here since we DID `sub rsp,32` above, unlike window.asm's ensure_main_window which never allocates a frame on its early-return path)
    ret
.build:
    CCALL gtk_font_dialog_new       ; GtkFontDialog *gtk_font_dialog_new(void)
    mov  [rbp-8], rax
    mov  [rel g_font_dialog], rax    ; cache it globally -- this is what makes ensure_font_dialog's later calls no-ops

    ; wrap filter_monospace as a GtkFilter object GtkFontDialog can use
    lea  rdi, [rel filter_monospace]  ; arg1 = the predicate function
    xor  esi, esi                       ; arg2 = user_data = NULL (filter_monospace doesn't need any)
    xor  edx, edx                        ; arg3 = user_destroy = NULL (nothing to free when the filter itself is destroyed)
    CCALL gtk_custom_filter_new             ; GtkCustomFilter *gtk_custom_filter_new(GtkCustomFilterFunc, gpointer, GDestroyNotify)
    mov  [rbp-16], rax

    mov  rdi, [rbp-8]                          ; arg1 = the font dialog
    mov  rsi, [rbp-16]                          ; arg2 = the filter
    CCALL gtk_font_dialog_set_filter               ; void gtk_font_dialog_set_filter(GtkFontDialog*, GtkFilter*) -- takes its own reference

    mov  rdi, [rbp-16]                                ; our own reference to the filter
    CCALL g_object_unref                                 ; no longer needed -- the dialog now owns the one that matters

    leave
    ret

; void on_font_activate(GSimpleAction *action, GVariant *parameter, gpointer user_data)
on_font_activate:
    push rbp
    mov  rbp, rsp
    sub  rsp, 16                  ; [rbp-8] = the initial_value PangoFontDescription* we build below, to pre-select the dialog
    ICALL ensure_font_dialog        ; build (or confirm already-built) g_font_dialog

    ; --- decide what to pre-select: the remembered pick, or a sane default ---
    movzx eax, byte [rel g_font_desc_str]   ; peek at the first byte -- empty string (NUL) means "nothing picked yet this run"
    test al, al
    jnz  .have_remembered
    lea  rdi, [rel default_font_str]      ; nothing picked yet -- open on a
    jmp  .parse                           ; sane monospace choice, not blank
.have_remembered:
    lea  rdi, [rel g_font_desc_str]         ; use whatever was picked last time
.parse:
    CCALL pango_font_description_from_string  ; PangoFontDescription *pango_font_description_from_string(const char*) -- parses the text form back into a real description object; rax = a new one we own
    mov  [rbp-8], rax
.choose:
    ; --- show the picker (async) ----------------------------------------
    mov  rdi, [rel g_font_dialog]     ; arg1 = self
    mov  rsi, [rel g_window]           ; arg2 = parent
    mov  rdx, [rbp-8]                   ; arg3 = initial_value = the description we just parsed
    xor  ecx, ecx                        ; arg4 = cancellable = NULL
    lea  r8, [rel on_font_chosen]         ; arg5 = callback
    xor  r9, r9                            ; arg6 = user_data = NULL
    CCALL gtk_font_dialog_choose_font        ; void gtk_font_dialog_choose_font(GtkFontDialog*, GtkWindow *parent, PangoFontDescription *initial_value, GCancellable*, GAsyncReadyCallback, gpointer) -- six arguments, one more than GtkFileDialog's open/save (an earlier version of this function miscounted them and passed the callback where cancellable belongs -- a real bug caught during testing)

    ; deliberately not freeing [rbp-8]'s PangoFontDescription here: GTK
    ; docs don't guarantee it's done with initial_value the instant this
    ; call returns (choose_font is async), and it's a handful of bytes --
    ; a tiny leak beats a use-after-free.

    leave
    ret
