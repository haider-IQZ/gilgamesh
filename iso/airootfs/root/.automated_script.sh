#!/usr/bin/env bash

script_cmdline() {
    local param
    for param in $(</proc/cmdline); do
        case "${param}" in
            script=*)
                echo "${param#*=}"
                return 0
                ;;
        esac
    done
}

automated_script() {
    local script rt
    script="$(script_cmdline)"
    if [[ -n "${script}" && ! -x /tmp/startup_script ]]; then
        if [[ "${script}" =~ ^((http|https|ftp|tftp)://) ]]; then
            printf '%s: downloading %s\n' "$0" "${script}"
            # there's no synchronization for network availability before executing this script; to ensure the network
            # is online, we use a transient systemd service that depends on network-online.target to download the
            # script rather than manually polling the target
            systemd-run --pty --quiet -p Wants=network-online.target -p After=network-online.target \
                curl "${script}" --location --retry-connrefused --retry 10 --fail -s -o /tmp/startup_script
            rt=$?
        else
            cp "${script}" /tmp/startup_script
            rt=$?
        fi
        if [[ ${rt} -eq 0 ]]; then
            chmod +x /tmp/startup_script
            printf '%s: executing automated script\n' "$0"
            # note that script is executed when other services (like pacman-init) may be still in progress, please
            # synchronize to "systemctl is-system-running --wait" when your script depends on other services
            /tmp/startup_script
        fi
    fi
}

wait_for_network() {
    local attempt
    echo "Waiting up to 30 seconds for internet access..."
    for ((attempt = 0; attempt < 10; attempt++)); do
        if curl --fail --silent --show-error --max-time 2 -o /dev/null https://archlinux.org/ 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    echo "Still offline. Connect Ethernet or use iwctl to connect to Wi-Fi."
    echo "In iwctl: device list; station <device> scan; station <device> get-networks;"
    echo "station <device> connect <network>. Then run gilgamesh-install."
    return 1
}

if [[ $(tty) == "/dev/tty1" ]]; then
    if [[ -n $(script_cmdline) ]]; then
        automated_script
    elif mkdir /run/gilgamesh-installer-started 2>/dev/null; then
        # /run lasts for one boot; cancelling must leave a usable rescue shell.
        logo=/opt/gilgamesh/src/installer/logo.txt
        if [[ -r $logo ]]; then cat "$logo"; else echo "Gilgamesh Linux"; fi
        echo
        if ! wait_for_network; then
            : # Leave the live shell available for connecting and retrying manually.
        elif systemctl start pacman-init.service; then
            export TERM=linux
            /usr/local/bin/gilgamesh-install
        else
            echo "Pacman keyring initialization failed; check journalctl -u pacman-init."
        fi
        echo "Run gilgamesh-install to try again. Other consoles are available with Alt+F2."
    fi
fi
