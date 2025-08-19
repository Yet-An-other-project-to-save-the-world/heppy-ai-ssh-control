#!/bin/bash
set -uo pipefail

# heppy-ai-ssh-wrapper.sh
# Version: 1.1.0
# Adds multi-branch workflow helpers and safer path handling.

VERSION="1.1.0"
CONFIG_DIR="$HOME/.config/heppy_ai"
CONFIG_FILE="$CONFIG_DIR/auth.conf"
KEY_FILE="$CONFIG_DIR/key.conf"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Missing config file at $CONFIG_FILE"
  exit 1
fi

# Load allowed paths from config
WRITE_PATHS=()
READ_PATHS=()
# Read lines ignoring comments and blank lines
while IFS='=' read -r key value || [ -n "$key" ]; do
  # skip comments / empty
  [[ "$key" =~ ^# ]] && continue
  [[ -z "$key" ]] && continue
  case "$key" in
    WRITE) WRITE_PATHS+=("$value") ;;
    READ) IFS=' ' read -ra paths <<< "$value"; READ_PATHS+=("${paths[@]}") ;;
  esac
done < <(grep -vE '^(#|$)' "$CONFIG_FILE")

ALL_SEARCH_PATHS=("${WRITE_PATHS[@]}" "${READ_PATHS[@]}")

# ---------------------------
# Key handling
# ---------------------------
generate_key() {
    local key
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

# ---------------------------
# Path validation (symlink-safe)
# ---------------------------
validate_write_path() {
  local path="$1"

  # If file exists, resolve symlink to its real location
  if [ -e "$path" ]; then
    path="$(realpath -se "$path" 2>/dev/null)" || {
      echo "ERROR: Cannot resolve $path" >&2
      return 1
    }
  else
    # For new files, check the parent directory instead
    local dir
    dir="$(dirname "$path")"
    dir="$(realpath -se "$dir" 2>/dev/null)" || {
      echo "ERROR: Cannot resolve $dir" >&2
      return 1
    }
    path="$dir/$(basename "$path")"
  fi

  for root in "${WRITE_PATHS[@]}"; do
    # ensure root is resolved too
    root="$(realpath -se "$root" 2>/dev/null || echo "$root")"
    if [[ "$path" == "$root"* ]]; then
      return 0
    fi
  done

  echo "ERROR: Path violation - $path not in allowed write paths" >&2
  return 1
}

validate_read_path() {
  local path="$1"

  # Reject hidden files/dirs (quick check)
  if [[ "$(basename "$path")" == .* ]] || [[ "$path" == */.* ]]; then
    echo "ERROR: Hidden files or directories are not allowed - $path" >&2
    return 1
  fi

  [ ! -e "$path" ] && {
    echo "ERROR: File not found: $path" >&2
    return 1
  }

  path="$(realpath -se "$path" 2>/dev/null)" || {
    echo "ERROR: Cannot resolve $path" >&2
    return 1
  }

  for root in "${ALL_SEARCH_PATHS[@]}"; do
    root="$(realpath -se "$root" 2>/dev/null || echo "$root")"
    if [[ "$path" == "$root"* ]]; then
      return 0
    fi
  done

  echo "ERROR: Path violation - $path not in allowed read paths" >&2
  return 1
}

# ---------------------------
# Git helpers and workflow
# ---------------------------
setup_git_identity() {
  # Only set global if not present
  if [ -z "$(git config --global user.name || true)" ]; then
    git config --global user.name "Heppy AI"
    git config --global user.email "yaptstw@hepppy.com"
  fi
}

# Ensure a fork exists under the bot's GH account for an upstream repo,
# then clone that fork into a unique local directory and return the path.
# Usage: git_clone_fork <original_repo_url>
git_clone_fork() {
  local ORIGINAL_REPO="$1"
  if [ -z "$ORIGINAL_REPO" ]; then
    echo "ERROR: git_clone_fork requires an original repo URL" >&2
    return 1
  fi

  # base write dir
  if [ ${#WRITE_PATHS[@]} -eq 0 ]; then
    echo "ERROR: No WRITE paths configured" >&2
    return 1
  fi
  local base_dir="${WRITE_PATHS[0]%/}"
  mkdir -p "$base_dir"

  # extract basename (e.g., repo.git -> repo)
  local repo_basename
  repo_basename=$(basename "$ORIGINAL_REPO")
  repo_basename="${repo_basename%.git}"

  # Get logged-in GH username
  local USER_LOGIN
  USER_LOGIN=$(gh api user --jq .login 2>/dev/null) || true
  if [ -z "$USER_LOGIN" ]; then
    echo "ERROR: Unable to get GitHub username. Run: gh auth login" >&2
    return 1
  fi

  # If fork already exists, reuse it; otherwise create fork
  if gh repo view "$USER_LOGIN/$repo_basename" >/dev/null 2>&1; then
    local fork_name="$repo_basename"
  else
    gh repo fork "$ORIGINAL_REPO" --remote=false --clone=false || {
      echo "ERROR: gh repo fork failed" >&2
      return 1
    }
    local fork_name="$repo_basename"
  fi

  # Create unique local dir
  local target_dir=""
  while :; do
    local random_id
    random_id=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 9 || true)
    local new_dir="${base_dir}/git-project-${repo_basename}-${random_id}"
    if [ ! -e "$new_dir" ]; then
      mkdir -p "$new_dir"
      target_dir="$new_dir"
      break
    fi
  done

  # ensure known hosts
  mkdir -p ~/.ssh
  ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || true

  # Clone fork
  git clone "git@github.com:${USER_LOGIN}/${fork_name}.git" "$target_dir" || {
    echo "ERROR: git clone failed" >&2
    rm -rf "$target_dir"
    return 1
  }

  echo "$target_dir"
}

git_add() {
  local repo_dir=$1
  shift
  local files=("$@")

  if [ ! -d "$repo_dir/.git" ]; then
    echo "ERROR: Not a git repo: $repo_dir" >&2
    return 1
  fi

  # If no files specified, add all changes
  if [ ${#files[@]} -eq 0 ]; then
    files=(".")
  fi

  git -C "$repo_dir" add "$files" \
      && echo "✅ Staged '$files' for commit in $(basename "$repo_dir")" \
      || echo "❌ Failed to stage '$file_dir'"


}



# Create a session branch inside an already-cloned repo dir
# Usage: git_branch <repo_dir> [branch_name]
git_branch() {
  local repo_dir="$1"
  local branch_name="${2:-}"

  [ -z "$repo_dir" ] && { echo "ERROR: Missing repo_dir"; return 1; }
  [ ! -d "$repo_dir/.git" ] && { echo "ERROR: $repo_dir is not a git repo"; return 1; }

  if [ -z "$branch_name" ]; then
    branch_name="heppy-session-$(tr -dc 'a-z0-9' </dev/urandom | head -c 8 || echo "$RANDOM")"
  fi

  git -C "$repo_dir" checkout -b "$branch_name" || {
    echo "ERROR: Failed to create branch $branch_name" >&2
    return 1
  }

  echo "$branch_name"
}

# Commit staged changes and push to origin
# Usage: git_commit_push <repo_dir> <branch_name> <commit_msg>
git_commit_push() {
  local repo_dir="$1"
  local branch_name="$2"
  local commit_msg="${3:-Automated changes by Heppy AI}"

  [ -z "$repo_dir" ] && { echo "ERROR: Missing repo_dir"; return 1; }
  [ -z "$branch_name" ] && { echo "ERROR: Missing branch_name"; return 1; }
  [ ! -d "$repo_dir/.git" ] && { echo "ERROR: $repo_dir is not a git repo"; return 1; }

  # Ensure on correct branch
  git -C "$repo_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1 || {
    echo "ERROR: Branch $branch_name does not exist in $repo_dir" >&2
    return 1
  }
  git -C "$repo_dir" checkout "$branch_name"

  # Stage all changes in working tree (you may want to be more selective in production)
  git -C "$repo_dir" add -A

  # If nothing to commit, still attempt to push branch if it doesn't exist remotely
  if git -C "$repo_dir" diff --cached --quiet; then
  :
  else
    git -C "$repo_dir" commit -m "$commit_msg" || {
      echo "ERROR: git commit failed" >&2
      return 1
    }
  fi

  # Push branch
  git -C "$repo_dir" push -u origin "$branch_name" || {
    echo "ERROR: git push failed. Trying to pull --rebase and retry..."
    git -C "$repo_dir" pull --rebase origin "$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)" || {
      echo "ERROR: pull --rebase failed" >&2
      return 1
    }
    git -C "$repo_dir" push -u origin "$branch_name" || {
      echo "ERROR: git push failed after retry" >&2
      return 1
    }
  }

  echo "OK"
}

# Create a PR from branch to base
# Usage: git_pr <repo_dir> <branch_name> <base_branch> <title> <body>
git_pr() {
  local repo_dir="$1"
  local branch_name="$2"
  local base_branch="${3:-main}"
  local title="${4:-Automated changes by Heppy AI}"
  local body="${5:-This PR was created automatically by Heppy AI.}"

  [ -z "$repo_dir" ] && { echo "ERROR: Missing repo_dir"; return 1; }
  [ -z "$branch_name" ] && { echo "ERROR: Missing branch_name"; return 1; }
  [ ! -d "$repo_dir/.git" ] && { echo "ERROR: $repo_dir is not a git repo"; return 1; }

  # Ensure branch is pushed to fork
  if ! git -C "$repo_dir" ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1; then
    echo "ERROR: Branch $branch_name not found on fork. Push first." >&2
    return 1
  fi

  # Get the original repository URL from git config
  local original_repo
  original_repo=$(git -C "$repo_dir" config --get heppy.original-repo)
  
  if [ -z "$original_repo" ]; then
    # Fallback: Try to get from origin remote (for backwards compatibility)
    local origin_url
    origin_url=$(git -C "$repo_dir" remote get-url origin)
    if [[ "$origin_url" =~ github.com[:\/](.*)\.git ]]; then
      original_repo="https://github.com/Bram-diederik/cmdline-assist.git"
    else
      echo "ERROR: Could not determine original repository" >&2
      return 1
    fi
  fi

  # Extract owner/repo from original URL
  local repo_path
  if [[ "$original_repo" =~ github.com[:\/]([^/]+/[^/]+)\.git$ ]]; then
    repo_path="${BASH_REMATCH[1]}"
  else
    echo "ERROR: Could not parse repository path from $original_repo" >&2
    return 1
  fi

  # Get current user's GitHub username
  local github_user
  github_user=$(gh api user --jq .login 2>/dev/null) || {
    echo "ERROR: Could not get GitHub username. Run 'gh auth login' first." >&2
    return 1
  }

  # Create PR in original repository pointing to our fork's branch
  (cd "$repo_dir" && gh pr create \
    --repo "$repo_path" \
    --base "$base_branch" \
    --head "$github_user:$branch_name" \
    --title "$title" \
    --body "$body") || {
    echo "ERROR: Failed to create pull request" >&2
    return 1
  }

  # Return PR URL
  local pr_url
  pr_url=$(cd "$repo_dir" && gh pr view --repo "$repo_path" --json url --jq .url 2>/dev/null)
  echo "$pr_url"
}


# Delete local and remote branch
# Usage: git_cleanup_branch <repo_dir> <branch_name>
git_cleanup_branch() {
  local repo_dir="$1"
  local branch_name="$2"

  [ -z "$repo_dir" ] && { echo "ERROR: Missing repo_dir"; return 1; }
  [ -z "$branch_name" ] && { echo "ERROR: Missing branch_name"; return 1; }
  [ ! -d "$repo_dir/.git" ] && { echo "ERROR: $repo_dir is not a git repo"; return 1; }

  # Delete remote branch
  git -C "$repo_dir" push origin --delete "$branch_name" || {
    echo "WARN: remote branch delete failed or branch didn't exist"
  }

  # Delete local
  if git -C "$repo_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    git -C "$repo_dir" branch -D "$branch_name" || {
      echo "WARN: local branch delete failed"
    }
  fi

  echo "OK"
}

# ---------------------------
# Command dispatcher
# ---------------------------
run_command() {
  local cmd="$1"
  shift
  case "$cmd" in
        read_file)
        local path="${1:-}"
        [ -z "$path" ] && { echo "ERROR: Missing file path"; return 1; }
      
        local exists=0
        [ -e "$path" ] && exists=1
      
        if ! validate_read_path "$path"; then
          if [ "$exists" -eq 1 ]; then
            echo "ERROR: File exists but security prevents reading: $path"
          fi
          return 1
        fi
      
        [ ! -f "$path" ] && { echo "ERROR: File not found"; return 1; }
      
        case "$path" in
          *.odt|*.ods|*.odp)
            odt2txt "$path"
            ;;
          *)
            cat "$path"
            ;;
        esac
        ;;

    token_check)
      echo OK
      ;;
    read_file)
      local path="${1:-}"
     [ -z "$path" ] && { echo "ERROR: Missing file path"; return 1; }

     local exists=0
     [ -e "$path" ] && exists=1

     if ! validate_read_path "$path"; then
       if [ "$exists" -eq 1 ]; then
         echo "ERROR: File exists but security prevents reading: $path"
       fi
       return 1
     fi
     [ ! -f "$path" ] && { echo "ERROR: File not found"; return 1; }
     cat "$path"
    ;;
    write_file)
      local path="${1:-}"
      local content="${2:-}"
      [ -z "$path" ] && { echo "ERROR: Missing file path"; return 1; }
      [ -z "$content" ] && { echo "ERROR: Missing content (base64)"; return 1; }
      validate_write_path "$path" || return 1
      mkdir -p "$(dirname "$path")"
      # atomic write
      tmpfile=$(mktemp "${path}.tmp.XXXXXX")
      echo "$content" | base64 --decode > "$tmpfile" || { rm -f "$tmpfile"; echo "ERROR: decode failed"; return 1; }
      mv "$tmpfile" "$path"
      chmod 600 "$path" || true
      echo "OK"
      ;;
    write_check)
      local path="${1:-}"
      [ -z "$path" ] && { echo "ERROR: Missing file path" >&2; echo "NOK"; return 1; }
      if validate_write_path "$path"; then echo "OK"; else echo "NOK"; fi
      ;;
    make_project)
      local project_name="${1:-}"
      [ -z "$project_name" ] && { echo "ERROR: Missing project name" >&2; return 1; }
      if [ ${#WRITE_PATHS[@]} -eq 0 ]; then
        echo "ERROR: No WRITE paths found in config" >&2
        return 1
      fi
      local base_dir="${WRITE_PATHS[0]%/}"
      mkdir -p "$base_dir"
      while :; do
        local random_id
        random_id=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 9 || true)
        local new_dir="${base_dir}/${project_name}-${random_id}"
        if [ ! -e "$new_dir" ]; then
          mkdir -p "$new_dir"
          echo "$new_dir"
          break
        fi
      done
      ;;
    git_fork)
      if [ $# -lt 1 ]; then
        echo "ERROR: Usage: git_fork <repo_url>" >&2
        return 1
      fi
      git_clone_fork "$1"
      ;;
    git_add)
      if [ $# -lt 1 ]; then
        echo "ERROR: Usage: git_add <repo_dir> [files...]" >&2
        return 1
      fi
      git_add "$@"
      ;;
    git_clone_fork)
      if [ $# -lt 1 ]; then
        echo "ERROR: Usage: git_clone_fork <repo_url>" >&2
        return 1
      fi
      git_clone_fork "$1"
      ;;
    git_branch)
      if [ $# -lt 1 ]; then
        echo "ERROR: Usage: git_branch <repo_dir> [branch_name]" >&2
        return 1
      fi
      git_branch "$@"
      ;;
    git_commit_push)
      if [ $# -lt 2 ]; then
        echo "ERROR: Usage: git_commit_push <repo_dir> <branch_name> [commit_msg]" >&2
        return 1
      fi
      git_commit_push "$@"
      ;;
    git_pr)
      if [ $# -lt 3 ]; then
        echo "ERROR: Usage: git_pr <repo_dir> <branch_name> <base_branch> [title] [body]" >&2
        return 1
      fi
      git_pr "$@"
      ;;
    git_cleanup_branch)
      if [ $# -lt 2 ]; then
        echo "ERROR: Usage: git_cleanup_branch <repo_dir> <branch_name>" >&2
        return 1
      fi
      git_cleanup_branch "$@"
      ;;
    # Add other commands here...
    *)
      echo "ERROR: Unknown command: $cmd" >&2
      return 1
      ;;
  esac
}

main() {
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
      echo "  $0 --version                 show version"
      ;;
  esac
}

main "$@"
