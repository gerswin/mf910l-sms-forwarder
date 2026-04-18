#!/bin/sh
# MF910L SMS -> n8n forwarder (BusyBox 1.18.5 compatible)

# Load env file if present
ENV_FILE="${SMS_ENV_FILE:-/data/sms_forward.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

WEBHOOK_URL="${WEBHOOK_URL:?WEBHOOK_URL not set}"
PASS_B64="${PASS_B64:?PASS_B64 not set (base64 of router password)}"
CURL="${CURL:-/data/curl}"
SEEN="${SEEN:-/data/sms_forwarded_ids.txt}"
LOG="${LOG:-/data/sms_forward.log}"
INTERVAL="${INTERVAL:-30}"
API="${API:-http://127.0.0.1}"
# Rotation caps (lines). Prevent /data fill-up on long uptime.
SEEN_MAX="${SEEN_MAX:-1000}"
SEEN_KEEP="${SEEN_KEEP:-500}"
LOG_MAX="${LOG_MAX:-2000}"
LOG_KEEP="${LOG_KEEP:-1000}"
# Force session refresh every N iterations (defends against silent cookie expiry).
RELOGIN_EVERY="${RELOGIN_EVERY:-60}"
REF_HDR="Referer: $API/index.html"
XRW_HDR="X-Requested-With: XMLHttpRequest"

touch "$SEEN"

logmsg() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

rotate_file() {
  F="$1"; MAX="$2"; KEEP="$3"
  [ -f "$F" ] || return 0
  LINES=$(wc -l < "$F" 2>/dev/null)
  [ -n "$LINES" ] && [ "$LINES" -gt "$MAX" ] || return 0
  tail -n "$KEEP" "$F" > "$F.tmp" && mv "$F.tmp" "$F"
}

do_login() {
  "$CURL" -sS --max-time 10 \
    -X POST \
    -H "$REF_HDR" -H "$XRW_HDR" \
    --data "isTest=false&goformId=LOGIN&password=$PASS_B64" \
    "$API/goform/goform_set_cmd_process" >/dev/null 2>&1
}

fetch_sms() {
  TS=$(date +%s)
  "$CURL" -sS --max-time 10 \
    -H "$REF_HDR" -H "$XRW_HDR" \
    --data-urlencode "isTest=false" \
    --data-urlencode "cmd=sms_data_total" \
    --data-urlencode "page=0" \
    --data-urlencode "data_per_page=20" \
    --data-urlencode "mem_store=1" \
    --data-urlencode "tags=10" \
    --data-urlencode "order_by=order by id desc" \
    --data-urlencode "_=$TS" \
    -G "$API/goform/goform_get_cmd_process"
}

decode_hex() {
  printf '%s' "$1" | awk '
    function hex2dec(h,   i,c,v,n) {
      n = 0
      for (i = 1; i <= length(h); i++) {
        c = substr(h, i, 1)
        if      (c == "0") v = 0
        else if (c == "1") v = 1
        else if (c == "2") v = 2
        else if (c == "3") v = 3
        else if (c == "4") v = 4
        else if (c == "5") v = 5
        else if (c == "6") v = 6
        else if (c == "7") v = 7
        else if (c == "8") v = 8
        else if (c == "9") v = 9
        else if (c == "a" || c == "A") v = 10
        else if (c == "b" || c == "B") v = 11
        else if (c == "c" || c == "C") v = 12
        else if (c == "d" || c == "D") v = 13
        else if (c == "e" || c == "E") v = 14
        else if (c == "f" || c == "F") v = 15
        else v = 0
        n = n * 16 + v
      }
      return n
    }
    function utf8(cp,   b1,b2,b3) {
      if (cp < 128) return sprintf("%c", cp)
      if (cp < 2048) {
        b1 = 192 + int(cp/64); b2 = 128 + (cp%64)
        return sprintf("%c%c", b1, b2)
      }
      b1 = 224 + int(cp/4096)
      b2 = 128 + int((cp/64)%64)
      b3 = 128 + (cp%64)
      return sprintf("%c%c%c", b1, b2, b3)
    }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i += 4) {
        cp = hex2dec(substr($0, i, 4))
        out = out utf8(cp)
      }
      printf "%s", out
    }'
}

json_escape() {
  awk 'BEGIN{ORS=""} {
    gsub(/\\/, "\\\\")
    gsub(/"/,  "\\\"")
    gsub(/\r/, "\\r")
    gsub(/\t/, "\\t")
    if (NR > 1) printf "\\n"
    printf "%s", $0
  }'
}

# POST JSON to HTTPS webhook via static curl (timeout wrapped)
post_webhook() {
  BODY="$1"
  CODE=$(timeout -t 30 "$CURL" -sS -k -4 -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Content-Type: application/json" \
    -H "User-Agent: MF910L-SMS-Forwarder" \
    --data-binary "$BODY" \
    --connect-timeout 10 --max-time 20 \
    "$WEBHOOK_URL" 2>/dev/null)
  case "$CODE" in
    2*) return 0 ;;
    *)  return 1 ;;
  esac
}

forward_one() {
  ID="$1"; NUM="$2"; HEX="$3"; DT="$4"
  grep -q "^${ID}$" "$SEEN" && return 0
  TEXT=$(decode_hex "$HEX")
  ESC=$(printf '%s' "$TEXT" | json_escape)
  JSON='{"id":"'"$ID"'","number":"'"$NUM"'","date":"'"$DT"'","content":"'"$ESC"'"}'
  if post_webhook "$JSON"; then
    echo "$ID" >> "$SEEN"
    logmsg "forwarded id=$ID num=$NUM"
  else
    logmsg "post failed id=$ID num=$NUM"
  fi
}

parse_and_forward() {
  RAW="$1"
  printf '%s' "$RAW" | awk '{ gsub(/\},[[:space:]]*\{/, "}\n{"); print }' | \
  while IFS= read -r line; do
    case "$line" in
      *'"id"'*'"number"'*'"content"'*)
        ID=$(printf '%s' "$line"  | awk 'match($0,/"id":"[0-9]+"/){print substr($0,RSTART+6,RLENGTH-7)}')
        NUM=$(printf '%s' "$line" | awk 'match($0,/"number":"[^"]*"/){print substr($0,RSTART+10,RLENGTH-11)}')
        HEX=$(printf '%s' "$line" | awk 'match($0,/"content":"[0-9A-Fa-f]*"/){print substr($0,RSTART+11,RLENGTH-12)}')
        DT=$(printf '%s' "$line"  | awk 'match($0,/"date":"[^"]*"/){print substr($0,RSTART+8,RLENGTH-9)}')
        [ -n "$ID" ] && [ -n "$HEX" ] && forward_one "$ID" "$NUM" "$HEX" "$DT"
        ;;
    esac
  done
}

logmsg "starting forwarder pid=$$"
do_login

LOOP=0
while :; do
  LOOP=$((LOOP + 1))
  if [ "$RELOGIN_EVERY" -gt 0 ] && [ $((LOOP % RELOGIN_EVERY)) -eq 0 ]; then
    do_login
    logmsg "periodic relogin loop=$LOOP"
  fi
  RAW=$(fetch_sms)
  case "$RAW" in
    *'"messages"'*'"id"'*) parse_and_forward "$RAW" ;;
    *'"messages"'*) : ;;
    *) logmsg "bad response, relogin"; do_login ;;
  esac
  if [ $((LOOP % 20)) -eq 0 ]; then
    rotate_file "$SEEN" "$SEEN_MAX" "$SEEN_KEEP"
    rotate_file "$LOG"  "$LOG_MAX"  "$LOG_KEEP"
  fi
  sleep "$INTERVAL"
done
