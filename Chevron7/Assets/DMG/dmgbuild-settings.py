# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# dmgbuild settings for the release DMG (package-release.sh passes -D app=...
# and -D assets=<this folder>; dmgbuild gives a settings file no __file__).
# The icon centres must match APP_CENTER and APPLICATIONS_CENTER in
# scripts/make-dmg-background.py, which draws the arrow between them.
import os.path

assets = defines["assets"]  # noqa: F821 (dmgbuild global)
app = defines["app"]  # noqa: F821
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "Chevron7.icns")

# dmgbuild combines background.png with background@2x.png into one HiDPI TIFF.
background = os.path.join(assets, "background.png")
# Finder counts its title bar (about 30 pt) in the window height, so this
# leaves the 400 pt picture whole below it.
window_rect = ((200, 120), (660, 430))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (165, 180),
    "Applications": (495, 180),
}
