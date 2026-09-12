# Book source card layout cleanup

## Goal

Keep source names, descriptions, health state, login state, and groups readable
on narrow phones without changing card behavior.

## Plan

1. Keep the leading icon or selection checkbox in a fixed 40 px slot and give
   the source name and description the remaining header width.
2. Move metadata into its own wrapping row so favorite, enabled, and menu
   controls cannot squeeze it.
3. Move favorite and enabled controls into a separate footer row. Keep the
   shared popup menu as a plain three-dot trigger at the header edge.
4. Add narrow-screen and large-text regression tests covering long labels,
   selection, favorite, enabled, and menu behavior.
5. Render light and dark previews with a real Chinese font and inspect them for
   clipping or overflow.
