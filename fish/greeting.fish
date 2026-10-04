# Gilgamesh greeting: fastfetch with the logo instead of fish's "Welcome to fish" text.
# fish only runs fish_greeting in interactive shells, so scripts never see it. It's also
# skipped in shells started from another one (`fish` inside fish, nvim's terminal...), tmux
# panes and ssh sessions, where it would just be noise. Your own fish_greeting in config.fish
# replaces this one.
function fish_greeting
    set -q __gilgamesh_greeted; and return
    set -gx __gilgamesh_greeted 1        # inherited by everything started from this shell
    set -q TMUX; and return
    set -q SSH_CONNECTION; and return
    command -q fastfetch; and fastfetch
end
