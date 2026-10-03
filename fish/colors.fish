# Gilgamesh fish colors, from the current theme (Gilgamesh Settings → Theme).
# The bar writes the theme's colors to $XDG_STATE_HOME/gilgamesh/theme/; this loads them,
# and loads them again in every open shell when you switch themes (the bar sets the
# universal variable gilgamesh_theme). starship and fzf read their theme file themselves.

set -g __gilgamesh_theme_dir (set -q XDG_STATE_HOME; and echo $XDG_STATE_HOME; or echo ~/.local/state)/gilgamesh/theme

function __gilgamesh_load_theme
    set -l dir $__gilgamesh_theme_dir
    if test -f $dir/colors.fish
        source $dir/colors.fish
    else
        # no theme written yet: jellybeans, the default
        set -g fish_color_normal e8e8d3
        set -g fish_color_command 99ad6a           # green: commands
        set -g fish_color_keyword 9b859d           # purple: if, for, function...
        set -g fish_color_param e8e8d3             # arguments
        set -g fish_color_quote fad07a             # yellow: "strings"
        set -g fish_color_redirection 5fb0b0       # cyan: > < |
        set -g fish_color_end 5fb0b0               # ; &
        set -g fish_color_operator 597bc5          # blue: * ~ $var
        set -g fish_color_escape 5fb0b0            # \n etc.
        set -g fish_color_error cf6a4c             # red: unknown command
        set -g fish_color_comment 888888 --italics
        set -g fish_color_valid_path --underline   # paths that exist
        set -g fish_color_autosuggestion 555555    # dim gray suggestion
        set -g fish_color_selection --background=2a2a2a
        set -g fish_color_search_match --background=2a2a2a
        set -g fish_pager_color_prefix fad07a --bold
        set -g fish_pager_color_completion e8e8d3
        set -g fish_pager_color_description 888888
        set -g fish_pager_color_progress 597bc5
        set -g fish_pager_color_selected_background --background=2a2a2a
    end
    # the prompt and fzf in the theme's colors (both re-read the file every time)
    test -f $dir/starship.toml; and set -gx STARSHIP_CONFIG $dir/starship.toml
    test -f $dir/fzf; and set -gx FZF_DEFAULT_OPTS_FILE $dir/fzf
end

function __gilgamesh_theme_changed --on-variable gilgamesh_theme
    __gilgamesh_load_theme
end

__gilgamesh_load_theme
