status is-interactive; or return

if not set -q STARSHIP_CONFIG
    if not test -f "$HOME/.config/starship.toml"
        if not set -q XDG_CONFIG_HOME; or not test -f "$XDG_CONFIG_HOME/starship.toml"
            set -gx STARSHIP_CONFIG /usr/share/gilgamesh/fish/starship.toml
        end
    end
end
source /usr/share/gilgamesh/fish/colors.fish
source /usr/share/gilgamesh/fish/prompt.fish
source /usr/share/gilgamesh/fish/greeting.fish
source /usr/share/gilgamesh/fish/starship-init.fish
