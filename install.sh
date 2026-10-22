#!/usr/bin/env bash
# Links scripts from this repo into $HOME: ~/.<name>.sh -> scripts/<name>.sh,
# so `git pull` updates them in place. Does not edit ~/.bashrc, only prints
# the line to add.
#
# Usage: ./install.sh [--uninstall] [name...]   (no names: all scripts)

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
uninstall=0

if [ "${1:-}" = "--uninstall" ]; then uninstall=1; shift; fi
case "${1:-}" in
    -h|--help) sed -n '2,6s/^# \{0,1\}//p' "$0"; exit 0 ;;
esac

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
    for f in "$repo"/scripts/*.sh; do
        f="${f##*/}"
        names+=("${f%.sh}")
    done
fi

status=0
for name in "${names[@]}"; do
    name="${name%.sh}"
    src="$repo/scripts/$name.sh"
    dst="$HOME/.$name.sh"

    if [ ! -f "$src" ]; then
        echo "unknown script: $name (no $src)" >&2
        status=1
        continue
    fi

    if [ "$uninstall" = 1 ]; then
        if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
            rm -- "$dst"
            echo "removed: $dst"
        else
            echo "skipped: $dst is not a link to $src"
        fi
        continue
    fi

    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        echo "ok:      $dst -> $src"
    else
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            bak="$dst.bak.$(date +%Y%m%d-%H%M%S)"
            mv -- "$dst" "$bak"
            echo "moved:   $dst -> $bak"
        fi
        ln -s -- "$src" "$dst"
        echo "linked:  $dst -> $src"
    fi

    if ! grep -qF ".$name.sh" "$HOME/.bashrc" 2>/dev/null; then
        echo "         add to ~/.bashrc:  [ -f ~/.$name.sh ] && . ~/.$name.sh"
    fi
done

exit "$status"
