#!/bin/bash
KUBENV_SUFFIX="${HOME}/.kube/kubenv/"
KUBENV_KUBECONFIG_DEFAULT="${HOME}/.kube/config"
KUBENV_CONFIG_D="${HOME}/.kube/config.d"

# Files older than this age (in minutes) are removed automatically on
# startup, provided they are not currently held open by any live process.
KUBENV_CLEANUP_AGE_MIN="${KUBENV_CLEANUP_AGE_MIN:-1440}"

function _kubenv_usage()
{
    echo "kubenv allows to set kubectl context/namespace for current shell session."
    echo "You can also persist changes using 'save' command."
    echo "Remember to 'save' changes if you add new context (i.e. connect to new cluster)."
    echo
    echo "Usage:"
    echo "      kubenv [use [on|off]]|save|reload|merge|split|clean"
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
    echo "      - persists changes for the CURRENT context's namespace/cluster/user"
    echo "        back into its file in ${KUBENV_CONFIG_D}/, then rebuilds"
    echo "        ${KUBENV_KUBECONFIG_DEFAULT} from ${KUBENV_CONFIG_D}/*.yaml"
    echo "      - resets current context to 'null' afterwards, you need to switch manually"
    echo
    echo "merge"
    echo "      - rebuilds ${KUBENV_KUBECONFIG_DEFAULT} from all files in"
    echo "        ${KUBENV_CONFIG_D}/*.yaml (does not touch per-cluster files)"
    echo "      - resets current context to 'null' afterwards, you need to switch manually"
    echo
    echo "split"
    echo "      - reverse of 'merge': reads ${KUBENV_KUBECONFIG_DEFAULT} and writes"
    echo "        one file per context into ${KUBENV_CONFIG_D}/<context-name>.yaml"
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
    echo "      - restores config from the last backup (config.bkp)"
    echo "      - resets current context to 'null' afterwards, you need to switch manually"
    echo
    echo "clean"
    echo "      - removes stale per-session temp kubeconfig files from ${KUBENV_SUFFIX}"
    echo "        (files older than ${KUBENV_CLEANUP_AGE_MIN} min that are not held open"
    echo "        by any running shell); runs automatically every time kubenv is sourced"
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
            if [[ ${KUBENV_ENABELED} == 0 && "${KUBENV_PREV_CTX}" != "" ]]
            then
                ${KUBENV_KUBECTL} config use-context "${KUBENV_PREV_CTX}"
                KUBENV_PREV_CTX=${current_context}
            elif [[ ${KUBENV_ENABELED} == 1 ]]
            then
                echo "kubenv is disabled"
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
    [[ ${current_context} = "null" ]] && return

    current_namespace=$(${KUBENV_KUBECTL} config view --output="jsonpath={.contexts[?(@.name==\"${current_context}\")].context.namespace}")
    case "${1}" in
        ""|all)
            for c in $(${KUBENV_KUBECTL} get namespace --output="jsonpath={range.items[*]}{.metadata.name}:{end}"|tr ':' '\n')
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
            if [[ ${KUBENV_ENABELED} == 0 && "${KUBENV_PREV_NS}" != "" ]]
            then
                ${KUBENV_KUBECTL} config set-context "${current_context}" --namespace "${KUBENV_PREV_NS}"
                KUBENV_PREV_NS=${current_namespace}
            elif [[ ${KUBENV_ENABELED} == 1 ]]
            then
                echo "kubenv is disabled"
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
    kubectl config set-cluster null --server=''  --certificate-authority='' --kubeconfig=${KUBENV_CONFIG} >/dev/null 2>&1
    kubectl config set-credentials null --username='' --password='' --kubeconfig=${KUBENV_CONFIG} >/dev/null 2>&1
    kubectl config set-context null --cluster=null --user=null --kubeconfig=${KUBENV_CONFIG} >/dev/null 2>&1
    kubectl config use-context null --kubeconfig=${KUBENV_CONFIG} >/dev/null 2>&1

    KUBENV_PREV_CTX=""
    KUBENV_PREV_NS=""
    echo "Context reset to 'null', please switch context manually (kubenv ctx <name>)"
}

# Removes stale/unused temporary kubeconfig files from ${KUBENV_SUFFIX}
# (files named kubenv.XXXXXXXXXX, created by mktemp every time this
# script is sourced).
#
# A file is considered "dead" and removed if BOTH of the following hold:
#   1. it is older than ${KUBENV_CLEANUP_AGE_MIN} minutes (1 day by default);
#   2. it is not currently held open by any live process (checked via
#      lsof/fuser when available - this protects files still in use by
#      active sessions, even if those sessions have been idle longer
#      than the threshold).
# The current session's own file (${KUBENV_CONFIG}, if already set) is
# always skipped.
#
# "kubenv clean" calls this function explicitly and prints a report of
# what was removed/skipped. On a normal source of the script it is also
# called automatically, but silently, so it doesn't clutter the output.
function _kubenv_cleanup_old()
{
    local verbose="${1:-0}"
    local removed=0 skipped_open=0 skipped_young=0
    local f age_min

    [[ -d "${KUBENV_SUFFIX}" ]] || return 0

    for f in "${KUBENV_SUFFIX}"kubenv.*
    do
        [[ -f "${f}" ]] || continue
        [[ -n "${KUBENV_CONFIG}" && "${f}" == "${KUBENV_CONFIG}" ]] && continue

        # Skip files younger than the threshold, so we don't touch files
        # that other sessions are creating right now, in parallel.
        if [[ -n "$(find "${f}" -mmin "-${KUBENV_CLEANUP_AGE_MIN}" 2>/dev/null)" ]]
        then
            skipped_young=$((skipped_young + 1))
            continue
        fi

        # Don't touch the file if it's still open by some live session
        # (e.g. a long-running terminal holding onto an old file).
        if command -v lsof >/dev/null 2>&1
        then
            if lsof -- "${f}" >/dev/null 2>&1
            then
                skipped_open=$((skipped_open + 1))
                continue
            fi
        elif command -v fuser >/dev/null 2>&1
        then
            if fuser "${f}" >/dev/null 2>&1
            then
                skipped_open=$((skipped_open + 1))
                continue
            fi
        fi

        rm -f -- "${f}"
        removed=$((removed + 1))
    done

    if [[ "${verbose}" == "1" ]]
    then
        echo "kubenv clean: removed ${removed} stale file(s), skipped ${skipped_open} in use, ${skipped_young} too recent"
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
            [[ -f "${f}" ]] && files+=("${f}")
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

# Rebuilds ~/.kube/config from ~/.kube/config.d/*.yaml
function _kubenv_merge()
{
    local merged
    merged=$(_kubenv_build_merged) || return 1

    cp "${KUBENV_KUBECONFIG_DEFAULT}" "${KUBENV_SUFFIX}/config.bkp" 2>/dev/null

    echo "${merged}" > "${KUBENV_KUBECONFIG_DEFAULT}"
    echo "Rebuilt ${KUBENV_KUBECONFIG_DEFAULT} from $(ls "${KUBENV_CONFIG_D}"/*.yaml "${KUBENV_CONFIG_D}"/*.yml 2>/dev/null | wc -l | tr -d ' ') file(s) in ${KUBENV_CONFIG_D}"

    # pick up the result in the current session too
    cp "${KUBENV_KUBECONFIG_DEFAULT}" "${KUBENV_CONFIG}"

    _kubenv_reset_context
}

# Saves the current context (cluster/user/context/namespace) back to its
# own file in config.d/<cluster-name>.yaml, then rebuilds the combined
# ~/.kube/config from all files in config.d.
function _kubenv_save()
{
    mkdir -p "${KUBENV_CONFIG_D}"

    local current_context cluster_name file
    current_context=$(${KUBENV_KUBECTL} config current-context 2>/dev/null)

    if [[ -z "${current_context}" || "${current_context}" == "null" ]]
    then
        echo "No active context to save (current context is empty or 'null')"
        return 1
    fi

    cluster_name=$(${KUBENV_KUBECTL} config view --raw --output="jsonpath={.contexts[?(@.name==\"${current_context}\")].context.cluster}")
    if [[ -z "${cluster_name}" ]]
    then
        cluster_name="${current_context}"
    fi

    file="${KUBENV_CONFIG_D}/${cluster_name}.yaml"

    # The minified (--minify) config contains only the current
    # context/cluster/user - exactly what's needed for a per-cluster file.
    ${KUBENV_KUBECTL} config view --raw --minify --flatten > "${file}"

    echo "Saved context '${current_context}' to ${file}"

    # _kubenv_merge already resets the context at the end
    _kubenv_merge
}

# Reverse of merge/save: reads ~/.kube/config (or KUBENV_CONFIG - the
# current working copy, if merge hasn't been run yet) and splits every
# context out into its own file config.d/<context-name>.yaml.
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

    local ctx file written=0 skipped=0
    for ctx in ${contexts}
    do
        # "null" is kubenv's own internal context, skip it
        [[ "${ctx}" == "null" ]] && continue

        file="${KUBENV_CONFIG_D}/${ctx}.yaml"

        if [[ -f "${file}" && "${force}" != "force" ]]
        then
            echo "Skipping ${ctx} (${file} already exists, use 'kubenv split force' to overwrite)"
            skipped=$((skipped + 1))
            continue
        fi

        KUBECONFIG="${KUBENV_KUBECONFIG_DEFAULT}" kubectl config view --raw --minify --flatten --context="${ctx}" > "${file}"
        echo "Wrote ${file}"
        written=$((written + 1))
    done

    echo "Split done: ${written} file(s) written, ${skipped} skipped."

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
                cp "${KUBENV_SUFFIX}/config.bkp" "${KUBENV_KUBECONFIG_DEFAULT}"
                cp "${KUBENV_KUBECONFIG_DEFAULT}" "${KUBENV_CONFIG}"
                _kubenv_reset_context
                ;;
            save)
                _kubenv_save
                ;;
            merge)
                _kubenv_merge
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
                    COMPREPLY=($(compgen -W "$(${KUBENV_KUBECTL} get namespace --output="jsonpath={range.items[*]}{.metadata.name}:{end}"|tr ':' '\n')" -- ${cur}))
                    ;;
                split)
                    COMPREPLY=($(compgen -W "force" -- ${cur}))
                    ;;
            esac
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
}

complete -F _kubenv_complete kubenv

# Main
if [ ! "${0}" != "${BASH_SOURCE[0]}" ]
then
    echo "This script must be sourced. e.g."
    echo "$ . ${0}"
    echo
    _kubenv_usage
    exit 1
fi

[ ! -d $HOME/.kube ] && mkdir $HOME/.kube
[ ! -d "${KUBENV_CONFIG_D}" ] && mkdir -p "${KUBENV_CONFIG_D}"
[ ! -f $KUBENV_KUBECONFIG_DEFAULT ] && touch $KUBENV_KUBECONFIG_DEFAULT

mkdir -p "${KUBENV_SUFFIX}" || echo "Failed to create config directory"

# Silently clean up other sessions' stale temp files before creating
# our own.
_kubenv_cleanup_old 0

KUBENV_CONFIG=$(mktemp "${KUBENV_SUFFIX}kubenv.XXXXXXXXXX")
cp "${KUBENV_KUBECONFIG_DEFAULT}" "${KUBENV_CONFIG}"
export KUBECONFIG="${KUBENV_CONFIG}"

trap "rm ${KUBENV_CONFIG}" EXIT
KUBENV_KUBECTL="kubectl --kubeconfig=${KUBENV_CONFIG}"
KUBENV_PREV_CTX=""
KUBENV_PREV_NS=""
KUBENV_ENABELED=0

_kubenv_reset_context
