# Console-viewer viewport patch - SPEC (author: easy-for-gaokun research)

Target:   plymouth 24.004.60+git20250831.4a3c171d-0ubuntu8 (Ubuntu 26.04, arm64)
Upstream: gitlab.freedesktop.org/plymouth/plymouth, branch `main`
Purpose:  let a `script` theme pin the boot-log viewport to the bottom-left of
          the screen and to a fixed number of lines, instead of the hardcoded
          "one label per text row, whole screen, anchored top-left" behaviour.

## WHY A PATCH IS NEEDED

`ply_console_viewer_new()` derives its geometry from the display and nothing
else (ply-console-viewer.c:119-124):

    console_viewer->line_max_chars = ply_pixel_display_get_width (display)
                                     / console_viewer->font_width - 1;
    line_count = ply_pixel_display_get_height (display)
                 / console_viewer->font_height;

and `ply_console_viewer_show()` anchors every label at the top-left
(ply-console-viewer.c:274-276):

    ply_label_show (console_message_label, console_viewer->display,
                    console_viewer->font_width / 2,
                    console_viewer->font_height * label_index);

On a 1600x2560 panel with `MonospaceFont=Ubuntu Mono 11` that is ~105 labels
filling the whole display.  There is no config key, and the script language
cannot reach the console viewer, so the geometry has to come from C.

The good news: the *scrolling* half already works.  `update_console_messages()`
keeps only the newest `visible_line_count` lines (lines 185-247), which is
exactly "new lines push the old ones up".  Only the viewport is missing.

## Preferred approach for this project

Do NOT carry a patch.  Fork `src/libply-splash-graphics/ply-console-viewer.[ch]`
into `drivers/plymouth/` (or `src/`) inside this repo and edit the fork; then
ship a small wrapper that builds only that piece against the distro headers.
The two edits below are the entire behavioural delta either way.

--------------------------------------------------------------------------------

## EDIT 1 - src/libply-splash-graphics/ply-console-viewer.h

After the existing `ply_console_viewer_set_text_color` declaration
(currently line 46-47), append:

    void ply_console_viewer_set_viewport (ply_console_viewer_t *console_viewer,
                                          long                  x,
                                          long                  y);
    void ply_console_viewer_set_line_count (ply_console_viewer_t *console_viewer,
                                            size_t                line_count);

--------------------------------------------------------------------------------

## EDIT 2 - src/libply-splash-graphics/ply-console-viewer.c

(2a) struct _ply_console_viewer (after the existing `uint32_t text_color;`,
     currently line 54) - add two fields:

    long                     viewport_x;
    long                     viewport_y;

(2b) ply_console_viewer_new() initialises them (currently lines 103-108):

    console_viewer = calloc (1, sizeof(struct _ply_console_viewer));

    console_viewer->message_labels = ply_list_new ();
    console_viewer->is_hidden = true;
    console_viewer->viewport_x = 0;
    console_viewer->viewport_y = 0;

    console_viewer->font = strdup (font);

(2c) ply_console_viewer_new() honours a pre-set line count, so the plugin can
     call `ply_console_viewer_set_line_count()` before constructing it.  A
     static "requested" holder is ugly; the clean way is to give
     ply_console_viewer_new() an extra parameter.  Change the signature to

        ply_console_viewer_t *
        ply_console_viewer_new (ply_pixel_display_t *display,
                                const char          *font,
                                size_t               line_count)

     and replace the body of the geometry block (currently lines 118-134) with:

    /* Allow the label to be the size of how many characters can fit in the
       width of the screen, minus one for larger fonts that have some size
       overhead */
    console_viewer->line_max_chars = ply_pixel_display_get_width (display)
                                     / console_viewer->font_width - 1;

    if (line_count == 0) {
            line_count = ply_pixel_display_get_height (display)
                         / console_viewer->font_height;
    }

    /* Display at least one line */
    if (line_count == 0)
            line_count = 1;

    ply_label_free (measure_label);

    for (size_t label_index = 0; label_index < line_count; label_index++) {
            console_message_label = ply_label_new ();
            ply_label_set_font (console_message_label, console_viewer->font);
            ply_list_append_data (console_viewer->message_labels,
                                  console_message_label);
    }

    console_viewer->terminal_emulator =
            ply_terminal_emulator_new (line_count,
                                       console_viewer->line_max_chars);

(2d) ply_console_viewer_show() honours the viewport
     (currently lines 270-279):

    label_index = 0;
    ply_list_foreach (console_viewer->message_labels, node) {
            ply_label_t *console_message_label;
            console_message_label = ply_list_node_get_data (node);
            ply_label_show (console_message_label, console_viewer->display,
                            console_viewer->viewport_x

                                    + console_viewer->font_width / 2,

                            console_viewer->viewport_y

                                    + console_viewer->font_height * label_index);

            ply_label_set_hex_color (console_message_label, label_color);
            label_index++;
    }

(2e) ply_console_viewer_draw_area() clips to the viewport
     (currently lines 302-311):

    label_index = 0;
    ply_list_foreach (console_viewer->message_labels, node) {
            console_message_label = ply_list_node_get_data (node);
            ply_label_draw_area (console_message_label, buffer,
                                 MAX (x, console_viewer->viewport_x

                                             + console_viewer->font_width / 2),

                                 MAX (y, console_viewer->viewport_y

                                             + console_viewer->font_height
                                                     + label_index),

                                 MIN (ply_label_get_width (console_message_label),
                                      width),
                                 MIN (height, console_viewer->font_height));
            label_index++;
    }

(2f) new setters at the end of the file:

    void
    ply_console_viewer_set_viewport (ply_console_viewer_t *console_viewer,
                                     long                  x,
                                     long                  y)
    {
            console_viewer->viewport_x = x;
            console_viewer->viewport_y = y;
    }

    void
    ply_console_viewer_set_line_count (ply_console_viewer_t *console_viewer,
                                       size_t                line_count)
    {
            (void) console_viewer;
            (void) line_count;
            /* Line count is fixed at construction time (see ply_console_viewer_new). */
    }

--------------------------------------------------------------------------------

## EDIT 3 - src/plugins/splash/script/plugin.c

(3a) struct _ply_boot_splash_plugin (currently lines 100-106) - add:

    long                          console_viewport_x;
    long                          console_viewport_y;
    size_t                        console_line_count;

(3b) create_plugin() reads the new keys (currently lines 235-243):

    plugin->console_text_color =
            ply_key_file_get_ulong (key_file, "script",
                                    "ConsoleLogTextColor",
                                    PLY_CONSOLE_VIEWER_LOG_TEXT_COLOR);

    plugin->console_background_color =
            ply_key_file_get_ulong (key_file, "script",
                                    "ConsoleLogBackgroundColor",
                                    0x00000000);

    plugin->console_line_count =
            ply_key_file_get_integer (key_file, "script",
                                      "ConsoleLogLineCount",
                                      0);

    plugin->console_viewport_x =
            ply_key_file_get_integer (key_file, "script",
                                      "ConsoleLogViewportX",
                                      0);

    plugin->console_viewport_y =
            ply_key_file_get_integer (key_file, "script",
                                      "ConsoleLogViewportY",
                                      0);

(3c) start_script_animation(): pass the line count.  Because the viewport/line
     count is known here but the display is created later in
     script_lib_sprite_setup(), pass both through that function.  Simplest
     minimal edit: extend script_lib_sprite_setup() with the three extra
     arguments and forward them to ply_console_viewer_new() /
     ply_console_viewer_set_viewport() in add_display()
     (script-lib-sprite.c:543-568):

    if (ply_console_viewer_preferred ()) {
            script_display->console_viewer =
                    ply_console_viewer_new (script_display->pixel_display,
                                            data->monospace_font,
                                            data->console_line_count);
            ply_console_viewer_set_text_color (script_display->console_viewer,
                                               data->console_text_color);
            ply_console_viewer_set_viewport (script_display->console_viewer,
                                             data->console_viewport_x,
                                             data->console_viewport_y);

            if (data->boot_buffer)
                    ply_console_viewer_convert_boot_buffer (
                            script_display->console_viewer, data->boot_buffer);
    } else {
            script_display->console_viewer = NULL;
    }

(3d) The background fill that `update_console_messages()` triggers
     (script-lib-sprite.c:415-416) fills the WHOLE clip area with
     console_background_color whenever should_show_console_messages is true.
     For a bottom-left panel you want it restricted to the viewport, so change
     that call site to a rectangle:

    if (data->should_show_console_messages) {
            ply_rectangle_t viewport = {
                    .x      = data->console_viewport_x,
                    .y      = data->console_viewport_y,
                    .width  = data->console_viewport_width,
                    .height = data->console_line_count * font_height,
            };
            ply_pixel_buffer_fill_with_hex_color (pixel_buffer, &viewport,
                                                  data->console_background_color);
    }

     (needs `console_viewport_width`/`font_height` plumbed the same way; a
      simpler alternative is to set ConsoleLogBackgroundColor=0x00000000 and
      keep the logo on a black Window background, which is what the shipped
      theme does.)

--------------------------------------------------------------------------------

## NEW CONFIG KEYS AFTER THE PATCH

[script]
ConsoleLogLineCount   = 3      ; 0 = fill the screen (old behaviour)
ConsoleLogViewportX   = 48     ; top-left of the log block, scanout coords
ConsoleLogViewportY   = 2200   ; 2560 - 3*font_height - 48 for 3 lines
ConsoleLogBackgroundColor = 0x00000000

Because the DRM scanout is the native 1600x2560 portrait buffer, "bottom-left"
on this device is the LARGE-Y, SMALL-X corner of the scanout - i.e.
ViewportY near 2560, ViewportX near 0 - which lands bottom-left on the glass
once the theme's rotation compensation is taken into account.  Verify visually:
see RESEARCH.md section 4 for the two-line A/B procedure.

--------------------------------------------------------------------------------

## RISK

Priority: LOW-MEDIUM.

+ The only concurrency-sensitive part is the existing console-viewer API; the

  patch adds no new threads, fds or allocations beyond what already exists.

+ `ply_console_viewer_new()` gains a parameter, so the patch MUST be applied to

  script.so, console-viewer.so and libply-splash-graphics together.  Mixing a
  patched script.so with an unpatched library gives a runtime symbol mismatch.

+ Plymouth's own fallback is unaffected: if the theme fails to load, plymouthd

  falls back to `text.plymouth` / `details` (see RESEARCH.md section 6).
