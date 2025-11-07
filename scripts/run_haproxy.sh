#!/bin/bash
set -Eo pipefail

# HAProxy startup script for IB Gateway
# Processes config template, validates, and starts HAProxy with auto-restart

HAPROXY_TEMPLATE="${HOME}/haproxy/haproxy.cfg.tmpl"
HAPROXY_CONFIG="${HOME}/haproxy/haproxy.cfg"
RESTART_DELAY="${HAPROXY_RESTART:-5}"

# Function to process template and validate config
prepare_config() {
    printf ".> Processing HAProxy config template\n"

    # Process template with environment variables
    envsubst < "${HAPROXY_TEMPLATE}" > "${HAPROXY_CONFIG}"

    # Validate generated config
    if haproxy -c -f "${HAPROXY_CONFIG}" > /dev/null 2>&1; then
        printf ".> HAProxy config validation: OK\n"
        return 0
    else
        printf ".> HAProxy config validation: FAILED\n"
        haproxy -c -f "${HAPROXY_CONFIG}"
        return 1
    fi
}

# Main loop with auto-restart
while true; do
    # Prepare config
    if ! prepare_config; then
        printf ".> Config validation failed. Retrying in %d seconds...\n" "${RESTART_DELAY}"
        sleep "${RESTART_DELAY}"
        continue
    fi

    # Start HAProxy
    printf ".> Starting HAProxy (master-worker mode)\n"
    printf ".> Proxying:\n"
    printf "   - Live trading:  0.0.0.0:4001 -> 127.0.0.1:4001\n"
    printf "   - Paper trading: 0.0.0.0:4002 -> 127.0.0.1:4002\n"
    printf "   - Stats page:    0.0.0.0:8404/stats\n"

    # Run HAProxy in foreground (master-worker mode handles signals)
    haproxy -f "${HAPROXY_CONFIG}" -W

    # If HAProxy exits, wait before restarting
    EXIT_CODE=$?
    printf ".> HAProxy exited with code %d. Restarting in %d seconds...\n" "${EXIT_CODE}" "${RESTART_DELAY}"
    sleep "${RESTART_DELAY}"
done
