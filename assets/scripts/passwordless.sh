#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not as root or via sudo." >&2
    exit 1
fi
user=$(id -un)

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

relabel() {
    if [ -e /sys/fs/selinux/enforce ]; then
        sudo restorecon -F "$@"
    fi
}

dm_path=$(readlink -e /etc/systemd/system/display-manager.service || true)
case "${dm_path##*/}" in
    gdm.service|gdm3.service) ;;
    "")
        echo "Could not determine the display manager (no display-manager.service)." >&2
        exit 1 ;;
    *)
        echo "Active display manager is ${dm_path##*/}, not GDM; GDM autologin would not apply." >&2
        exit 1 ;;
esac

gdm_conf=""
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

printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$user" > "$tmp"
sudo visudo -cf "$tmp"
sudo install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/zz-nopasswd
relabel /etc/sudoers.d/zz-nopasswd

sudo -k
if ! sudo -n true 2>/dev/null; then
    echo "Error: /etc/sudoers.d/zz-nopasswd is installed but not in effect." >&2
    echo "       Check that /etc/sudoers includes /etc/sudoers.d and that nothing after" >&2
    echo "       the include overrides the rule. Your password has not been changed." >&2
    exit 1
fi

polkit_done=0

if sudo test -d /etc/polkit-1/rules.d; then
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
    echo "Warning: no polkit rules directory found; polkit prompts were not changed." >&2
fi

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
PAM_UNIX_AUTH_RE='^[[:space:]]*-?auth[[:space:]].*pam_unix[.]so'
NULLOK_RE='[[:space:]]nullok([[:space:]]|$)'

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

    while IFS= read -r -d '' f <&3; do
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
    done 3< <(pam_files)
}

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