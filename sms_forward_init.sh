#!/bin/sh
### BEGIN INIT INFO
# Provides:          sms_forward
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: SMS forwarder to n8n
### END INIT INFO

SCRIPT="/data/sms_forward.sh"
SUPERVISOR="/data/sms_supervisor.sh"
PIDFILE="/var/run/sms_forward.pid"
LOG="/data/sms_forward.log"

kill_all() {
  if [ -f "$PIDFILE" ]; then
    PID=$(head -n1 "$PIDFILE")
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
  fi
  pkill -f "$SUPERVISOR" 2>/dev/null
  pkill -f "$SCRIPT" 2>/dev/null
  sleep 1
  pkill -9 -f "$SUPERVISOR" 2>/dev/null
  pkill -9 -f "$SCRIPT" 2>/dev/null
  rm -f "$PIDFILE"
}

case "$1" in
  start)
    # Kernel 3.0 sin getrandom: OpenSSL bloquea en /dev/random.
    # Forzar urandom como fuente RNG.
    if [ ! -L /dev/random ]; then
      rm -f /dev/random && ln -s /dev/urandom /dev/random
    fi
    # Evita duplicados si quedó algo corriendo
    kill_all
    setsid sh -c 'nohup "$0" >/dev/null 2>&1 &' "$SUPERVISOR"
    sleep 1
    PID=$(pgrep -f "$SUPERVISOR" | head -n1)
    if [ -n "$PID" ]; then
      echo "$PID" > "$PIDFILE"
      echo "started pid=$PID"
    else
      echo "start failed"
      exit 1
    fi
    ;;
  stop)
    kill_all
    echo "stopped"
    ;;
  restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;
  status)
    PID=$([ -f "$PIDFILE" ] && head -n1 "$PIDFILE")
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
      WORKER=$(pgrep -f "$SCRIPT" | head -n1)
      echo "running supervisor=$PID worker=${WORKER:-none}"
    else
      echo "not running"
      exit 3
    fi
    ;;
  *)
    echo "usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
