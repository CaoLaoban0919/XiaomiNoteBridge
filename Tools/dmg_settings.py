"""dmgbuild 配置：标准「拖进 Applications」布局。

为什么不用 Finder 脚本：从命令行控制 Finder 需要系统自动化授权，
在脚本里拿不到（-10004 权限违例）。dmgbuild 直接写 .DS_Store，绕开这层。
"""

app_path = "build/MiNoteBridge.app"
volume_name = "米记桥"

files = [app_path]
symlinks = {"Applications": "/Applications"}

# 图标位置：左 App、右 Applications，中间留出拖拽距离
icon_locations = {
    "MiNoteBridge.app": (160, 180),
    "Applications": (440, 180),
}

window_rect = ((120, 120), (560, 380))
default_view = "icon-view"
icon_size = 96
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
