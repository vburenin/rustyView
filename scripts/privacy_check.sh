#!/usr/bin/env bash

set -u

scan_mode=worktree
if [[ ${1:-} == "--staged" ]]; then
    scan_mode=staged
    shift
fi

if (( $# > 0 )); then
    echo "usage: scripts/privacy_check.sh [--staged]" >&2
    exit 2
fi

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "privacy check: run this script inside the repository" >&2
    exit 2
}

cd "$repository_root" || exit 2

failure_count=0
staged_content_root=""
staged_file_number=0

if [[ "$scan_mode" == staged ]]; then
    staged_content_root=$(mktemp -d "${TMPDIR:-/tmp}/rustyview-privacy-staged.XXXXXX") || exit 2
    trap 'rm -rf "$staged_content_root"' EXIT
fi

report_match() {
    local file=$1
    local line=$2
    local reason=$3
    printf 'privacy check: %s:%s: %s\n' "$file" "$line" "$reason" >&2
    failure_count=$((failure_count + 1))
}

report_regex_matches() {
    local file=$1
    local content_file=$2
    local pattern=$3
    local reason=$4
    local matches
    local match
    local line

    matches=$(LC_ALL=C grep -En "$pattern" "$content_file" 2>/dev/null || true)
    [[ -z "$matches" ]] && return

    while IFS= read -r match; do
        line=${match%%:*}
        report_match "$file" "$line" "$reason"
    done <<< "$matches"
}

is_allowed_public_host() {
    case "$1" in
        rustyview-support.vburenin.chatgpt.site|rusty.firempq.com)
            # Public App Store support/privacy pages, never a media server.
            return 0
            ;;
        example|*.example|example.com|*.example.com|example.test|*.example.test|invalid|*.invalid|localhost|127.0.0.1|www.apple.com|developer.apple.com|www.apache.org)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

scan_urls() {
    local file=$1
    local content_file=$2
    local matches
    local match
    local line
    local url
    local authority
    local host

    matches=$(LC_ALL=C grep -Eon 'https?://[^[:space:]`"<>\\)]+' "$content_file" 2>/dev/null || true)
    [[ -z "$matches" ]] && return

    while IFS= read -r match; do
        line=${match%%:*}
        url=${match#*:}
        authority=${url#*://}
        authority=${authority%%/*}

        if [[ "$authority" == *@* ]]; then
            report_match "$file" "$line" "credential-bearing URL"
            continue
        fi

        host=${authority%%:*}
        # Public companion project linked from the product documentation.
        if [[ "$url" == "https://github.com/vburenin/rustyDLNA" ]]; then
            continue
        fi
        if ! is_allowed_public_host "$host"; then
            report_match "$file" "$line" "non-example URL literal; keep deploy endpoints in ignored local configuration"
        fi
    done <<< "$matches"
}

scan_local_denylist() {
    local file=$1
    local content_file=$2
    local needle
    local matches
    local match
    local line

    [[ -f .privacy-denylist ]] || return

    while IFS= read -r needle || [[ -n "$needle" ]]; do
        [[ -z "$needle" || "$needle" == \#* ]] && continue
        if [[ "$needle" =~ ^[[:alnum:]_]+$ ]]; then
            matches=$(LC_ALL=C grep -En "(^|[^[:alnum:]_])${needle}([^[:alnum:]_]|$)" "$content_file" 2>/dev/null || true)
        else
            matches=$(LC_ALL=C grep -Fn -- "$needle" "$content_file" 2>/dev/null || true)
        fi
        [[ -z "$matches" ]] && continue

        while IFS= read -r match; do
            line=${match%%:*}
            report_match "$file" "$line" "matches a private identifier from the local denylist"
        done <<< "$matches"
    done < .privacy-denylist
}

home_path_prefix='/Users/'
home_path_pattern="${home_path_prefix}[^/[:space:]\"']+"
pem_pattern='-----BEGIN [A-Z ]+ PRIVATE KEY-----'
private_ip_pattern='(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
email_pattern='[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
token_pattern='(AKIA|ASIA)[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|sk_live_[0-9A-Za-z]{16,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'

list_candidates() {
    if [[ "$scan_mode" == staged ]]; then
        git diff --cached --name-only --diff-filter=ACMR -z
    else
        git ls-files --cached --others --exclude-standard -z
    fi
}

while IFS= read -r -d '' file; do
    content_file=$file
    if [[ "$scan_mode" == staged ]]; then
        staged_file_number=$((staged_file_number + 1))
        content_file="$staged_content_root/$staged_file_number"
        if ! git show ":$file" > "$content_file"; then
            report_match "$file" "-" "could not inspect staged content"
            continue
        fi
    fi

    case "$file" in
        *.pem|*.p12|*.mobileprovision|*.sqlite|*.sqlite-shm|*.sqlite-wal|*.realm|*.log|*.xcuserstate|*.mkv|*.avi|*.mov|*.m4v)
            report_match "$file" "-" "sensitive or user-generated file type must not be committed"
            continue
            ;;
        *.mp4|*.ts|*.webm)
            case "$file" in
                rustyViewUITests/Fixtures/synthetic-playback.mp4|rustyViewUITests/Fixtures/synthetic-playback.ts|rustyViewUITests/Fixtures/synthetic-multiaudio.mp4|rustyViewUITests/Fixtures/synthetic-native-caption.mp4|rustyViewUITests/Fixtures/synthetic-stall-0.ts|rustyViewUITests/Fixtures/synthetic-stall-1.ts|rustyViewUITests/Fixtures/synthetic-stall-2.ts|rustyViewTests/Fixtures/synthetic-offline-valid.mp4|rustyViewTests/Fixtures/synthetic-offline-unsupported.webm|rustyViewTests/Fixtures/synthetic-native-tracks.mp4)
                    ;;
                *)
                    report_match "$file" "-" "media is not an explicitly reviewed synthetic test fixture"
                    ;;
            esac
            continue
            ;;
    esac

    LC_ALL=C grep -Iq . "$content_file" 2>/dev/null || continue

    report_regex_matches "$file" "$content_file" "$home_path_pattern" "absolute macOS home path"
    report_regex_matches "$file" "$content_file" "$pem_pattern" "embedded private key"
    report_regex_matches "$file" "$content_file" "$private_ip_pattern" "private-network IPv4 address"
    report_regex_matches "$file" "$content_file" "$token_pattern" "high-confidence credential token"
    scan_urls "$file" "$content_file"
    scan_local_denylist "$file" "$content_file"

    email_matches=$(LC_ALL=C grep -Eon "$email_pattern" "$content_file" 2>/dev/null || true)
    if [[ -n "$email_matches" ]]; then
        while IFS= read -r match; do
            line=${match%%:*}
            email=${match#*:}
            domain=${email##*@}
            # The owner explicitly designated this public App Store contact.
            if [[ "$email" == "vbhomeai@gmail.com" &&
                  ( "$file" == "docs/APP_STORE.md" || "$file" == "scripts/privacy_check.sh" ) ]]; then
                continue
            fi
            case "$domain" in
                example|*.example|example.com|*.example.com|example.test|*.example.test|invalid|*.invalid)
                    ;;
                *)
                    report_match "$file" "$line" "non-example email address"
                    ;;
            esac
        done <<< "$email_matches"
    fi
done < <(list_candidates)

if (( failure_count > 0 )); then
    printf 'privacy check failed with %d finding(s).\n' "$failure_count" >&2
    exit 1
fi

echo "privacy check passed"
