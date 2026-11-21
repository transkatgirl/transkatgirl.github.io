#!/usr/bin/env bash

# Download & run this script with the following command:
# wget -nv -O - https://transkatgirl.github.io/assets/scripts/passwordless.sh | bash

set -euo pipefail

PAM_UNIX_AUTH_RE='^[[:space:]]*-?auth[[:space:]].*pam_unix[.]so'
NULLOK_RE='[[:space:]]nullok([[:space:]]|$)'
SUDOERS_RULE=/etc/sudoers.d/zz-nopasswd

relabel() {
    [ -e /sys/fs/selinux/enforce ] || return 0
    if ! sudo sh -c 'command -v restorecon' >/dev/null 2>&1; then
        echo "Warning: SELinux is enabled but restorecon is not installed; not relabeling $*." >&2
        return 0
    fi
    sudo restorecon -F "$@" \
        || echo "Warning: restorecon failed for $*; check its SELinux label." >&2
}

preflight() {
    case $user in
        ""|-*|*[!A-Za-z0-9._-]*)
            echo "Unsupported username '$user' (only letters, digits, '.', '_' and '-' are handled)." >&2
            exit 1 ;;
    esac

    if ! awk -F: -v u="$user" '$1 == u { found = 1 } END { exit !found }' /etc/passwd; then
        echo "'$user' is not a local account in /etc/passwd (directory, SSSD or systemd-homed" >&2
        echo "accounts are not supported); nothing was changed." >&2
        exit 1
    fi

    if ! sudo -v; then
        echo "Could not get sudo access (wrong password, no terminal, or '$user' is not" >&2
        echo "allowed to use sudo); nothing was changed." >&2
        exit 1
    fi

    if ! sudo test -d /etc/sudoers.d; then
        echo "/etc/sudoers.d does not exist; nothing was changed." >&2
        exit 1
    fi
    if ! sudo visudo -c >/dev/null; then
        echo "The existing sudoers configuration has errors (see 'sudo visudo -c'); nothing was changed." >&2
        exit 1
    fi

    printf '#%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$uid" > "$sudoers_tmp"
    if ! sudo visudo -cf "$sudoers_tmp" >/dev/null; then
        echo "The generated sudoers rule failed validation; nothing was changed." >&2
        exit 1
    fi
}

detect_dm() {
    local id="" load="" dm=""

    if command -v systemctl >/dev/null 2>&1; then
        load=$(systemctl show --value -p LoadState display-manager.service 2>/dev/null || true)
        if [ "$load" = loaded ]; then
            id=$(systemctl show --value -p Id display-manager.service 2>/dev/null || true)
        fi
    fi
    if [ -z "$id" ]; then
        id=$(readlink -e /etc/systemd/system/display-manager.service 2>/dev/null || true)
        id=${id##*/}
    fi

    case $id in
        display-manager.service|display-manager-legacy.service)
            if [ -r /etc/sysconfig/displaymanager ]; then
                dm=$(sed -nE 's/^[[:space:]]*DISPLAYMANAGER[[:space:]]*=//p' /etc/sysconfig/displaymanager \
                    | tail -n 1 | tr -d "\"' \t")
            fi
            if [ -z "$dm" ]; then
                dm=$(readlink -e /etc/alternatives/default-displaymanager 2>/dev/null || true)
                dm=${dm##*/}
            fi
            if [ -n "$dm" ]; then dm=$dm.service; fi ;;
        *)
            dm=$id ;;
    esac

    printf '%s\n' "$dm"
}

polkit_js_capable() {
    local v
    command -v pkaction >/dev/null 2>&1 || return 1
    v=$(pkaction --version 2>/dev/null) || return 1
    v=${v##* }
    case $v in
        0.*)
            v=${v#0.}
            v=${v%%[!0-9]*}
            [ -n "$v" ] && [ "$v" -ge 106 ] ;;
        [1-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

gs_disable() {
    local schema=$1 key=$2 w
    w=$(gsettings writable "$schema" "$key" 2>/dev/null) || return 2
    if [ "$w" != true ]; then
        echo "Warning: $schema $key is locked by system policy; not changed." >&2
        return 1
    fi
    gsettings set "$schema" "$key" false 2>/dev/null || true
    if [ "$(gsettings get "$schema" "$key" 2>/dev/null)" != false ]; then
        echo "Warning: $schema $key did not persist (run this from a terminal inside your desktop session)." >&2
        return 1
    fi
}

pam_files() {
    local d f name
    local -A seen=()
    for d in /etc/pam.d /usr/etc/pam.d /usr/lib/pam.d; do
        sudo test -d "$d" || continue
        while IFS= read -r -d '' f; do
            name=${f##*/}
            [ -n "${seen[$name]+x}" ] && continue
            seen[$name]=1
            printf '%s\0' "$f"
        done < <(sudo find -L "$d" -maxdepth 1 -type f \
            ! -name '*.pre-nullok' ! -name '*.bak' ! -name '*.orig' ! -name '*~' \
            ! -name '*.dpkg-*' ! -name '*.ucf-*' ! -name '*.rpmnew' ! -name '*.rpmsave' \
            ! -name '*.pacnew' ! -name '*.pacsave' -print0)
    done
}

pam_check_nullok() {
    local files=()
    mapfile -d '' -t files < <(pam_files)
    [ "${#files[@]}" -gt 0 ] || return 1
    sudo awk -v unix="$PAM_UNIX_AUTH_RE" -v nullok="$NULLOK_RE" '
        $0 ~ unix {
            seen = 1
            if ($0 !~ nullok) {
                bad = 1
                if (!(FILENAME in shown)) { shown[FILENAME]; print FILENAME }
            }
        }
        END { exit !(seen && !bad) }' "${files[@]}"
}

pam_has_nullok() {
    pam_check_nullok >/dev/null
}

enable_nullok() {
    local cur profile feats f real target note
    local authselect_active=0
    local files=()

    if command -v authselect >/dev/null 2>&1 && cur=$(authselect current --raw 2>/dev/null); then
        if ! sudo authselect check >/dev/null 2>&1; then
            echo "Warning: authselect's PAM files were changed outside authselect; not changing PAM." >&2
            echo "         Run 'sudo authselect check' for details." >&2
            return 0
        fi
        authselect_active=1
        profile=${cur%% *}
        feats=$(authselect list-features "$profile" 2>/dev/null || true)
        if grep -qx without-nullok <<<"$feats"; then
            case " $cur " in
                *" without-nullok "*)
                    sudo authselect disable-feature without-nullok \
                        || echo "Warning: 'authselect disable-feature without-nullok' failed; authselect-managed PAM files not changed." >&2 ;;
            esac
        elif grep -qx with-nullok <<<"$feats"; then
            sudo authselect enable-feature with-nullok \
                || echo "Warning: 'authselect enable-feature with-nullok' failed; authselect-managed PAM files not changed." >&2
        else
            echo "Warning: authselect profile '$profile' has no nullok feature; authselect-managed PAM files not changed." >&2
        fi
    fi

    if command -v pam-config >/dev/null 2>&1 && [ -e /etc/pam.d/common-auth-pc ]; then
        if ! sudo pam-config -a --unix-nullok; then
            echo "Warning: 'pam-config -a --unix-nullok' failed; PAM not changed." >&2
            return 0
        fi
    fi

    mapfile -d '' -t files < <(pam_files)

    for f in "${files[@]}"; do
        sudo awk -v unix="$PAM_UNIX_AUTH_RE" -v nullok="$NULLOK_RE" \
            '$0 ~ unix && $0 !~ nullok { f = 1 } END { exit !f }' "$f" || continue

        real=$(sudo readlink -f "$f")

        if [ "$authselect_active" -eq 1 ]; then
            case $real in
                /etc/authselect/*) continue ;;
            esac
        fi

        case $real in
            /etc/*)
                target=$real
                sudo test -e "$target.pre-nullok" \
                    || sudo cp -p "$target" "$target.pre-nullok"
                note="backup: $target.pre-nullok" ;;
            *)
                target=/etc/pam.d/${f##*/}
                if sudo test -L "$target"; then
                    sudo test -e "$target.pre-nullok" || sudo test -L "$target.pre-nullok" \
                        || sudo cp -P "$target" "$target.pre-nullok"
                    note="original symlink saved as $target.pre-nullok"
                else
                    note="new override of $real; delete it to revert"
                fi
                sudo install -m 644 -o root -g root "$real" "$target" ;;
        esac

        sudo sed -E -i \
            -e "/$PAM_UNIX_AUTH_RE/s/([[:space:]])nullok_secure([[:space:]]|\$)/\1nullok\2/" \
            -e "/$PAM_UNIX_AUTH_RE/{/$NULLOK_RE/!s/(pam_unix[.]so)([[:space:]]|\$)/\1 nullok\2/}" \
            "$target"
        relabel "$target"
        echo "Added nullok to $target ($note)"

        if [ "$target" = /etc/pam.d/common-auth ] && command -v pam-auth-update >/dev/null 2>&1; then
            echo "Note: pam-auth-update will now treat common-auth as locally modified and stop" >&2
            echo "      updating it; 'pam-auth-update --force' would remove nullok again." >&2
        fi
    done
}

main() {
    local dm bin f rc gdm_conf="" gdm_src gdm_dir polkit_done=0 polkit_new_dir=0

    uid=$(id -u)
    if [ "$uid" -eq 0 ]; then
        echo "Run this as your normal user, not as root or via sudo." >&2
        exit 1
    fi
    user=$(id -un)

    tmp="" sudoers_tmp=""
    trap 'rm -f -- "$tmp" "$sudoers_tmp"' EXIT
    tmp=$(mktemp)
    sudoers_tmp=$(mktemp)

    preflight

    dm=$(detect_dm)
    case $dm in
        gdm.service|gdm3.service) ;;
        "")
            echo "Could not determine the display manager." >&2
            exit 1 ;;
        *)
            echo "Active display manager is $dm, not GDM; GDM autologin would not apply." >&2
            exit 1 ;;
    esac

    for bin in /usr/sbin/gdm /usr/sbin/gdm3 /usr/bin/gdm /usr/bin/gdm3; do
        [ -f "$bin" ] || continue
        gdm_conf=$(LC_ALL=C grep -aoE '[[:print:]]*/etc/gdm3?/(custom|daemon)\.conf' "$bin" \
            | grep -m1 -xE '/etc/gdm3?/(custom|daemon)\.conf' || true)
        [ -n "$gdm_conf" ] && break
    done
    if [ -z "$gdm_conf" ]; then
        for f in /etc/gdm/custom.conf /etc/gdm3/daemon.conf /etc/gdm3/custom.conf; do
            if [ -f "$f" ]; then gdm_conf=$f; break; fi
        done
    fi
    if [ -z "$gdm_conf" ]; then
        echo "No GDM config file found." >&2
        exit 1
    fi

    sudo install -m 0440 -o root -g root "$sudoers_tmp" "$SUDOERS_RULE"
    relabel "$SUDOERS_RULE"
    if ! sudo -n -k true 2>/dev/null; then
        sudo rm -f -- "$SUDOERS_RULE"
        echo "Error: $SUDOERS_RULE did not take effect, so it was removed; nothing was changed." >&2
        echo "       Check that your sudoers file includes /etc/sudoers.d and that nothing" >&2
        echo "       after the include overrides the rule." >&2
        exit 1
    fi

    gdm_src=$gdm_conf
    sudo test -f "$gdm_src" || gdm_src=/dev/null

    sudo cat "$gdm_src" | awk -v user="$user" '
        function add_keys() {
            print "AutomaticLoginEnable=true"
            print "AutomaticLogin=" user
            added = 1
        }
        /^[ \t]*\[/ {
            in_daemon = ($0 ~ /^[ \t]*\[daemon\][ \t]*$/)
            print
            if (in_daemon && !added) add_keys()
            next
        }
        in_daemon && /^[ \t]*AutomaticLogin(Enable)?[ \t]*=/ { next }
        { print }
        END {
            if (!added) { print ""; print "[daemon]"; add_keys() }
        }
    ' > "$tmp"
    if sudo test -f "$gdm_conf"; then
        sudo test -e "$gdm_conf.bak" || sudo cp -p "$gdm_conf" "$gdm_conf.bak"
    fi
    gdm_dir=${gdm_conf%/*}
    if ! sudo test -d "$gdm_dir"; then
        sudo install -d -m 755 -o root -g root "$gdm_dir"
        relabel "$gdm_dir"
    fi
    sudo install -m 644 -o root -g root "$tmp" "$gdm_conf"
    relabel "$gdm_conf"

    if sudo test -d /etc/polkit-1/rules.d || polkit_js_capable; then
        if ! sudo test -d /etc/polkit-1/rules.d; then
            sudo install -d -m 755 -o root -g root /etc/polkit-1/rules.d
            relabel /etc/polkit-1 /etc/polkit-1/rules.d
            polkit_new_dir=1
        fi
        cat > "$tmp" <<EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$user" && subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
EOF
        sudo install -m 644 -o root -g root "$tmp" /etc/polkit-1/rules.d/00-nopassword.rules
        relabel /etc/polkit-1/rules.d/00-nopassword.rules
        polkit_done=1
    fi

    if sudo test -d /etc/polkit-1/localauthority/50-local.d; then
        cat > "$tmp" <<EOF
[No password prompt]
Identity=unix-user:$user
Action=*
ResultActive=yes
EOF
        sudo install -m 644 -o root -g root "$tmp" /etc/polkit-1/localauthority/50-local.d/99-nopassword.pkla
        relabel /etc/polkit-1/localauthority/50-local.d/99-nopassword.pkla
        polkit_done=1
    fi

    if [ "$polkit_done" -eq 0 ]; then
        echo "Warning: polkit not found; polkit prompts were not changed." >&2
    elif [ "$polkit_new_dir" -eq 1 ]; then
        echo "Note: created /etc/polkit-1/rules.d; polkit may not load the new rule until it" >&2
        echo "      restarts (e.g. at the next reboot)." >&2
    fi

    if command -v gsettings >/dev/null 2>&1; then
        rc=0
        gs_disable org.gnome.desktop.screensaver lock-enabled || rc=$?
        if [ "$rc" -eq 2 ]; then
            echo "Warning: GNOME screensaver settings not found; lock screen was not changed." >&2
        fi
        gs_disable org.gnome.desktop.screensaver ubuntu-lock-on-suspend || true
    else
        echo "Warning: gsettings not found; lock screen was not changed." >&2
    fi

    if ! pam_has_nullok; then
        enable_nullok
    fi

    if pam_has_nullok; then
        sudo passwd -d "$user"
    else
        echo "Warning: could not enable empty passwords in PAM; keeping your current password" >&2
        echo "         so you can still log in and unlock. Files with pam_unix auth lines lacking nullok:" >&2
        pam_check_nullok | sed 's/^/           /' >&2 || true
    fi
}

main "$@"