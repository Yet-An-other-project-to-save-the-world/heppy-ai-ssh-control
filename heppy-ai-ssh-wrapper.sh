#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
#   ssh_writer.sh – dynamic secure file operations
# -------------------------------------------------

VERSION="1.0.0"

CONFIG_DIR="$HOME/.config/heppy_ai"
CONFIG_FILE="$CONFIG_DIR/auth.conf"
KEY_FILE="$CONFIG_DIR/key.conf"

# Ensure config dir exists
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

[ ! -f "$CONFIG_FILE" ] && { echo "ERROR: Missing config file"; exit 1; }

# -------------------------------------------------
# Load allowed paths
# -------------------------------------------------
WRITE_PATHS=()
READ_PATHS=()
while IFS='=' read -r key value; do
    case "$key" in
        WRITE) WRITE_PATHS+=("$value") ;;
        READ)
            IFS=' ' read -ra paths <<< "$value"
            READ_PATHS+=("${paths[@]}")
            ;;
    esac
done < <(grep -vE '^(#|$)' "$CONFIG_FILE")

ALL_SEARCH_PATHS=("${WRITE_PATHS[@]}" "${READ_PATHS[@]}")

# -------------------------------------------------
# Security Functions
# -------------------------------------------------
validate_write_path() {
    local path="$1"
    path="$(realpath -m "$path" 2>/dev/null || echo "$path")"

    for root in "${WRITE_PATHS[@]}"; do
        if [[ "$path" == "$root"* ]]; then
            return 0
        fi
    done

    echo "ERROR: Path violation - $path not in allowed write paths: ${WRITE_PATHS[*]}" >&2
    return 1
}

validate_read_path() {
    local path="$1"
    if [[ "$path" != /* ]]; then
        for root in "${ALL_SEARCH_PATHS[@]}"; do
            if [ -e "${root%/}/$path" ]; then
                return 0
            fi
        done
    else
        path="$(realpath -m "$path" 2>/dev/null || echo "$path")"
        for root in "${ALL_SEARCH_PATHS[@]}"; do
            if [[ "$path" == "$root"* ]]; then
                return 0
            fi
        done
    fi
    echo "ERROR: Path violation - $path" >&2
    return 1
}

validate_read_path() {
    local path="$1"

    # Reject hidden files and dirs
    if [[ "$(basename "$path")" == .* ]] || [[ "$path" == */.* ]]; then
        echo "ERROR: Hidden files or directories are not allowed - $path" >&2
        return 1
    fi

    # Relative path handling
    if [[ "$path" != /* ]]; then
        for root in "${ALL_SEARCH_PATHS[@]}"; do
            if [ -e "${root%/}/$path" ]; then
                return 0
            fi
        done
    else
        # Absolute path handling
        path="$(realpath -m "$path" 2>/dev/null || echo "$path")"
        for root in "${ALL_SEARCH_PATHS[@]}"; do
            if [[ "$path" == "$root"* ]]; then
                return 0
            fi
        done
    fi

    echo "ERROR: Path violation - $path not in allowed read paths: ${ALL_SEARCH_PATHS[*]}" >&2
    return 1
}


# -------------------------------------------------
# Old Command Functions
# -------------------------------------------------
run_command() {
    local cmd="$1"
    shift
    case "$cmd" in
find_files)
    for root in "${ALL_SEARCH_PATHS[@]}"; do
        if [ $# -eq 0 ]; then
            # List all files excluding hidden dirs and hidden files
            find "$root" \
                -type d -name '.*' -prune -o \
                -type f ! -name '.*' -print
        else
            # Find all files excluding hidden dirs and files first
            files=$(find "$root" \
                -type d -name '.*' -prune -o \
                -type f ! -name '.*' -print)

            # Filter files that contain all patterns (case-insensitive)
            # Using a loop to narrow down
            filtered="$files"
            for pat in "$@"; do
                filtered=$(echo "$filtered" | grep -iF -- "$pat" || true)
            done

            echo "$filtered"
        fi
    done
    ;;

        token_check)
           echo OK
            ;;
        read_file)
            path="${1:-}"
            [ -z "$path" ] && { echo "ERROR: Missing file path"; exit 1; }
            validate_read_path "$path" || exit 1
            [ ! -f "$path" ] && { echo "ERROR: File not found"; exit 1; }
            cat "$path"
            ;;
        write_file)
            path="${1:-}"
            content="${2:-}"
            decoded_content=$(echo "$content" | base64 --decode 2>/dev/null)
            [ -z "$path" ] && { echo "ERROR: Missing file path"; exit 1; }
            validate_write_path "$path" || exit 1
            mkdir -p "$(dirname "$path")"
            printf "%s" "$decoded_content" > "$path"
            ;;
        write_check)
            path="${1:-}"
            [ -z "$path" ] && { echo "ERROR: Missing file path" >&2; echo "NOK"; exit 1; }
            if validate_write_path "$path"; then echo "OK"; else echo "NOK"; fi
            ;;
        make_project)
            project_name="${1:-}"
            [ -z "$project_name" ] && { echo "ERROR: Missing project name" >&2; exit 1; }
            if [ ${#WRITE_PATHS[@]} -eq 0 ]; then
                echo "ERROR: No WRITE paths found in config" >&2
                exit 1
            fi
            base_dir="${WRITE_PATHS[0]%/}"
            mkdir -p "$base_dir"
            while :; do
                random_id=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 9 || true)
                new_dir="${base_dir}/${project_name}-${random_id}"
                if [ ! -e "$new_dir" ]; then
                    mkdir -p "$new_dir"
                    echo "$new_dir"
                    break
                fi
            done
            ;;
        *)
            echo "ERROR: Invalid command" >&2
            exit 1
            ;;
    esac
}

# -------------------------------------------------
# Key handling
# -------------------------------------------------
generate_key() {
    local key
    # Disable 'exit on error' for this command to prevent early termination
    set +e
    key=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32)
    set -e

    if [ -z "$key" ]; then
        echo "ERROR: Failed to generate key" >&2
        exit 1
    fi

    echo "$key" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    echo "Generated key: $key"
}

check_key() {
    local provided_key="$1"
    [ ! -f "$KEY_FILE" ] && { echo "ERROR: Key file missing"; exit 1; }
    local stored_key
    stored_key=$(<"$KEY_FILE")
    if [[ "$provided_key" != "$stored_key" ]]; then
        echo "ERROR: Invalid key" >&2
        exit 1
    fi
}

# -------------------------------------------------
# Main handler
# -------------------------------------------------
case "${1:-}" in
    --version)
        echo "VERSION: $VERSION"
        ;;
    --keygen)
        generate_key
        ;;
    --exec)
        [ $# -lt 3 ] && { echo "ERROR: Usage: $0 --exec <key> <command> [args...]"; exit 1; }
        check_key "$2"
        shift 2
        run_command "$@"
        ;;
    *)
        echo "Usage:"
        echo "  $0 --keygen                  Generate a new key"
        echo "  $0 --exec <key> <cmd> [...]  Run command with key authentication"
        echo "  $0 --version                 show version";
        ;;
esac
