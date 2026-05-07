#!/usr/bin/env bash
# Start/stop/status the local BPP service stack required by integration tests.
# Logs in /tmp/bpp-local-stack/, PID tracking in /tmp/bpp-local-stack/pids.
#
# Usage:
#   ./start_local_stack.sh           # start (default)
#   ./start_local_stack.sh start     # explicit start
#   ./start_local_stack.sh stop      # stop services started by this script
#   ./start_local_stack.sh status    # show health of all 4 services

set -euo pipefail

LOG_DIR=/tmp/bpp-local-stack
PID_FILE="${LOG_DIR}/pids"
ROOT="${HOME}/Entwicklung/bpp"
WAIT_MAX_SECONDS=180

mkdir -p "$LOG_DIR"

# Service registry: name|kind|relative-path|health-url
SERVICES=(
    "bpp-auth|dotnet|bpp-auth/BPP.Auth.NET/BPP.Auth.NET.API|http://localhost:5240/health"
    "bpp-file|dotnet|bpp-file/BPP.File.NET/BPP.File.NET.API|http://localhost:5242/health"
    "bpp-mail|mvn|bpp-mail|http://localhost:8082/actuator/health"
    "bpp-js-report-connector|mvn|bpp-js-report-connector|http://localhost:8081/actuator/health"
    "bpp-push|dotnet|bpp-push/BPP.Push.NET/BPP.Push.NET.API|http://localhost:5245/health"
)

is_healthy() {
    curl -fs -o /dev/null -m 2 "$1"
}

start_one() {
    local name=$1 kind=$2 rel_path=$3 health_url=$4
    local abs_path="${ROOT}/${rel_path}"

    if is_healthy "$health_url"; then
        echo "[$name] already UP — skipping"
        return
    fi

    if [[ ! -d "$abs_path" ]]; then
        echo "[$name] FAILED: path does not exist: $abs_path"
        return 1
    fi

    local log="${LOG_DIR}/${name}.log"
    echo "[$name] starting (logs: $log)..."

    case "$kind" in
        dotnet)
            (cd "$abs_path" && ASPNETCORE_ENVIRONMENT=local nohup dotnet run > "$log" 2>&1 &
                echo "${name}=$!" >> "$PID_FILE")
            ;;
        mvn)
            (cd "$abs_path" && nohup ./mvnw spring-boot:run > "$log" 2>&1 &
                echo "${name}=$!" >> "$PID_FILE")
            ;;
        *)
            echo "[$name] unknown kind: $kind"
            return 1
            ;;
    esac
}

wait_for_one() {
    local name=$1 health_url=$2
    local elapsed=0
    while ! is_healthy "$health_url"; do
        if (( elapsed >= WAIT_MAX_SECONDS )); then
            echo "[$name] NEVER healthy after ${WAIT_MAX_SECONDS}s — see ${LOG_DIR}/${name}.log"
            return 1
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    echo "[$name] healthy after ${elapsed}s"
}

cmd_start() {
    : > "$PID_FILE"  # truncate
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r name kind rel_path health_url <<< "$entry"
        start_one "$name" "$kind" "$rel_path" "$health_url"
    done

    echo
    echo "Waiting for all services to become healthy (up to ${WAIT_MAX_SECONDS}s each)..."
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r name kind rel_path health_url <<< "$entry"
        wait_for_one "$name" "$health_url"
    done

    echo
    echo "All services UP. Run integration tests with:"
    echo "  cd ${ROOT}/bpp-backend/BPP.Backend.NET/BPP.Backend.NET.Products.Tests && \\"
    echo "    dotnet test --filter Category=LocalIntegration"
}

cmd_stop() {
    # `dotnet run` / `mvn spring-boot:run` are launchers — they fork the real server then exit.
    # Tracked launcher PIDs are stale, so we kill by port via `ss -tlnp`.
    local stopped_anything=false
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r name kind rel_path health_url <<< "$entry"
        local port=${health_url##*localhost:}
        port=${port%%/*}

        local pids
        pids=$(ss -H -tlnp "sport = :${port}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u | tr '\n' ' ')
        if [[ -n "$pids" ]]; then
            echo "Stopping $name (port $port, PIDs: $pids)..."
            kill $pids 2>/dev/null || true
            stopped_anything=true
        fi
    done

    if [[ -f "$PID_FILE" ]]; then
        rm -f "$PID_FILE"
    fi

    if [[ "$stopped_anything" == false ]]; then
        echo "No services were running on the expected ports."
    else
        echo "Done. Verify with: $0 status"
    fi
}

cmd_status() {
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r name kind rel_path health_url <<< "$entry"
        if is_healthy "$health_url"; then
            echo "[$name] UP"
        else
            echo "[$name] DOWN"
        fi
    done
}

case "${1:-start}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    *)
        echo "Usage: $0 [start|stop|status]"
        exit 1
        ;;
esac
