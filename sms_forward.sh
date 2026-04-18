#!/bin/sh
# MF910L SMS -> webhook forwarder (BusyBox 1.18.5 compatible)

# ----- Config -----
ENV_FILE="${SMS_ENV_FILE:-/data/sms_forward.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

WEBHOOK_URL="${WEBHOOK_URL:?WEBHOOK_URL not set}"
PASS_B64="${PASS_B64:?PASS_B64 not set (base64 of router password)}"
CURL="${CURL:-/data/curl}"
SEEN="${SEEN:-/data/sms_forwarded_ids.txt}"
RETRY_FILE="${RETRY_FILE:-/data/sms_retry.txt}"
STATS_FILE="${STATS_FILE:-/data/sms_stats.txt}"
LOG="${LOG:-/data/sms_forward.log}"
INTERVAL="${INTERVAL:-30}"
API="${API:-http://127.0.0.1}"

# Rotation caps (lines)
SEEN_MAX="${SEEN_MAX:-1000}"
SEEN_KEEP="${SEEN_KEEP:-500}"
LOG_MAX="${LOG_MAX:-2000}"
LOG_KEEP="${LOG_KEEP:-1000}"

# Periodic session refresh (iterations; 0 = off)
RELOGIN_EVERY="${RELOGIN_EVERY:-60}"

# SMS stores to poll. "1"=SIM, "0"=module memory. Space-separated.
STORES="${MEM_STORES:-1 0}"

# Delete SMS from router after successful forward (1/0)
DELETE_AFTER_FORWARD="${DELETE_AFTER_FORWARD:-1}"

# Max POST retries per message before giving up (marks seen + logs)
MAX_RETRIES="${MAX_RETRIES:-5}"

# HMAC-SHA256 secret. If set and openssl available, adds X-Signature header.
HMAC_SECRET="${HMAC_SECRET:-}"

REF_HDR="Referer: $API/index.html"
XRW_HDR="X-Requested-With: XMLHttpRequest"

touch "$SEEN" "$RETRY_FILE"

# ----- Logging -----
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

# ----- Counters (file-based; shell subshells drop in-memory vars) -----
inc_counter() {
  F="${STATS_FILE}.$1"
  N=$(cat "$F" 2>/dev/null)
  N=${N:-0}
  echo $((N + 1)) > "$F"
}

get_counter() {
  cat "${STATS_FILE}.$1" 2>/dev/null || echo 0
}

write_stats() {
  {
    echo "forwarded=$(get_counter forwarded)"
    echo "failed=$(get_counter failed)"
    echo "deleted=$(get_counter deleted)"
    echo "gaveup=$(get_counter gaveup)"
    echo "relogin=$(get_counter relogin)"
    echo "uptime_loops=$LOOP"
    echo "last_update=$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$STATS_FILE"
}

# ----- Retry tracking -----
retry_count() {
  awk -F: -v id="$1" '$1==id{print $2; exit}' "$RETRY_FILE"
}

retry_inc() {
  ID="$1"
  CUR=$(retry_count "$ID")
  CUR=${CUR:-0}
  NEW=$((CUR + 1))
  awk -F: -v id="$ID" '$1!=id' "$RETRY_FILE" > "$RETRY_FILE.tmp"
  echo "$ID:$NEW" >> "$RETRY_FILE.tmp"
  mv "$RETRY_FILE.tmp" "$RETRY_FILE"
  echo "$NEW"
}

retry_clear() {
  awk -F: -v id="$1" '$1!=id' "$RETRY_FILE" > "$RETRY_FILE.tmp"
  mv "$RETRY_FILE.tmp" "$RETRY_FILE"
}

# ----- Router API -----
do_login() {
  "$CURL" -sS --max-time 10 \
    -X POST \
    -H "$REF_HDR" -H "$XRW_HDR" \
    --data "isTest=false&goformId=LOGIN&password=$PASS_B64" \
    "$API/goform/goform_set_cmd_process" >/dev/null 2>&1
}

fetch_sms() {
  STORE="$1"
  TS=$(date +%s)
  "$CURL" -sS --max-time 10 \
    -H "$REF_HDR" -H "$XRW_HDR" \
    --data-urlencode "isTest=false" \
    --data-urlencode "cmd=sms_data_total" \
    --data-urlencode "page=0" \
    --data-urlencode "data_per_page=20" \
    --data-urlencode "mem_store=$STORE" \
    --data-urlencode "tags=10" \
    --data-urlencode "order_by=order by id desc" \
    --data-urlencode "_=$TS" \
    -G "$API/goform/goform_get_cmd_process"
}

delete_sms() {
  STORE="$1"; ID="$2"
  "$CURL" -sS --max-time 10 \
    -X POST \
    -H "$REF_HDR" -H "$XRW_HDR" \
    --data "isTest=false&goformId=DELETE_SMS&msg_id=${ID};&notCallback=true&mem_store=${STORE}" \
    "$API/goform/goform_set_cmd_process" >/dev/null 2>&1
}

# ----- Encoding helpers -----
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
    function utf8(cp,   b1,b2,b3,b4) {
      if (cp < 128) return sprintf("%c", cp)
      if (cp < 2048) {
        b1 = 192 + int(cp/64); b2 = 128 + (cp%64)
        return sprintf("%c%c", b1, b2)
      }
      if (cp < 65536) {
        b1 = 224 + int(cp/4096)
        b2 = 128 + int((cp/64)%64)
        b3 = 128 + (cp%64)
        return sprintf("%c%c%c", b1, b2, b3)
      }
      b1 = 240 + int(cp/262144)
      b2 = 128 + int((cp/4096)%64)
      b3 = 128 + int((cp/64)%64)
      b4 = 128 + (cp%64)
      return sprintf("%c%c%c%c", b1, b2, b3, b4)
    }
    {
      out = ""
      n = length($0)
      i = 1
      while (i <= n) {
        cp = hex2dec(substr($0, i, 4))
        i += 4
        if (cp >= 55296 && cp <= 56319 && i + 3 <= n) {
          low = hex2dec(substr($0, i, 4))
          if (low >= 56320 && low <= 57343) {
            cp = 65536 + (cp - 55296) * 1024 + (low - 56320)
            i += 4
          }
        }
        out = out utf8(cp)
      }
      printf "%s", out
    }'
}

json_escape() {
  awk 'BEGIN{ORS=""} {
    gsub(/\\/, "\\\\")
    gsub(/"/,  "\\\"")
    gsub(/\010/, "\\b")
    gsub(/\t/,   "\\t")
    gsub(/\r/,   "\\r")
    gsub(/\014/, "\\f")
    gsub(/[\001-\007\013\016-\037]/, "")
    if (NR > 1) printf "\\n"
    printf "%s", $0
  }'
}

# ZTE "YY,MM,DD,HH,MM,SS,+TZ" -> ISO 8601 "YYYY-MM-DDTHH:MM:SS+HH:MM"
iso_date() {
  printf '%s' "$1" | awk -F, '{
    if (NF < 7) { print ""; exit }
    yy = $1
    if (yy + 0 < 70) yy = "20" yy; else yy = "19" yy
    tz = $7
    sign = substr(tz, 1, 1)
    num = substr(tz, 2)
    L = length(num)
    if (L == 2)      tz = sign num ":00"
    else if (L == 3) tz = sign "0" substr(num,1,1) ":" substr(num,2,2)
    else if (L == 4) tz = sign substr(num,1,2) ":" substr(num,3,2)
    printf "%s-%s-%sT%s:%s:%s%s", yy, $2, $3, $4, $5, $6, tz
  }'
}

# ----- Webhook -----
post_webhook() {
  BODY="$1"
  SIG=""
  if [ -n "$HMAC_SECRET" ]; then
    SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$HMAC_SECRET" 2>/dev/null | awk '{print $NF}')
  fi
  if [ -n "$SIG" ]; then
    CODE=$(timeout -t 30 "$CURL" -sS -k -4 -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -H "User-Agent: MF910L-SMS-Forwarder" \
      -H "X-Signature: sha256=$SIG" \
      --data-binary "$BODY" \
      --connect-timeout 10 --max-time 20 \
      "$WEBHOOK_URL" 2>/dev/null)
  else
    CODE=$(timeout -t 30 "$CURL" -sS -k -4 -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -H "User-Agent: MF910L-SMS-Forwarder" \
      --data-binary "$BODY" \
      --connect-timeout 10 --max-time 20 \
      "$WEBHOOK_URL" 2>/dev/null)
  fi
  case "$CODE" in
    2*) return 0 ;;
    *)  return 1 ;;
  esac
}

# ----- Core -----
forward_one() {
  STORE="$1"; ID="$2"; NUM="$3"; HEX="$4"; DT="$5"
  KEY="${STORE}:${ID}"
  grep -q "^${KEY}$" "$SEEN" && return 0
  TEXT=$(decode_hex "$HEX")
  ESC=$(printf '%s' "$TEXT" | json_escape)
  ISO=$(iso_date "$DT")
  JSON='{"id":"'"$ID"'","store":"'"$STORE"'","number":"'"$NUM"'","date":"'"$DT"'","iso_date":"'"$ISO"'","content":"'"$ESC"'"}'
  if post_webhook "$JSON"; then
    echo "$KEY" >> "$SEEN"
    inc_counter forwarded
    retry_clear "$KEY"
    logmsg "forwarded store=$STORE id=$ID num=$NUM"
    if [ "$DELETE_AFTER_FORWARD" = "1" ]; then
      if delete_sms "$STORE" "$ID"; then
        inc_counter deleted
      else
        logmsg "delete failed store=$STORE id=$ID"
      fi
    fi
  else
    inc_counter failed
    NEW=$(retry_inc "$KEY")
    logmsg "post failed store=$STORE id=$ID num=$NUM attempt=$NEW"
    if [ "$NEW" -ge "$MAX_RETRIES" ]; then
      echo "$KEY" >> "$SEEN"
      retry_clear "$KEY"
      inc_counter gaveup
      logmsg "gave up store=$STORE id=$ID after $NEW attempts"
    fi
  fi
}

parse_and_forward() {
  RAW="$1"; STORE="$2"
  printf '%s' "$RAW" | awk '{ gsub(/\},[[:space:]]*\{/, "}\n{"); print }' | \
  while IFS= read -r line; do
    case "$line" in
      *'"id"'*'"number"'*'"content"'*)
        ID=$(printf '%s' "$line"  | awk 'match($0,/"id":"[0-9]+"/){print substr($0,RSTART+6,RLENGTH-7)}')
        NUM=$(printf '%s' "$line" | awk 'match($0,/"number":"[^"]*"/){print substr($0,RSTART+10,RLENGTH-11)}')
        HEX=$(printf '%s' "$line" | awk 'match($0,/"content":"[0-9A-Fa-f]*"/){print substr($0,RSTART+11,RLENGTH-12)}')
        DT=$(printf '%s' "$line"  | awk 'match($0,/"date":"[^"]*"/){print substr($0,RSTART+8,RLENGTH-9)}')
        [ -n "$ID" ] && [ -n "$HEX" ] && forward_one "$STORE" "$ID" "$NUM" "$HEX" "$DT"
        ;;
    esac
  done
}

# Old SEEN format was bare IDs; new format is STORE:ID.
migrate_seen() {
  [ -s "$SEEN" ] || return 0
  FIRST=$(head -n 1 "$SEEN" 2>/dev/null)
  case "$FIRST" in
    *:*) return 0 ;;
  esac
  awk '{print "1:" $0}' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
  logmsg "migrated SEEN to STORE:ID format"
}

# ----- Init -----
logmsg "starting forwarder pid=$$"
migrate_seen

if [ -n "$HMAC_SECRET" ]; then
  if command -v openssl >/dev/null 2>&1; then
    logmsg "HMAC signing enabled"
  else
    logmsg "WARN: HMAC_SECRET set but openssl not found, signatures disabled"
    HMAC_SECRET=""
  fi
fi

do_login

# ----- Main loop -----
LOOP=0
while :; do
  LOOP=$((LOOP + 1))
  if [ "$RELOGIN_EVERY" -gt 0 ] && [ $((LOOP % RELOGIN_EVERY)) -eq 0 ]; then
    do_login
    inc_counter relogin
    logmsg "periodic relogin loop=$LOOP"
  fi
  for STORE in $STORES; do
    RAW=$(fetch_sms "$STORE")
    case "$RAW" in
      *'"messages"'*'"id"'*) parse_and_forward "$RAW" "$STORE" ;;
      *'"messages"'*) : ;;
      *) logmsg "bad response store=$STORE, relogin"; do_login; inc_counter relogin ;;
    esac
  done
  if [ $((LOOP % 20)) -eq 0 ]; then
    rotate_file "$SEEN" "$SEEN_MAX" "$SEEN_KEEP"
    rotate_file "$LOG"  "$LOG_MAX"  "$LOG_KEEP"
    write_stats
  fi
  sleep "$INTERVAL"
done
