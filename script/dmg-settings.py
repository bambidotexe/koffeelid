# The disk image's window: what it holds, where each icon sits, what is behind them. Read by `dmgbuild`,
# which writes the layout into the image's own .DS_Store — no Finder, no AppleScript, no Automation grant,
# and the same image whoever builds it.
#
# The caller passes `app`, `name`, `background` and optionally `volume_icon` with -D. The icon centres here
# and the ones in `script/dmg-background.swift` are the same two points; change them together or the arrow
# painted on the backdrop stops meeting the icons.

import os.path

application = defines["app"]
app_name = os.path.basename(application)

# What lands on the image: the app itself, and the folder it is meant to be dragged to.
files = [application]
symlinks = {"Applications": "/Applications"}

format = "UDZO"
# Left to dmgbuild: it sizes the image from what it holds.
size = None

# An icon view, with everything Finder would otherwise put around it taken away.
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 128

# 660 × 480 at (200, 200): the canvas `dmg-background.swift` draws. Finder takes its own bars out of that
# height and shows the backdrop from its top-left, so the backdrop keeps everything in its top 340 points and
# the icons, with their labels, end at about 336.
window_rect = ((200, 200), (660, 480))
icon_locations = {app_name: (165, 250), "Applications": (495, 250)}

background = defines["background"]

if defines.get("volume_icon"):
    icon = defines["volume_icon"]
