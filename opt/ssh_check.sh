#!/bin/bash

# Comprehensive SSH server connection tester (no temp files)
# Usage: ssh-server-check.sh --name <server_name> --host <hostname> --user <username>
#                           --port <port> --key <ssh_key> [--auth <auth_key>] [--timeout <seconds>]

# Initialize variables
TIMEOUT=5
LOG_FILE="/var/log/ssh-server-check.log"
# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) SERVER_NAME="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --key) SSH_KEY="$2"; shift 2 ;;
        --auth) AUTH_KEY="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
done

# Validate required parameters
REQUIRED_ARGS=("SERVER_NAME" "HOST" "USER" "PORT" "SSH_KEY")
for arg in "${REQUIRED_ARGS[@]}"; do
    if [ -z "${!arg}" ]; then
        echo "ERROR: Missing required argument --${arg,,}"
        exit 1
    fi
done

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "$LOG_FILE"
}

# Main test function using SSH process substitution
test_ssh_connection() {
    # Create SSH command with in-memory key
    local ssh_cmd="ssh -i $SSH_KEY -p \"$PORT\" \
                  -o ConnectTimeout=$TIMEOUT \
                  -o StrictHostKeyChecking=no \
                  -o BatchMode=yes \
                  \"$USER@$HOST\" $AUTH_KEY token_check"
    log "Testing connection to $SERVER_NAME ($HOST:$PORT)"
    log "SSH command: ${ssh_cmd//$SSH_KEY/***}"

    # 1. Test basic connection
    if ! eval "$ssh_cmd" true 2>&1 | tee -a "$LOG_FILE"; then
        log "ERROR: Basic SSH connection failed"
        return 1
    fi

    # 3. Test command execution
    test_cmd="echo SSH_TEST_SUCCESS_$(date +%s)"
    cmd_result=$(eval "$ssh_cmd" "$test_cmd" 2>/dev/null)
    if [[ "$cmd_result" != OK ]]; then
        log "ERROR: Command execution test failed"
        return 1
    fi
    
    log "Command execution verified: ${cmd_result:0:20}..."

    # 4. Test network connectivity (using process substitution for any required files)
    if ! eval "$ssh_cmd" "ping -c 3 -W 1 8.8.8.8 >/dev/null" 2>/dev/null; then
        log "WARNING: External network connectivity test failed"
    else
        log "External network connectivity verified"
    fi

    return 0
}

# Main execution
log "Starting comprehensive test for server: $SERVER_NAME"
if test_ssh_connection; then
    log "SUCCESS: All tests completed successfully for $SERVER_NAME"
    echo "OK - All tests passed for $SERVER_NAME"
    exit 0
else
    log "FAILURE: Tests failed for $SERVER_NAME"
    echo "ERROR: Connection tests failed for $SERVER_NAME"
    exit 1
fi
