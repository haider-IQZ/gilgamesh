# Empty line after each command's output, so commands don't blur together.
# (Done here instead of starship's add_newline, which also puts a blank line
# at the very top of a fresh terminal.)
function __gilgamesh_spacing --on-event fish_postexec
    echo
end
