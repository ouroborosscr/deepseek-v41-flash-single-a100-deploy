#!/usr/bin/env bash

set -euo pipefail

# Shared controller for the A100 deployment.  The parent directory is group-owned
# by sharedgroup on the reference server, so members of that group can start and
# stop the service without sudo or access to another user's private tmux socket.
BASE=${DSV41_BASE:-/date/sunchengrui/deepseek-v41-flash}
SERVER_SCRIPT=${DSV41_SERVER_SCRIPT:-$BASE/dsv41_server.sh}
SOCKET=${DSV41_TMUX_SOCKET:-$BASE/dsv41.tmux}
SESSION=${DSV41_TMUX_SESSION:-dsv41-server}
PORT=${DSV41_PORT:-7888}
CONTEXT=${DSV41_CONTEXT:-786432}
GPU=${DSV41_GPU:-2}
HOST=${DSV41_HOST:-0.0.0.0}
LOCKFILE=${DSV41_LOCKFILE:-$BASE/dsv41ctl.lock}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

[[ -x "$SERVER_SCRIPT" ]] || die "server script not executable: $SERVER_SCRIPT"
mkdir -p "$BASE"

require_group_access() {
  [[ -r "$BASE" && -x "$BASE" ]] || die "no access to deployment directory: $BASE"
}

tmux_cmd() {
  # Do not let the long-lived tmux server inherit the controller's flock fd;
  # otherwise the lock would remain held after this command exits.
  tmux -S "$SOCKET" "$@" 9>&-
}

socket_permissions() {
  # tmux normally creates a private socket.  Make the control socket usable by
  # the deployment group, but never world-writable.
  chmod 660 "$SOCKET" 2>/dev/null || true
}

session_exists() {
  tmux_cmd has-session -t "$SESSION" 2>/dev/null
}

server_pid() {
  pgrep -f -- "$BASE/llama\.cpp/.*/bin/llama-server .*--port[[:space:]]+$PORT" | head -1 || true
}

health_ok() {
  curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1
}

stop_unlocked() {
  if session_exists; then
    log "stopping tmux session $SESSION"
    tmux_cmd kill-session -t "$SESSION"
  fi

  # This catches a process that outlived tmux.  Match the deployment binary and
  # port only; do not kill unrelated llama-server instances.
  local pid
  pid=$(server_pid)
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$BASE/logs/server-${PORT}.status"
  log "GPU service stopped; port $PORT is free"
}

start_unlocked() {
  if health_ok; then
    if pgrep -af -- "--ctx-size[[:space:]]+$CONTEXT" | grep -q -- "--port[[:space:]]+$PORT"; then
      log "already running: port=$PORT context=$CONTEXT"
      return 0
    fi
    log "restarting existing service to apply context=$CONTEXT"
    stop_unlocked
  elif session_exists; then
    # A 786K cold load takes about a minute.  Do not mistake that expected
    # 503/loading window for a dead session when another user runs `start`.
    local existing_pid
    existing_pid=$(server_pid)
    if [[ -n "$existing_pid" ]]; then
      log "service is already starting; waiting for health"
      for _ in $(seq 1 180); do
        if health_ok; then
          log "ready: http://127.0.0.1:${PORT}/health"
          return 0
        fi
        kill -0 "$existing_pid" 2>/dev/null || break
        sleep 2
      done
      if health_ok; then
        log "ready: http://127.0.0.1:${PORT}/health"
        return 0
      fi
      log "existing server exited or failed health; removing stale session"
    else
      log "removing stale tmux session $SESSION"
    fi
    tmux_cmd kill-session -t "$SESSION"
  fi

  rm -f "$BASE/logs/server-${PORT}.status"
  umask 0007
  tmux_cmd new-session -d -s "$SESSION" \
    "export DSV41_GPU='$GPU' DSV41_HOST='$HOST' DSV41_PORT='$PORT' DSV41_CONTEXT='$CONTEXT'; exec '$SERVER_SCRIPT'"
  socket_permissions

  log "starting DeepSeek-V4.1-Flash: gpu=$GPU host=$HOST port=$PORT context=$CONTEXT"
  for _ in $(seq 1 180); do
    if health_ok; then
      socket_permissions
      log "ready: http://127.0.0.1:${PORT}/health"
      return 0
    fi
    if [[ -f "$BASE/logs/server-${PORT}.status" ]]; then
      tail -30 "$BASE/logs/server-${PORT}.log" >&2 || true
      die "server exited during startup"
    fi
    sleep 2
  done
  tail -30 "$BASE/logs/server-${PORT}.log" >&2 || true
  die "timed out waiting for health"
}

status_unlocked() {
  printf 'base=%s\nsession=%s\nport=%s\ncontext=%s\ngpu=%s\n' \
    "$BASE" "$SESSION" "$PORT" "$CONTEXT" "$GPU"
  if health_ok; then
    echo 'state=running'
  else
    echo 'state=stopped-or-starting'
  fi
  if session_exists; then
    tmux_cmd list-panes -t "$SESSION" -F 'tmux_pane=#{pane_pid} command=#{pane_current_command}'
  fi
}

require_group_access
command=${1:-status}
shift || true
[[ $# -eq 0 ]] || die "usage: $0 {start|stop|restart|status}"

exec 9>"$LOCKFILE"
flock -w 30 9 || die "another dsv41ctl operation is in progress"

case "$command" in
  start) start_unlocked ;;
  stop) stop_unlocked ;;
  restart) stop_unlocked; start_unlocked ;;
  status) status_unlocked ;;
  *) die "unknown command: $command (use start, stop, restart, or status)" ;;
esac
