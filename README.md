# AITL — AI In The Loop
### Caeruli Obscuri Laboratorium · *Ex aperto, claritas.*

A hardware AI companion you actually own. A 2.8" capacitive ESP32 "CYD" becomes a desk-side console that talks to
**Claude, Gemini, Gemma / Llama / Qwen (Ollama, local), OpenAI, OpenRouter and any OpenAI-compatible endpoint
(Meta Muse Spark once an endpoint exists)**, switches models and chats in two taps, dictates into your Mac, types
replies straight into whatever app is in front, and runs one-tap prompts on your clipboard — with **no key, no cloud
relay and no third-party firmware** anywhere in the loop.

```
┌──────────────┐  USB-C (serial)   ┌──────────────────┐   HTTPS   ┌───────────────┐
│  AITL device │ ─────────────────▶│  aitl bridge     │ ────────▶ │ Anthropic     │
│  (ESP32 CYD) │  Wi-Fi (TLS, pinned│  (your Mac)      │           │ Google Gemini │
│              │   cert + token)    │  keys in Keychain│ ────────▶ │ Ollama (local)│
│   LVGL UI    │ ◀───────────────── │  types/dictates  │           │ OpenAI-compat │
└──────────────┘  BLE HID keyboard  └──────────────────┘           └───────────────┘
        └──────────────────────────────▶ any computer/phone as a Bluetooth keyboard
```

## What it does (today)

| Feature | How |
|---|---|
| Chat with any configured model, streamed to the screen | `TYPE` → on-device keyboard → **AI ▸**; replies stream token by token |
| Swap models | tap the model chip; grouped by provider, dimmed if no key. `Claude Code (subscription)` needs no key at all |
| Multiple chats | tap the chat chip; open, long-press to delete, long-press chip for a new chat; chats persist on the Mac |
| Dictate into the Mac | `DICTATE` or the physical **BOOT** button toggles macOS dictation in the frontmost app |
| Type into the Mac | `TYPE` → **MAC ▸**, or the paste button after any reply, or the "→ type" actions |
| Ask by voice | Actions → *Ask by voice*: a native dialog opens on the Mac, dictation starts, the answer streams to the device |
| Clipboard actions | Summarize / explain / fix grammar / draft reply / translate / extract to-dos — editable in `config.toml` |
| Mac controls | volume, mute, play/pause, Cmd-Tab, Cmd-Space, Esc, Enter |
| Four transports | USB serial (zero setup), Wi-Fi (signed frames by default, TLS pinned-cert mode for boards with PSRAM), Bluetooth link (Nordic UART, whole protocol), Bluetooth HID keyboard (pairs with anything) |
| Dictation, two ways | **Host Mac**: the device triggers macOS dictation into the frontmost app. **Device mic**: an I²S mic on the P3 header streams compressed audio to the bridge, which transcribes it (local Whisper or Gemini) and either asks the AI or types the text |
| Claude Code control | your `claude -r` sessions listed on the device, tap to resume; permission prompts pushed to the screen with Allow/Deny; needs-input and finished-turn notices |
| Claude on subscription | `claude-code/*` models run through the Claude Agent SDK on your Claude Code login: no API key, no per-token bill |
| Full settings | connection, Wi-Fi credentials, bridge pairing, BLE, brightness, timeout, rotation, color inversion, R/B swap, touch calibration, long-press, touch sensitivity, tap LED, microSD logging, factory reset |
| First-boot wizard | orientation → color check → 3-point touch calibration with live verification |
| microSD | optional: finished exchanges are appended to `/aitl/chats/<id>.txt` |
| Status LED | caerulei breathing idle · amber listening · blue pulse thinking · green done · red error |

## Quick start (5 minutes)

```bash
# 1. Flash the device (already done for the unit on your desk)
tools/flash.sh                      # builds firmware/ and uploads over USB

# 2. Bridge on the Mac
cd bridge && python3 -m venv .venv && . .venv/bin/activate && pip install -e ".[discovery]"
# Claude works out of the box through your Claude Code login (no API key, billed to your subscription).
aitl keys set gemini                # optional: Gemini (GEMINI_API_KEY env var also works)
aitl keys set anthropic             # optional: Claude via the API instead of the subscription
aitl doctor                         # ports, keys, TLS fingerprint, model catalog
aitl serve                          # USB link; the device shows "Bridge linked"
```

Then on the device: **Setup › Keystrokes via** stays on *Bridge*; grant your terminal **Accessibility** permission
(System Settings › Privacy & Security › Accessibility) the first time typing or dictation does nothing.

### Wi-Fi (cable-free) — verified end to end
Use AITL Manager's Wi-Fi panel, or: `aitl provision --ssid "MyNetwork" --bridge` over USB. The device restarts onto
Wi-Fi and connects to `aitl-bridge.local` (advertised by the app over mDNS, so the Mac's IP can change). The device and
the Mac must be on the same network; guest networks are usually isolated. Frames are HMAC-SHA256 signed with a
per-session nonce (`signed` mode, fits a classic ESP32); `wifi_mode = "tls"` in config.toml selects pinned-certificate
TLS for boards with PSRAM. Wi-Fi and Bluetooth are mutually exclusive on no-PSRAM boards. See `docs/SECURITY.md`.

### The Mac app (recommended)
`macapp/` is a Swift menu-bar app, built like Lidless: `cd macapp && make install`. It supervises the Python bridge as
its child (so macOS attributes Bluetooth and keyboard control to "AITL Bridge"), and **AITL Manager** (menu › Open AITL
Manager, or left-click the icon) manages the device from the Mac: model, Wi-Fi credentials and bridge pairing over USB,
display, touch, dictation, Bluetooth, storage, restart and factory reset, with live status (links, RAM, IP) in the sidebar.
First run: allow the Bluetooth and "control System Events" prompts, and add the app under System Settings › Privacy &
Security › Accessibility.

### Bluetooth link (no cable, no Wi-Fi) — verified end to end
```bash
aitl serve --ble            # runs as "AITL Bridge.app" (macOS only lets apps use Bluetooth); allow the prompt once
aitl set bleLink on         # or Setup › Bluetooth link on the device
aitl autostart on           # start at login, restart on crash (LaunchAgent); aitl autostart off to remove
aitl logs -f  ·  aitl stop  ·  aitl ble-scan
```

### Bluetooth keyboard (works with any computer, iPad, phone)
Setup › **Bluetooth keyboard** on → pair "AITL Keyboard" from the host → Setup › **Keystrokes via: Bluetooth HID**.
For dictation over BLE set macOS *Dictation shortcut* to "Press Right Command key twice" (the default the device sends).

## Repository layout

```
firmware/      PlatformIO project (ESP32 Arduino, LVGL 8.3, LovyanGFX). `pio run -t upload`
  src/hal      display + CST820 touch, status LED, microSD
  src/link     NDJSON link: USB serial + Wi-Fi TLS WebSocket (bridge.cpp)
  src/ble      BLE HID keyboard + consumer control (NimBLE)
  src/core     settings (NVS), app state + protocol
  src/ui       theme, home, lists, compose keyboard, settings, wizard, calibration, pairing
bridge/        Python package `aitl` (providers, Mac automation, transports, CLI, tests)
macapp/        Swift menu-bar app "AITL Bridge" that runs and supervises the bridge (make install)
docs/          HARDWARE, PROTOCOL, SECURITY, UI
tools/         flash.sh, erase.sh, monitor.sh, probe/ (hardware identification sketch)
firmware-backup/  first 2 MB of whatever was on the board before (2026-10-20)
```

## Boards
One build flag per board (`firmware/boards/`): `cyd28c` (this unit: ILI9341 + CST820 capacitive), `cyd28c_st7789`,
`cyd28r` (2.8" resistive, XPT2046), `cyd24c` (2.4" capacitive), `cyd35r` (3.5" resistive, ST7796 480×320),
`hosyond40r` (Hosyond 4.0" ESP32-32E, ST7796 480×320, resistive; big-screen UI with taller buttons and 16 px text).
`tools/flash.sh cyd28r` flashes the resistive 2.8"; the first-boot wizard calibrates any of them (swap, invert,
scale, offset). Verified pinout and quirks: `docs/HARDWARE.md`.

## Device microphone (optional)
Solder an INMP441 to the P3 header: VDD→3V3, GND→GND, SCK→IO22, WS→IO21, SD→IO35, L/R→GND. Then on the device
Setup › Dictation › Microphone = *Device mic*, and check Setup › *Mic test* (a live level bar). Transcription runs on
the Mac: `pip install mlx-whisper` for free local Whisper, otherwise the bridge uses Gemini. Hold the BOOT button to
talk, release to send; or tap TALK and let the silence detector stop it.

## Roadmap (next vectors)
- V-A: on-device wake word / audio via an I²S mic on the P3 header (the CYD has no mic), streamed to the bridge for local Whisper.
- V-B: OTA updates over the pinned Wi-Fi link; partition table already reserves the space decision.
- V-C: per-chat system prompts and "personas" selectable from the device; tool use (calendar, notes) through the bridge.
- V-D: Windows/Linux bridge back-ends for `mac.py` (the protocol is OS-agnostic).
- V-E: printed case with the BOOT button exposed as the push-to-talk key.

*Decision support, not decision authority.* — UNCLASSIFIED // OPEN SOURCE

## Repository
Source of truth: this repo (`~/Desktop/AITL`, https://github.com/hord-brayden/AITL). Device firmware in `firmware/`,
Mac bridge in `bridge/`, menu-bar app in `macapp/`. The 2 MB flash dump of the board's previous firmware is kept out of git.
