# MF910L SMS Forwarder

Forwards incoming SMS from a ZTE MF910L router to an HTTP(S) webhook (e.g. n8n).
Runs on-device under BusyBox 1.18.5.

## Files

- `sms_forward.sh` — polls router web API, decodes UCS-2 hex, POSTs JSON.
- `sms_supervisor.sh` — respawns forwarder on exit.
- `sms_forward_init.sh` — SysV init script (start/stop/restart/status).
- `adb_persist.sh` — forces ADB USB composition at boot.
- `.env.example` — config template.

## Install

On router (`/data` persists across reboots):

```sh
# 1. Copy scripts + static curl binary
adb push sms_forward.sh sms_supervisor.sh adb_persist.sh /data/
adb push sms_forward_init.sh /etc/init.d/sms_forward
adb push curl /data/curl
adb shell chmod +x /data/*.sh /data/curl /etc/init.d/sms_forward

# 2. Create env file
cp .env.example sms_forward.env
# edit WEBHOOK_URL + PASS_B64
adb push sms_forward.env /data/sms_forward.env
adb shell chmod 600 /data/sms_forward.env

# 3. Enable + start
adb shell update-rc.d sms_forward defaults
adb shell /etc/init.d/sms_forward start
```

## Config

All config via env file at `/data/sms_forward.env` (override path with `SMS_ENV_FILE`).
Required: `WEBHOOK_URL`, `PASS_B64`. See `.env.example`.

## Webhook payload

```json
{"id":"12","number":"+34600000000","date":"25,04,18,10,30,00,+08","content":"hello"}
```

## Ops

```sh
/etc/init.d/sms_forward status
tail -f /data/sms_forward.log
```
