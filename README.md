# MF910L SMS Forwarder

Forwards incoming SMS from a ZTE MF910L router to an HTTP(S) webhook (e.g. n8n).
Runs on-device under BusyBox 1.18.5.

## Historia

Llevo años con la misma idea rondando: convertir un módem 4G viejo en un
reenviador de SMS.

Lo intenté primero con teléfonos Android. SMS Gateway, SMS Sync, y un par de
apps propias que escribí yo mismo. Todas funcionan los primeros días. Después
el sistema decide que tu app consume mucha batería, la mete en "optimización",
y a las 6 horas ya no reenvía nada. Vuelves a abrirla, das permisos otra vez,
la "fijas" en memoria, ignoras las advertencias del fabricante. Dura otros
días. Se repite.

Android nunca fue hecho para correr un daemon 24/7. Pelear contra el power
saving es pelear contra el propio OS.

Así que agarré un router ZTE MF910L que tenía en un cajón, lo rooteé, y le
metí 4 scripts de shell corriendo directo sobre BusyBox. Sin Android, sin
Doze, sin battery optimizer decidiendo por mí cuándo "ahorrar recursos". El
módem arranca, el init ejecuta el forwarder, y se queda ahí hasta que lo
desenchufe.

La motivación concreta: una prueba de concepto que valida pagos móviles en
tiempo real. El banco manda SMS cuando entra plata, el webhook lo parsea,
cruza contra la orden pendiente, y confirma. Sin integración bancaria, sin
Open Banking, sin esperar pantallazo del cliente por WhatsApp.

Honestidad: al momento de publicar esto lleva 3 días corriendo. Es poco
tiempo para decir "esto funciona". Pero ya sobrevivió un reboot del router
y un corte de energía, cosa que mis apps Android nunca lograron aguantar
limpio. Señal buena por ahora. Cuando tenga 30 días de uptime real actualizo
este README con el veredicto.

## Files

- `sms_forward.sh` — polls router web API, decodes UCS-2 hex, POSTs JSON.
- `sms_supervisor.sh` — respawns forwarder on exit.
- `sms_forward_init.sh` — SysV init script (start/stop/restart/status).
- `adb_persist.sh` — forces ADB USB composition at boot.
- `.env.example` — config template.

## Requirements

**Device must be rooted with ADB enabled.** Stock MF910L firmware blocks shell
access. Writes to `/data` and `/etc/init.d` and a working `adb shell` as root
are required.

### Rooting / enabling ADB on MF910L

Stock firmware exposes a diagnostic USB composition that can be flipped to
include `adb`. One-time procedure from a host PC (device connected via USB):

```sh
# 1. Enable engineer/diag mode via hidden web endpoint
#    (router must be on 192.168.0.1, admin session logged in)
PASS_B64=$(printf 'Admin' | base64)   # your router password, base64
curl -s -c cookies.txt \
  -H "Referer: http://192.168.0.1/index.html" \
  -H "X-Requested-With: XMLHttpRequest" \
  --data "isTest=false&goformId=LOGIN&password=$PASS_B64" \
  http://192.168.0.1/goform/goform_set_cmd_process

# 2. Switch USB composition to include ADB (usb_mode=6)
curl -s -b cookies.txt \
  -H "Referer: http://192.168.0.1/index.html" \
  -H "X-Requested-With: XMLHttpRequest" \
  --data "isTest=false&goformId=USB_MODE_SWITCH&usb_mode=6" \
  http://192.168.0.1/goform/goform_set_cmd_process

# 3. Re-plug USB. Host should now see adb device:
adb devices          # expect: <serial>  device
adb shell id         # expect: uid=0(root)
```

If step 2 does not expose ADB, the firmware variant may require flashing a
debug build or using a DIAG-port AT-command path (`AT+ZCDRUN=F`) to unlock
shell. Rooting is device/firmware specific — verify `adb shell id` returns
`uid=0` before proceeding.

Once rooted, install `adb_persist.sh` (below) so the ADB composition survives
reboots.

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
