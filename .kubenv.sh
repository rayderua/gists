#!/bin/bash
KUBENV_SUFFIX="${HOME}/.kube/kubenv/"
KUBENV_KUBECONFIG_DEFAULT="${HOME}/.kube/config"
KUBENV_CONFIG_D="${HOME}/.kube/config.d"
KUBENV_BACKUP_D="${KUBENV_SUFFIX}backups"

# Temp files of other sessions that can't be checked by PID (legacy names,
# or another host sharing $HOME) are removed once older than this (minutes).
KUBENV_CLEANUP_AGE_MIN="${KUBENV_CLEANUP_AGE_MIN:-1440}"

# How many backups of ~/.kube/config to keep.
KUBENV_BACKUPS="${KUBENV_BACKUPS:-10}"

function _kubenv_usage()
{
    echo "kubenv allows to set kubectl context/namespace for current shell session."
    echo "You can also persist changes using 'save' command."
    echo "Remember to 'save' changes if you add new context (i.e. connect to new cluster)."
    echo
    echo "Usage:"
    echo "      kubenv use [on|off] | save [force] | merge [force] | split [force]"
    echo "      kubenv reload | restore [list|<backup>] | clean"
    echo "      kubenv [(contexts|ctx)|(namespaces|ns)] [(cur|current)|all|-|<value-to-set>]"
    echo
    echo "Sub-commands:"
    echo
    echo "use"
    echo "      - on - enables kubenv"
    echo "      - off - disables kubenv"
    echo "      - (no argument) - toggles kubenv"
    echo
    echo "contexts | ctx"
    echo "      - With no argument | all - lists all contexts"
    echo "      - cur | current - lists current context"
    echo "      - - (hyphen) - switch to previous context"
    echo "      - any other argument sets context to that value"
    echo
    echo "namespaces | ns"
    echo "      - With no argument | all - lists all namespaces"
    echo "      - cur | current - lists current namespaces"
    echo "      - - (hyphen) - switch to previous namespace"
    echo "      - any other argument sets namespace to that value"
    echo
    echo "save"
    echo "      - persists the CURRENT context (with its namespace/cluster/user) into"
    echo "        every file in ${KUBENV_CONFIG_D}/ that already defines it, or into"
    echo "        a new <context-name>.yaml, then runs 'merge'"
    echo "      - 'force' is passed on to 'merge'"
    echo "      - resets current context to 'null' afterwards, you need to switch manually"
    echo
    echo "merge"
    echo "      - rebuilds ${KUBENV_KUBECONFIG_DEFAULT} from all files in"
    echo "        ${KUBENV_CONFIG_D}/*.yaml (does not touch per-cluster files)"
    echo "      - refuses if that would drop contexts that are in ${KUBENV_KUBECONFIG_DEFAULT}"
    echo "        but not in ${KUBENV_CONFIG_D}; 'kubenv merge force' drops them anyway"
    echo "      - resets current context to 'null' afterwards, you need to switch manually"
    echo
    echo "split"
    echo "      - reverse of 'merge': reads ${KUBENV_KUBECONFIG_DEFAULT} and writes"
    echo "        one file per context into ${KUBENV_CONFIG_D}/<context-name>.yaml"
    echo "        ('/' in context names becomes '_')"
    echo "      - use this once to bootstrap ${KUBENV_CONFIG_D} from an existing config"
    echo "      - by default, existing files in ${KUBENV_CONFIG_D} are NOT overwritten"
    echo "        unless you pass 'force': kubenv split force"
    echo "      - resets current context to 'null' afterwards, you need to switch manually"
    echo
    echo "reload"
    echo "      - reloads kubectl config from ${KUBENV_KUBECONFIG_DEFAULT}"
    echo "      - resets current context to 'null' afterwards, you need to switch manually"
    echo
    echo "restore"
    echo "      - (no argument) - restores ${KUBENV_KUBECONFIG_DEFAULT} from the latest backup"
    echo "      - list - lists backups in ${KUBENV_BACKUP_D} (newest last)"
    echo "      - <backup> - restores that backup"
    echo "      - a backup is taken before every merge/save/restore, the last"
    echo "        ${KUBENV_BACKUPS} are kept; the current config is backed up first,"
    echo "        so a restore can be undone with another restore"
    echo "      - resets current context to 'null' afterwards, you need to switch manually"
    echo
    echo "clean"
    echo "      - removes per-session temp kubeconfig files from ${KUBENV_SUFFIX}"
    echo "        whose shell is no longer running; runs automatically every time"
    echo "        kubenv is sourced"
    echo "      - files that can't be checked this way (old names, other hosts) are"
    echo "        removed after ${KUBENV_CLEANUP_AGE_MIN} min"
    echo "      - does NOT touch the current session's temp file"
    echo
}

function _kubenv_use()
{
    case "${1}" in
        "on")
            KUBENV_ENABELED=0
            ;;
        "off")
            KUBENV_ENABELED=1
            ;;
        *)
            if [[ ${KUBENV_ENABELED} == 0 ]]
            then
                KUBENV_ENABELED=1
            else
                KUBENV_ENABELED=0
            fi
            ;;
    esac

    if [[ ${KUBENV_ENABELED} == 0 ]]
    then
        echo "Enabled kubenv"
    else
        echo "Disabled kubenv"
    fi
}

function _kubenv_ctx()
{
    current_context=$(${KUBENV_KUBECTL} config current-context)
    case "${1}" in
        ""|all)
            for c in $(${KUBENV_KUBECTL} config get-contexts --output=name)
            do
                if [[ "${c}" == "${current_context}" ]]
                then
                    echo "* ${c}"
                else
                    echo "  ${c}"
                fi
            done
            ;;
        cur|current)
            echo "${current_context}"
            ;;
        "-")
            if [[ ${KUBENV_ENABELED} == 1 ]]
            then
                echo "kubenv is disabled"
            elif [[ "${KUBENV_PREV_CTX}" == "" ]]
            then
                echo "No previous context"
            else
                ${KUBENV_KUBECTL} config use-context "${KUBENV_PREV_CTX}"
                KUBENV_PREV_CTX=${current_context}
            fi
            ;;
        *)
            if [[ ${KUBENV_ENABELED} == 0 ]]
            then
                KUBENV_PREV_CTX=${current_context}
                ${KUBENV_KUBECTL} config use-context "${1}"
            else
                echo "kubenv is disabled"
            fi
            ;;
    esac
}

function _kubenv_ns()
{
    current_context=$(${KUBENV_KUBECTL} config current-context)
    if [[ ${current_context} = "null" ]]
    then
        echo "No context selected, run: kubenv ctx <name>" >&2
        return 1
    fi

    current_namespace=$(${KUBENV_KUBECTL} config view --output="jsonpath={.contexts[?(@.name==\"${current_context}\")].context.namespace}")
    case "${1}" in
        ""|all)
            for c in $(${KUBENV_KUBECTL} get namespace --request-timeout=10s --output="jsonpath={range.items[*]}{.metadata.name}:{end}"|tr ':' '\n')
            do
                if [[ "${c}" == "${current_namespace}" ]]
                then
                    echo "* ${c}"
                else
                    echo "  ${c}"
                fi
            done
            ;;
        cur|current)
            echo "${current_namespace}"
            ;;
        "-")
            if [[ ${KUBENV_ENABELED} == 1 ]]
            then
                echo "kubenv is disabled"
            elif [[ "${KUBENV_PREV_NS}" == "" ]]
            then
                echo "No previous namespace"
            else
                ${KUBENV_KUBECTL} config set-context "${current_context}" --namespace "${KUBENV_PREV_NS}"
                KUBENV_PREV_NS=${current_namespace}
            fi
            ;;
        *)
            if [[ ${KUBENV_ENABELED} == 0 ]]
            then
                KUBENV_PREV_NS=${current_namespace}
                ${KUBENV_KUBECTL} config set-context "${current_context}" --namespace "${1}"
            else
                echo "kubenv is disabled"
            fi
            ;;
    esac
}

# Resets the session's current context back to the internal "null" one.
# Called after any command that isn't about switching cluster/namespace
# (merge/save/split/reload/restore), forcing the user to explicitly
# pick a context again.
function _kubenv_reset_context()
{
    # force to create null context
    kubectl config set-cluster null --server=''  --certificate-authority='' --kubeconfig="${KUBENV_CONFIG}" >/dev/null 2>&1
    kubectl config set-credentials null --username='' --password='' --kubeconfig="${KUBENV_CONFIG}" >/dev/null 2>&1
    kubectl config set-context null --cluster=null --user=null --kubeconfig="${KUBENV_CONFIG}" >/dev/null 2>&1
    kubectl config use-context null --kubeconfig="${KUBENV_CONFIG}" >/dev/null 2>&1

    KUBENV_PREV_CTX=""
    KUBENV_PREV_NS=""
    echo "Context reset to 'null', please switch context manually (kubenv ctx <name>)"
}

# File name (without .yaml) for a context in config.d. Context names like
# EKS ARNs contain '/', which can't be part of a file name, and ':', which
# separates paths in KUBECONFIG; both become '_'.
function _kubenv_file_name()
{
    local n="${1//\//_}"
    echo "${n//:/_}"
}

# Writes stdin to a file readable only by the owner (kubeconfigs hold
# credentials). Existing files keep their permissions.
function _kubenv_write()
{
    (umask 077; cat > "${1}")
}

# Removes temporary kubeconfig files of sessions that are gone from
# ${KUBENV_SUFFIX}. Each session's file is named
# kubenv.<host>.<shell-pid>.XXXXXXXXXX, so a file of this host is removed
# as soon as its shell is no longer running. Files that can't be checked
# this way (old kubenv.XXXXXXXXXX names, or another host sharing $HOME)
# are removed once older than ${KUBENV_CLEANUP_AGE_MIN} minutes.
# The current session's own file (${KUBENV_CONFIG}, if already set) is
# always skipped.
#
# "kubenv clean" calls this function explicitly and prints a report of
# what was removed/skipped. On a normal source of the script it is also
# called automatically, but silently, so it doesn't clutter the output.
function _kubenv_cleanup_old()
{
    local verbose="${1:-0}"
    local removed=0 skipped_alive=0 skipped_young=0
    local f rest fhost pid host="${HOSTNAME%%.*}"

    [[ -d "${KUBENV_SUFFIX}" ]] || return 0

    for f in "${KUBENV_SUFFIX}"kubenv.*
    do
        [[ -f "${f}" ]] || continue
        [[ -n "${KUBENV_CONFIG}" && "${f}" == "${KUBENV_CONFIG}" ]] && continue

        rest="${f##*/kubenv.}"          # <host>.<pid>.<random> or <random>
        fhost="${rest%%.*}"
        rest="${rest#*.}"
        pid="${rest%%.*}"

        if [[ "${fhost}" == "${host}" && "${pid}" =~ ^[0-9]+$ ]]
        then
            if ps -p "${pid}" >/dev/null 2>&1
            then
                skipped_alive=$((skipped_alive + 1))
                continue
            fi
        elif [[ -n "$(find "${f}" -mmin "-${KUBENV_CLEANUP_AGE_MIN}" 2>/dev/null)" ]]
        then
            skipped_young=$((skipped_young + 1))
            continue
        fi

        rm -f -- "${f}"
        removed=$((removed + 1))
    done

    if [[ "${verbose}" == "1" ]]
    then
        echo "kubenv clean: removed ${removed} stale file(s), skipped ${skipped_alive} of running shells, ${skipped_young} too recent to tell"
    fi
}

# Collects all *.yaml/*.yml files in config.d and merges them into a
# single valid kubeconfig (via 'kubectl config view --flatten').
# The result is printed to stdout - the caller decides where to write it.
function _kubenv_build_merged()
{
    local files=()
    local f

    if [[ -d "${KUBENV_CONFIG_D}" ]]
    then
        for f in "${KUBENV_CONFIG_D}"/*.yaml "${KUBENV_CONFIG_D}"/*.yml
        do
            [[ -f "${f}" ]] || continue
            if [[ "${f}" == *:* ]]
            then
                echo "Skipping ${f}: ':' in the name breaks KUBECONFIG, rename the file" >&2
                continue
            fi
            files+=("${f}")
        done
    fi

    if [[ ${#files[@]} -eq 0 ]]
    then
        echo "No cluster configs found in ${KUBENV_CONFIG_D}" >&2
        return 1
    fi

    local joined
    joined=$(IFS=:; echo "${files[*]}")

    KUBECONFIG="${joined}" kubectl config view --flatten --raw
}

# Prints backup files, oldest first (names sort by date).
function _kubenv_backups()
{
    local f
    for f in "${KUBENV_BACKUP_D}"/config.*
    do
        [[ -f "${f}" ]] && echo "${f}"
    done
}

# Copies ~/.kube/config to ${KUBENV_BACKUP_D}/config.<date>, unless it is
# empty or the same as the latest backup, and keeps the last
# ${KUBENV_BACKUPS} backups.
function _kubenv_backup()
{
    [[ -s "${KUBENV_KUBECONFIG_DEFAULT}" ]] || return 0
    mkdir -p "${KUBENV_BACKUP_D}" || return 1

    local files=() f
    while IFS= read -r f; do files+=("${f}"); done < <(_kubenv_backups)

    if [[ ${#files[@]} -gt 0 ]] && cmp -s "${files[${#files[@]}-1]}" "${KUBENV_KUBECONFIG_DEFAULT}"
    then
        return 0
    fi

    f="${KUBENV_BACKUP_D}/config.$(date +%Y%m%d-%H%M%S)"
    local base="${f}" i=1
    while [[ -e "${f}" ]]; do f="${base}-$((i++))"; done
    _kubenv_write "${f}" < "${KUBENV_KUBECONFIG_DEFAULT}" || return 1
    files+=("${f}")

    local i n=$(( ${#files[@]} - KUBENV_BACKUPS ))
    for (( i = 0; i < n; i++ ))
    do
        rm -f -- "${files[i]}"
    done
}

function _kubenv_restore()
{
    local src f files=()
    while IFS= read -r f; do files+=("${f}"); done < <(_kubenv_backups)

    case "${1}" in
        list)
            if [[ ${#files[@]} -eq 0 ]]
            then
                echo "No backups in ${KUBENV_BACKUP_D}"
            else
                for f in "${files[@]}"; do echo "${f##*/}"; done
            fi
            return 0
            ;;
        "")
            if [[ ${#files[@]} -gt 0 ]]
            then
                src="${files[${#files[@]}-1]}"
            else
                src="${KUBENV_SUFFIX}config.bkp"   # backup from older kubenv versions
            fi
            ;;
        *)
            src="${KUBENV_BACKUP_D}/${1##*/}"
            ;;
    esac

    if [[ ! -f "${src}" ]]
    then
        echo "No backup to restore${1:+: ${1}} (see: kubenv restore list)" >&2
        return 1
    fi

    # Take the backup aside first: backing up the current config below may
    # rotate the oldest backup away.
    local tmp
    tmp=$(mktemp "${KUBENV_SUFFIX}restore.XXXXXXXXXX") || return 1
    cp -- "${src}" "${tmp}" || { rm -f -- "${tmp}"; return 1; }

    _kubenv_backup
    _kubenv_write "${KUBENV_KUBECONFIG_DEFAULT}" < "${tmp}"
    rm -f -- "${tmp}"
    cp "${KUBENV_KUBECONFIG_DEFAULT}" "${KUBENV_CONFIG}"

    echo "Restored ${KUBENV_KUBECONFIG_DEFAULT} from ${src}"
    _kubenv_reset_context
}

# Rebuilds ~/.kube/config from ~/.kube/config.d/*.yaml
function _kubenv_merge()
{
    local force="${1}" tmp missing

    tmp=$(mktemp "${KUBENV_SUFFIX}merge.XXXXXXXXXX") || return 1
    if ! _kubenv_build_merged > "${tmp}"
    then
        rm -f -- "${tmp}"
        return 1
    fi

    # Contexts that are only in ~/.kube/config (not split yet, or added
    # there by another tool) would be lost.
    missing=$(comm -23 \
        <(kubectl --kubeconfig="${KUBENV_KUBECONFIG_DEFAULT}" config get-contexts --output=name 2>/dev/null | grep -vxF null | sort) \
        <(kubectl --kubeconfig="${tmp}" config get-contexts --output=name 2>/dev/null | sort))

    if [[ -n "${missing}" && "${force}" != "force" ]]
    then
        echo "Not rebuilding ${KUBENV_KUBECONFIG_DEFAULT}: these contexts are in it but not in ${KUBENV_CONFIG_D}:" >&2
        echo "${missing}" | sed 's/^/  /' >&2
        echo "Add them with 'kubenv split' (keeps existing files), or drop them with 'kubenv merge force'" >&2
        rm -f -- "${tmp}"
        return 1
    fi

    _kubenv_backup
    _kubenv_write "${KUBENV_KUBECONFIG_DEFAULT}" < "${tmp}"
    rm -f -- "${tmp}"
    echo "Rebuilt ${KUBENV_KUBECONFIG_DEFAULT} from $(ls "${KUBENV_CONFIG_D}"/*.yaml "${KUBENV_CONFIG_D}"/*.yml 2>/dev/null | wc -l | tr -d ' ') file(s) in ${KUBENV_CONFIG_D}"

    # pick up the result in the current session too
    cp "${KUBENV_KUBECONFIG_DEFAULT}" "${KUBENV_CONFIG}"

    _kubenv_reset_context
}

# Saves the current context (cluster/user/context/namespace) into every
# file in config.d that already defines it (other entries in those files
# are kept), or into a new config.d/<context-name>.yaml, then rebuilds the
# combined ~/.kube/config from all files in config.d.
function _kubenv_save()
{
    local force="${1}"
    mkdir -p "${KUBENV_CONFIG_D}"

    local current_context
    current_context=$(${KUBENV_KUBECTL} config current-context 2>/dev/null)

    if [[ -z "${current_context}" || "${current_context}" == "null" ]]
    then
        echo "No active context to save (current context is empty or 'null')"
        return 1
    fi

    local files=() f
    for f in "${KUBENV_CONFIG_D}"/*.yaml "${KUBENV_CONFIG_D}"/*.yml
    do
        # files with ':' can't be merged (see _kubenv_build_merged)
        [[ -f "${f}" && "${f}" != *:* ]] || continue
        if kubectl --kubeconfig="${f}" config get-contexts --output=name 2>/dev/null | grep -qxF -- "${current_context}"
        then
            files+=("${f}")
        fi
    done

    if [[ ${#files[@]} -eq 0 ]]
    then
        files=("${KUBENV_CONFIG_D}/$(_kubenv_file_name "${current_context}").yaml")
    elif [[ ${#files[@]} -gt 1 ]]
    then
        echo "Context '${current_context}' is defined in several files, updating all of them:"
        printf '  %s\n' "${files[@]}"
    fi

    # The minified (--minify) config contains only the current
    # context/cluster/user.
    local cur tmp failed=0
    cur=$(mktemp "${KUBENV_SUFFIX}save.XXXXXXXXXX") || return 1
    if ! ${KUBENV_KUBECTL} config view --raw --minify --flatten > "${cur}"
    then
        rm -f -- "${cur}"
        return 1
    fi

    for f in "${files[@]}"
    do
        tmp=$(mktemp "${KUBENV_SUFFIX}save.XXXXXXXXXX") || { failed=1; break; }
        # The first file wins on name clashes, so the current values
        # replace the old ones while other entries of ${f} stay. ${f} may not exist yet,
        # kubectl skips missing files.
        if KUBECONFIG="${cur}:${f}" kubectl config view --raw --flatten > "${tmp}" \
            && _kubenv_write "${f}" < "${tmp}"
        then
            echo "Saved context '${current_context}' to ${f}"
        else
            echo "Failed to save context '${current_context}' to ${f}" >&2
            failed=1
        fi
        rm -f -- "${tmp}"
    done
    rm -f -- "${cur}"

    [[ ${failed} == 0 ]] || return 1

    # _kubenv_merge already resets the context at the end
    _kubenv_merge "${force}"
}

# Reverse of merge/save: reads ~/.kube/config and splits every context out
# into its own file config.d/<context-name>.yaml.
# By default, existing files are left untouched (so manual edits aren't
# overwritten) - pass "force" as the first argument to overwrite all.
function _kubenv_split()
{
    local force="${1}"
    mkdir -p "${KUBENV_CONFIG_D}"

    local contexts
    contexts=$(kubectl --kubeconfig="${KUBENV_KUBECONFIG_DEFAULT}" config get-contexts --output=name 2>/dev/null)

    if [[ -z "${contexts}" ]]
    then
        echo "No contexts found in ${KUBENV_KUBECONFIG_DEFAULT}"
        return 1
    fi

    local ctx file written=0 skipped=0 failed=0
    while IFS= read -r ctx
    do
        # "null" is kubenv's own internal context, skip it
        [[ -z "${ctx}" || "${ctx}" == "null" ]] && continue

        file="${KUBENV_CONFIG_D}/$(_kubenv_file_name "${ctx}").yaml"

        if [[ -f "${file}" && "${force}" != "force" ]]
        then
            echo "Skipping ${ctx} (${file} already exists, use 'kubenv split force' to overwrite)"
            skipped=$((skipped + 1))
            continue
        fi

        if kubectl --kubeconfig="${KUBENV_KUBECONFIG_DEFAULT}" config view --raw --minify --flatten --context="${ctx}" | _kubenv_write "${file}" \
            && [[ ${PIPESTATUS[0]} == 0 ]]
        then
            echo "Wrote ${file}"
            written=$((written + 1))
        else
            echo "Failed to write ${file}" >&2
            rm -f -- "${file}"
            failed=$((failed + 1))
        fi
    done <<< "${contexts}"

    echo "Split done: ${written} file(s) written, ${skipped} skipped, ${failed} failed."

    _kubenv_reset_context
}

function kubenv()
{
    if [[ ${#} -gt 0 ]]
    then
        case "${1}" in
            use)
                _kubenv_use "${2}"
                ;;
            contexts|ctx)
                _kubenv_ctx "${2}"
                ;;
            namespaces|ns)
                _kubenv_ns "${2}"
                ;;
            restore)
                _kubenv_restore "${2}"
                ;;
            save)
                _kubenv_save "${2}"
                ;;
            merge)
                _kubenv_merge "${2}"
                ;;
            split)
                _kubenv_split "${2}"
                ;;
            clean)
                _kubenv_cleanup_old 1
                ;;
            reload)
                cp "${KUBENV_KUBECONFIG_DEFAULT}" "${KUBENV_CONFIG}"
                _kubenv_reset_context
                ;;
            *)
                _kubenv_usage
                ;;
        esac
    else
        _kubenv_usage
    fi
}

_kubenv_complete()
{
    local cur prev

    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    case ${COMP_CWORD} in
        1)
            COMPREPLY=($(compgen -W "use contexts ctx namespaces ns save merge split clean restore reload help" -- ${cur}))
            ;;
        2)
            case ${prev} in
                contexts|ctx)
                    COMPREPLY=($(compgen -W "$(${KUBENV_KUBECTL} config get-contexts --output=name)" -- ${cur}))
                    ;;
                namespaces|ns)
                    COMPREPLY=($(compgen -W "$(${KUBENV_KUBECTL} get namespace --request-timeout=3s --output="jsonpath={range.items[*]}{.metadata.name}:{end}" 2>/dev/null|tr ':' '\n')" -- ${cur}))
                    ;;
                use)
                    COMPREPLY=($(compgen -W "on off" -- ${cur}))
                    ;;
                save|merge|split)
                    COMPREPLY=($(compgen -W "force" -- ${cur}))
                    ;;
                restore)
                    COMPREPLY=($(compgen -W "list $(_kubenv_backups | sed 's|.*/||')" -- ${cur}))
                    ;;
            esac
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
}

complete -F _kubenv_complete kubenv

function _kubenv_on_exit()
{
    [[ -n "${KUBENV_CONFIG}" ]] && rm -f -- "${KUBENV_CONFIG}"
}

# Adds _kubenv_on_exit to the shell's EXIT trap, keeping a trap that is
# already set (e.g. in ~/.bashrc).
function _kubenv_install_trap()
{
    eval "set -- $(trap -p EXIT)"   # -> trap -- '<command>' EXIT
    case "${3}" in
        *_kubenv_on_exit*) return ;;
    esac
    trap "_kubenv_on_exit${3:+; ${3}}" EXIT
}

# Main
if [ ! "${0}" != "${BASH_SOURCE[0]}" ]
then
    echo "This script must be sourced. e.g."
    echo "$ . ${0}"
    echo
    _kubenv_usage
    exit 1
fi

[ ! -d "$HOME/.kube" ] && mkdir "$HOME/.kube"
[ ! -d "${KUBENV_CONFIG_D}" ] && mkdir -p "${KUBENV_CONFIG_D}"
[ ! -f "$KUBENV_KUBECONFIG_DEFAULT" ] && touch "$KUBENV_KUBECONFIG_DEFAULT"

mkdir -p "${KUBENV_SUFFIX}" || echo "Failed to create config directory"

# Sourced again in the same shell: drop the previous file of this session.
_kubenv_on_exit
KUBENV_CONFIG=""

# Silently clean up other sessions' stale temp files before creating
# our own.
_kubenv_cleanup_old 0

KUBENV_CONFIG=$(mktemp "${KUBENV_SUFFIX}kubenv.${HOSTNAME%%.*}.$$.XXXXXXXXXX")
cp "${KUBENV_KUBECONFIG_DEFAULT}" "${KUBENV_CONFIG}"
export KUBECONFIG="${KUBENV_CONFIG}"

_kubenv_install_trap
KUBENV_KUBECTL="kubectl --kubeconfig=${KUBENV_CONFIG}"
KUBENV_PREV_CTX=""
KUBENV_PREV_NS=""
KUBENV_ENABELED=0

_kubenv_reset_context
