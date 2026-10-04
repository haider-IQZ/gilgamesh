-- Gilgamesh Hyprland config (Lua, Hyprland 0.55+)
-- Your own changes go in local.lua next to this file (loaded last, optional), so updates to this
-- file never clash with them.

local mod = "SUPER"

---- MONITORS ----
-- whatever the monitor prefers, integer scale (fractional scaling costs GPU time)
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

---- ENVIRONMENT ----
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")
hl.env("XCURSOR_SIZE", "24")
-- No NVIDIA variables needed: modeset/fbdev are on by default (driver 560+) and Hyprland
-- already uses GBM, which is all GBM_BACKEND/__GLX_VENDOR_LIBRARY_NAME would force.

---- INPUT ----
hl.config({
    input = {
        kb_layout = "us",          -- the installer writes your layout to local.lua
        follow_mouse = 1,
        sensitivity = 0,           -- no mouse acceleration: flat profile + unscaled motion (libinput settings, so touchpads too)
        accel_profile = "flat",
        repeat_delay = 200,        -- a held key repeats after 200 ms, 35 times a second
        repeat_rate = 35,
    },
})

---- LOOK AND FEEL ----
hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 8,
        border_size = 0,
        layout = "dwindle",
        allow_tearing = true,      -- global switch: games get it via the "immediate" rule below; apps that ask for tearing themselves may too
    },
    decoration = {
        rounding = 6,
        blur = { enabled = true, ignore_opacity = true },
        shadow = { enabled = false },
    },
    render = {
        direct_scanout = 2,        -- fullscreen games skip compositing (content type "game" only)
    },
    misc = {
        vrr = 3,                   -- adaptive sync for fullscreen games and video only
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
    },
    animations = { enabled = true },
})

hl.curve("overshot", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.05 } } })
hl.curve("smoothOut", { type = "bezier", points = { { 0.36, 0 }, { 0.66, -0.56 } } })
hl.curve("smoothIn", { type = "bezier", points = { { 0.25, 0.1 }, { 0.25, 1 } } })
hl.animation({ leaf = "windows", enabled = true, speed = 1, bezier = "overshot", style = "slide" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1, bezier = "smoothOut", style = "slide" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 1, bezier = "default" })
hl.animation({ leaf = "fade", enabled = true, speed = 2, bezier = "smoothIn" })
hl.animation({ leaf = "fadeDim", enabled = true, speed = 2, bezier = "smoothIn" })
hl.animation({ leaf = "workspaces", enabled = false, speed = 1, bezier = "default" })

---- RULES ----
hl.window_rule({
    name = "gilgamesh-settings",
    match = { title = "^(Gilgamesh Settings)$" },
    float = true,
    center = true,
    size = { 960, 640 },
})

-- Games: tear instead of waiting for vsync (lowest input latency), and mark them as "game" content.
-- Hyprland only does direct scanout and VRR for game/video content, and nothing in the
-- Proton/XWayland path reports it, so without this those two never turn on.
hl.window_rule({ name = "games-x", match = { class = "^steam_app_.*" }, immediate = true, content = "game" })
hl.window_rule({ name = "games-wl", match = { xdg_tag = "^proton-game$" }, immediate = true, content = "game" })

---- AUTOSTART ----
hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
    hl.exec_cmd("qs -d -n")                                   -- the Gilgamesh bar
    hl.exec_cmd("systemctl --user start hyprpolkitagent")     -- password prompts for apps
end)

---- KEYBINDINGS ----
-- apps
hl.bind(mod .. " + Q", hl.dsp.exec_cmd("foot"))
hl.bind(mod .. " + X", hl.dsp.exec_cmd("firefox"))
hl.bind(mod .. " + E", hl.dsp.exec_cmd("nautilus"))
hl.bind(mod .. " + D", hl.dsp.exec_cmd("qs ipc call launcher toggle"))   -- launcher + menu
hl.bind(mod .. " + W", hl.dsp.exec_cmd("qs ipc call wallpaper pick"))    -- wallpaper picker
hl.bind(mod .. " + SHIFT + R", hl.dsp.exec_cmd("pkill -x qs; pkill -x quickshell; sleep 1; qs -d -n"))  -- restart the bar (-x: exact process name; -f would match this shell's own command line)

-- media keys go to whatever the bar shows as playing
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("qs ipc call media playPause"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("qs ipc call media playPause"), { locked = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("qs ipc call media next"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("qs ipc call media previous"), { locked = true })

-- screenshots to the clipboard: Print = select an area, Shift+Print = whole screen
hl.bind("Print", hl.dsp.exec_cmd("sh -c 'grim -g \"$(slurp)\" - | wl-copy'"))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("sh -c 'grim - | wl-copy'"))

-- windows
hl.bind(mod .. " + C", hl.dsp.window.close())
hl.bind(mod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mod .. " + S", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind(mod .. " + H", hl.dsp.focus({ direction = "l" }))
hl.bind(mod .. " + J", hl.dsp.focus({ direction = "d" }))
hl.bind(mod .. " + K", hl.dsp.focus({ direction = "u" }))
hl.bind(mod .. " + L", hl.dsp.focus({ direction = "r" }))
hl.bind(mod .. " + SHIFT + H", hl.dsp.window.move({ direction = "l" }))
hl.bind(mod .. " + SHIFT + J", hl.dsp.window.move({ direction = "d" }))
hl.bind(mod .. " + SHIFT + K", hl.dsp.window.move({ direction = "u" }))
hl.bind(mod .. " + SHIFT + L", hl.dsp.window.move({ direction = "r" }))

-- workspaces 1-10
for i = 1, 10 do
    local key = i % 10
    hl.bind(mod .. " + " .. key, hl.dsp.focus({ workspace = i }))
    hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

---- YOUR CHANGES ----
pcall(require, "local")
