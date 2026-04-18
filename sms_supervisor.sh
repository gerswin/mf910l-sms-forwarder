#!/bin/sh
# Supervisor: respawn sms_forward.sh if it dies
SCRIPT="/data/sms_forward.sh"
LOG="/data/sms_forward.log"

trap '' HUP
exec </dev/null >>"$LOG" 2>&1

while :; do
  echo "$(date '+%Y-%m-%d %H:%M:%S') supervisor: launching $SCRIPT"
  "$SCRIPT"
  echo "$(date '+%Y-%m-%d %H:%M:%S') supervisor: script exited, respawn in 10s"
  sleep 10
done
