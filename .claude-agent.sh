# ~/.claude-agent.sh - share projects with an isolated agent user
# Usage: add to ~/.bashrc
#   [ -f ~/.claude-agent.sh ] && . ~/.claude-agent.sh
#
# Shares are bindfs mounts and are not persisted: they are gone after a reboot.
# Run `claude-agent help` for the list of subcommands.

AGENT_USER="${AGENT_USER:-claude}"
AGENT_HOME="${AGENT_HOME:-/home/$AGENT_USER}"
AGENT_PROJECTS="${AGENT_PROJECTS:-$AGENT_HOME/projects}"
AGENT_CONFIG="${AGENT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-agent/projects}"

_CLAUDE_AGENT_SUBCOMMANDS="list add remove share unshare shell run help"

_claude_agent_help() {
  cat <<EOF
claude-agent list                  - known projects and their share status
claude-agent add <name> [path]     - register a project (path defaults to \$PWD)
claude-agent remove <name>         - forget a project (must be unshared)
claude-agent share <name> [path]   - share a project with the agent
claude-agent unshare <name>        - stop sharing a project
claude-agent shell                 - login shell as the agent user
claude-agent run [name] [--new] [args...]
                                   - run claude in a shared project, continuing
                                     its last session (--new: start a fresh one)
claude-agent <name> [--new] [args...] - same, short form

share without a path uses the registered path for <name>, or \$PWD if <name>
is not registered yet. share with a path registers/updates <name>.
Shares do not survive a reboot.

Config: $AGENT_CONFIG
  one "name:path" per line, blank lines and lines starting with # are ignored
EOF
}

# ---------- config ----------

# print "name<TAB>path" for every registered project
_claude_agent_cfg() {
  [ -f "$AGENT_CONFIG" ] || return 0
  local line name path
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ""|\#*) continue ;; esac
    name="${line%%:*}"
    path="${line#*:}"
    [ "$name" = "$line" ] && continue          # no colon, skip
    case "$path" in "~"|"~/"*) path="$HOME${path#\~}" ;; esac
    printf '%s\t%s\n' "$name" "$path"
  done < "$AGENT_CONFIG"
}

_claude_agent_cfg_names() {
  _claude_agent_cfg | cut -f1
}

_claude_agent_cfg_get() {
  _claude_agent_cfg | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }'
}

# rewrite config without entry <name>, optionally appending "name:path"
_claude_agent_cfg_write() {
  local name="$1" path="$2" tmp
  mkdir -p -- "$(dirname -- "$AGENT_CONFIG")" || return 1
  tmp="$(mktemp "$AGENT_CONFIG.XXXXXX")" || return 1
  if [ -f "$AGENT_CONFIG" ]; then
    awk -v n="$name" 'index($0, n ":") != 1' "$AGENT_CONFIG" > "$tmp"
  fi
  [ -n "$path" ] && printf '%s:%s\n' "$name" "$path" >> "$tmp"
  mv -f -- "$tmp" "$AGENT_CONFIG"
}

_claude_agent_valid_name() {
  case "$1" in
    ""|.|..|-*|*/*|*:*|*[[:space:]]*)
      echo "bad name: '$1'" >&2; return 1 ;;
  esac
  case " $_CLAUDE_AGENT_SUBCOMMANDS " in *" $1 "*)
    echo "name '$1' clashes with a subcommand, pick another" >&2; return 1 ;;
  esac
}

# ---------- mounts ----------

# print "name<TAB>source" for every shared (mounted) project
_claude_agent_mounts() {
  findmnt -rn -o SOURCE,TARGET | while read -r src tgt; do
    case "$tgt" in
      "$AGENT_PROJECTS"/*) printf '%s\t%s\n' "${tgt##*/}" "$src" ;;
    esac
  done
}

_claude_agent_shared_names() {
  _claude_agent_mounts | cut -f1
}

_claude_agent_is_shared() {
  _claude_agent_shared_names | grep -qxF -- "$1"
}

# ---------- subcommands ----------

_claude_agent_list() {
  local cfg mounts
  cfg="$(_claude_agent_cfg)"
  mounts="$(_claude_agent_mounts)"
  {
    printf '%s\n' "$cfg" | while IFS=$'\t' read -r name path; do
      [ -n "$name" ] || continue
      if printf '%s\n' "$mounts" | cut -f1 | grep -qxF -- "$name"; then
        printf '%-20s %-9s %s\n' "$name" "shared" "$path"
      else
        printf '%-20s %-9s %s\n' "$name" "-" "$path"
      fi
    done
    # shared but not registered
    printf '%s\n' "$mounts" | while IFS=$'\t' read -r name src; do
      [ -n "$name" ] || continue
      printf '%s\n' "$cfg" | cut -f1 | grep -qxF -- "$name" && continue
      printf '%-20s %-9s %s\n' "$name" "shared*" "$src"
    done
  } | sort
}

_claude_agent_add() {
  [ -z "$1" ] && { echo "usage: claude-agent add <name> [path]" >&2; return 1; }
  _claude_agent_valid_name "$1" || return 1
  local src
  src="$(realpath -e -- "${2:-$PWD}")" || return 1
  [ -d "$src" ] || { echo "not a directory: $src" >&2; return 1; }
  _claude_agent_cfg_write "$1" "$src" || return 1
  echo "registered: $1 -> $src"
}

_claude_agent_remove() {
  [ -z "$1" ] && { echo "usage: claude-agent remove <name>" >&2; return 1; }
  if _claude_agent_is_shared "$1"; then
    echo "'$1' is shared, run: claude-agent unshare $1" >&2; return 1
  fi
  [ -n "$(_claude_agent_cfg_get "$1")" ] || { echo "unknown project: $1" >&2; return 1; }
  _claude_agent_cfg_write "$1" || return 1
  echo "removed: $1"
}

_claude_agent_share() {
  [ -z "$1" ] && { echo "usage: claude-agent share <name> [path]" >&2; return 1; }

  local name="$1" src tgt
  _claude_agent_valid_name "$name" || return 1

  if [ -n "$2" ]; then
    src="$2"
  else
    src="$(_claude_agent_cfg_get "$name")"
    [ -n "$src" ] || src="$PWD"
  fi
  src="$(realpath -e -- "$src")" || return 1
  [ -d "$src" ] || { echo "not a directory: $src" >&2; return 1; }

  case "$src/" in "$AGENT_HOME"/*)
    echo "refusing to share a path inside $AGENT_HOME: $src" >&2; return 1 ;;
  esac

  if _claude_agent_is_shared "$name"; then
    echo "already shared: $name" >&2; return 1
  fi

  # register or update
  if [ "$(_claude_agent_cfg_get "$name")" != "$src" ]; then
    _claude_agent_cfg_write "$name" "$src" || return 1
  fi

  tgt="$AGENT_PROJECTS/$name"
  local map="$(id -un)/$AGENT_USER:@$(id -gn)/@$AGENT_USER"

  sudo -u "$AGENT_USER" mkdir -p -- "$tgt" || return 1
  # no "--" here: bindfs appends its own fuse options after the paths
  sudo bindfs --map="$map" "$src" "$tgt" || return 1
  echo "shared: $src -> $tgt"
}

_claude_agent_unshare() {
  [ -z "$1" ] && { echo "usage: claude-agent unshare <name>" >&2; return 1; }
  local tgt="$AGENT_PROJECTS/$1"
  sudo umount -- "$tgt" || return 1
  sudo -u "$AGENT_USER" rmdir -- "$tgt" 2>/dev/null
  echo "unshared: $1"
}

_claude_agent_run() {
  local dir="$AGENT_PROJECTS"
  if [ -n "$1" ] && [ "${1#-}" = "$1" ]; then
    if ! _claude_agent_is_shared "$1"; then
      echo "not shared: $1 (run: claude-agent share $1)" >&2; return 1
    fi
    dir="$AGENT_PROJECTS/$1"; shift
  fi
  local new=
  if [ "$1" = "--new" ]; then new=1; shift; fi

  local cmd="cd $(printf %q "$dir") || exit 1"
  if [ -z "$new" ] && _claude_agent_should_continue "$@"; then
    # claude keeps sessions in <config>/projects/<cwd with non-alnum -> '-'>;
    # add -c only if one exists, otherwise claude -c fails
    local enc
    enc="$(printf %s "$dir" | sed 's/[^A-Za-z0-9]/-/g')"
    cmd+="; compgen -G \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/projects/$enc/*.jsonl\" >/dev/null && set -- -c \"\$@\""
  fi
  cmd+="; exec ~/.local/bin/claude \"\$@\""
  sudo -u "$AGENT_USER" -H bash -lc "$cmd" bash "$@"
}

# continue by default, unless the args already pick a session or are not
# an interactive/prompt run (subcommands, --help, --version)
_claude_agent_should_continue() {
  case "$1" in
    mcp|config|doctor|update|install|plugin|setup-token|migrate-installer|agents)
      return 1 ;;
  esac
  local a
  for a in "$@"; do
    case "$a" in
      -c|--continue|-r|--resume|--resume=*|--session-id|--session-id=*|--from-pr*|\
      -h|--help|-v|--version)
        return 1 ;;
    esac
  done
  return 0
}

claude-agent() {
  case "$1" in
    list)              _claude_agent_list ;;
    add)       shift;  _claude_agent_add "$@" ;;
    remove)    shift;  _claude_agent_remove "$@" ;;
    share)     shift;  _claude_agent_share "$@" ;;
    unshare)   shift;  _claude_agent_unshare "$@" ;;
    shell)             sudo -iu "$AGENT_USER" ;;
    run)       shift;  _claude_agent_run "$@" ;;
    ""|help|-h|--help) _claude_agent_help ;;
    *)                 _claude_agent_run "$@" ;;
  esac
}

# ---------- completion ----------

_claude_agent_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local pos=$((COMP_CWORD - 1))   # index among args after the subcommand
  COMPREPLY=()

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$_CLAUDE_AGENT_SUBCOMMANDS $(_claude_agent_shared_names)" -- "$cur"))
    return
  fi

  case "${COMP_WORDS[1]}" in
    share)
      if [ "$pos" -eq 1 ]; then
        # registered projects that are not shared yet
        local avail
        avail="$(_claude_agent_cfg_names | grep -vxF -f <(_claude_agent_shared_names))"
        COMPREPLY=($(compgen -W "$avail" -- "$cur"))
      elif [ "$pos" -eq 2 ]; then
        compopt -o filenames
        COMPREPLY=($(compgen -d -- "$cur"))
      fi
      ;;
    add)
      if [ "$pos" -eq 2 ]; then
        compopt -o filenames
        COMPREPLY=($(compgen -d -- "$cur"))
      fi
      ;;
    remove)
      [ "$pos" -eq 1 ] && COMPREPLY=($(compgen -W "$(_claude_agent_cfg_names)" -- "$cur"))
      ;;
    unshare)
      [ "$pos" -eq 1 ] && COMPREPLY=($(compgen -W "$(_claude_agent_shared_names)" -- "$cur"))
      ;;
    run)
      [ "$pos" -eq 1 ] && COMPREPLY=($(compgen -W "$(_claude_agent_shared_names)" -- "$cur"))
      [ "$pos" -eq 2 ] && COMPREPLY=($(compgen -W "--new" -- "$cur"))
      ;;
    *)
      # short form: claude-agent <name> --new
      [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "--new" -- "$cur"))
      ;;
  esac
}
complete -F _claude_agent_complete claude-agent
