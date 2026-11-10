#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo "Run as root: sudo $0 newusers.txt KEY_BASE_URL" >&2
    exit 1
fi
if (( $# != 2 )); then
    echo "Usage: $0 newusers.txt https://example.org/keys/" >&2
    exit 1
fi
userfile=$1
base_url=${2%/}
[[ -f $userfile && -r $userfile ]] || { echo "Cannot read user file: $userfile" >&2; exit 1; }
[[ $base_url =~ ^https?:// ]] || { echo "Key base URL must start with http:// or https://" >&2; exit 1; }
for command in curl ssh-keygen useradd groupadd getent install; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
install -d -m 755 /home/visitors /scratch

created=0
failed=0
while IFS=: read -r name uid gecos shell extra || [[ -n ${name:-} ]]; do
    [[ -z ${name//[[:space:]]/} || $name == \#* ]] && continue
    shell=${shell%$'\r'}
    if [[ ! $name =~ ^[a-z_][a-z0-9_-]*$ || ! $uid =~ ^[0-9]+$ || -z $gecos || ! $shell == /* || -n ${extra:-} ]]; then
        echo "Invalid entry for '${name:-<empty>}' -- skipping" >&2
        ((failed+=1))
        continue
    fi
    if [[ ! -x $shell ]]; then
        echo "Missing shell $shell for $name -- install zsh/bash first" >&2
        ((failed+=1))
        continue
    fi
    home=/home/visitors/$name
    scratch=/scratch/$name
    echo "Processing $name (UID/GID $uid)"

    # An existing group is usable only if its GID is correct.
    existing_group=$(getent group "$name" || true)
    if [[ -n $existing_group ]]; then
        IFS=: read -r _ _ current_gid _ <<< "$existing_group"
        if [[ $current_gid != "$uid" ]]; then
            echo "Group $name has GID $current_gid, expected $uid -- skipping" >&2
            ((failed+=1)); continue
        fi
    elif getent group "$uid" >/dev/null; then
        echo "GID $uid already belongs to another group -- skipping $name" >&2
        ((failed+=1)); continue
    else
        if ! groupadd -g "$uid" "$name"; then
            echo "Cannot create group for $name" >&2
            ((failed+=1)); continue
        fi
    fi

    # Only repair accounts that already match the assignment identity and home.
    if getent passwd "$name" >/dev/null; then
        account=$(getent passwd "$name")
        IFS=: read -r _ _ old_uid old_gid _ old_home _ <<< "$account"
        if [[ $old_uid != "$uid" || $old_gid != "$uid" || $old_home != "$home" ]]; then
            echo "Existing account $name has conflicting identity/home -- skipping" >&2
            ((failed+=1)); continue
        fi
        echo "User exists; checking directories and public key"
    elif getent passwd "$uid" >/dev/null; then
        echo "UID $uid already used by another account -- skipping $name" >&2
        ((failed+=1)); continue
    else
        if ! useradd -u "$uid" -g "$name" -c "$gecos" -d "$home" -s "$shell" -m -k /etc/skel -p '*' "$name"; then
            echo "Cannot create user $name" >&2
            ((failed+=1)); continue
        fi
        ((created+=1))
    fi

    install -d -o "$name" -g "$name" -m 750 "$home"
    install -d -o "$name" -g "$name" -m 700 "$home/.ssh"
    install -d -o "$name" -g "$name" -m 700 "$scratch"

    tmp=$(mktemp)
    if curl -fsSL --connect-timeout 8 --max-time 25 "$base_url/$name.pub" -o "$tmp" 2>/dev/null; then
        if [[ -s $tmp ]] && ssh-keygen -lf "$tmp" >/dev/null 2>&1; then
            install -o "$name" -g "$name" -m 600 "$tmp" "$home/.ssh/authorized_keys"
            echo "  Public key installed"
        else
            echo "  Downloaded key file invalid or empty: $name.pub" >&2
        fi
    else
        echo "  No public key available for $name"
    fi
    rm -f "$tmp"
done < "$userfile"
echo "Finished: $created new users created; $failed entries skipped due to errors."
