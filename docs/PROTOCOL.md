# Device ⇄ bridge protocol

Newline-delimited JSON, one object per line, `"t"` is the type. Identical over USB serial, the Wi-Fi WebSocket and the Bluetooth Nordic UART link.
Device log lines start with `# ` and are ignored by the bridge. Frames are ≤ 6 KB (bridge chunks long text).

## Device → bridge
| t | fields | notes |
|---|---|---|
| `hello` | id, fw, name, caps[], model, chat | sent every 3 s until acked; `chat` = chat to resume |
| `chat.send` | text, chat, model | start / continue a chat |
| `chat.stop` | | cancel generation |
| `chat.new` / `chat.open` / `chat.delete` / `chat.list` | chat | |
| `model.list` / `model.set` | model | |
| `action.list` / `action.run` | id, chat, model | actions come from `config.toml` |
| `hid.type` | text | type into the frontmost Mac app |
| `hid.key` | combo | `"cmd+v"`, `"enter"`, `"f5"`, `"rcmd"` |
| `dictation` | op: start / stop / toggle | |
| `hid.paste_last` / `clip.set_last` | | type / copy the last reply |
| `media` | key: vol_up / vol_down / mute / play_pause | |
| `pair.confirm` / `pair.reject` | code | Wi-Fi TOFU pairing answer |
| `prov.ok` | what | acknowledges provisioning |
| `ping` / `pong` | | liveness (device pings every 5 s; link dropped after 15–20 s silence) |
| `cc.list` / `cc.open` | id | Claude Code sessions (`claude -r` archive) |
| `alert.reply` | id, action: allow / deny / dismiss | answer a permission / notice card |
| `audio.start` / `audio.chunk` / `audio.stop` / `audio.cancel` | rate, codec, target; seq, d (base64 ADPCM) | device-mic dictation |
| `settings.ack` | key, ok | reply to `settings.set` |

## Bridge → device
| t | fields |
|---|---|
| `hello.ack` | bridge, version, models[{id,label,provider,ok}], chats[{id,title}], actions[{id,label}], model, chat, title |
| `chat.delta` | d (text piece, ≤160 chars) |
| `chat.done` | chat, title |
| `chat.error` | msg |
| `chat.view` | chat, title, text (trimmed transcript), last (last reply) |
| `chat.list` / `model.list` / `action.list` | lists |
| `status` | dictating, app (frontmost app name) |
| `ui.toast` | msg |
| `prov.wifi` | ssid, pass — USB only |
| `prov.bridge` | host, port, token, name, ca (PEM) — USB only |
| `pair.offer` | ca, fp, code, token, name — Wi-Fi pairing only |
| `cc.list` | sessions[{id,title,project,age}] |
| `alert` / `alert.clear` | id, kind: permission / notify / done, title, text, project, session, actions[] |
| `dictation.text` | text, target, note |
| `settings.set` | key, value (from `aitl set`) |
| `reboot` / `ping` / `pong` | |

Adding a message: handle it in `firmware/src/core/app.cpp::onMessage` and `bridge/aitl_bridge/session.py::handle`.

## Networks, Bluetooth bonds, diagnostics (added 2026-10-24)
Device → bridge: `hello` now also carries `up` (seconds), `reset` (reason string), `diag` (newest-first ring of
`{reason, up, minheap}`) and `bat` (%) when the gauge is enabled. `wifi.networks {list:[{ssid,prio,current}], current,
enabled}` answers any `wifi.*` request; `wifi.scan {list:[{ssid,rssi}]}` answers a scan; `ble.bonds {count}` answers
`ble.forget`.

Bridge → device: `hello.req` (answer with `hello` right away; sent on every serial open), `wifi.add {ssid,pass,prio}`
(USB only), `wifi.remove {ssid}`, `wifi.use {ssid}` (switch now), `wifi.list`, `wifi.scan`, `ble.forget`.
`prov.wifi` now upserts into the table instead of replacing the single network. New `settings.set` keys: `micSck`,
`micWs`, `micSd`, `encA`, `encB`, `encSw`, `togglePin`, `toggleRole`, `batteryEnabled`, `batteryDivider`, `chime`,
`glance`, `cpuMhz`.

The device keeps up to 8 networks in LittleFS `/wifi.json`. On connect it scans when more than one is saved and joins
the strongest visible one (RSSI + 20·prio); a `wifi.use` forces one network for the next connect. Retries back off from
20 s to 2 min while no saved network is in range.
