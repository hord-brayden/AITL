#pragma once
#include <Arduino.h>
#include "../config.h"

// Persistent device settings (NVS). Keep POD-ish; strings are bounded.
struct Settings {
  // Display
  uint8_t  brightness   = 200;   // 0..255
  uint16_t screenTimeout = 120;  // seconds, 0 = never
  uint8_t  rotation     = 1;     // 0..3 (1 = landscape, USB on the right)
  bool     invertColors = AITL_DEFAULT_INVERT;
  bool     bgrOrder     = false;
  // Touch mapping (applied to native 240x320 raw coordinates before rotation)
  bool     touchSwapXY  = false;
  bool     touchInvX    = false;
  bool     touchInvY    = false;
  int16_t  touchOffX    = 0;
  int16_t  touchOffY    = 0;
  uint16_t touchScaleX  = 1000;  // x1000; resistive panels need scale, capacitive stay at 1000
  uint16_t touchScaleY  = 1000;
  uint16_t longPressMs  = 400;
  uint8_t  touchDebounce = 1;    // consecutive samples required (1..4)
  bool     hapticLed    = true;  // flash LED on tap
  bool     sdLog        = true;  // append finished exchanges to microSD when present
  // Link
  bool     wifiEnabled  = false;
  bool     bleEnabled   = false;
  uint8_t  hidTarget    = 0;     // 0 = bridge (USB/Wi-Fi), 1 = BLE keyboard
  uint8_t  dictShortcut = 1;     // BLE HID: 0 RightCmd x2, 1 Ctrl x2, 2 F5, 3 Cmd+Opt+D
  uint8_t  dictSource   = 0;     // 0 = host Mac dictation, 1 = device microphone (I2S on P3)
  uint8_t  dictTarget   = 0;     // device mic result: 0 = ask the AI, 1 = type into the Mac
  uint8_t  micGain      = 4;     // 1..8 (shift applied to 24-bit samples)
  bool     bleLink      = false; // expose the bridge protocol over BLE (Nordic UART) as well as HID
  uint8_t  wifiMode     = 0;     // 0 = signed frames over ws (fits classic ESP32), 1 = TLS pinned (needs PSRAM)
  // Hardware add-ons (-1 = not fitted). Pins are runtime settings so the case wiring can change without a reflash.
  int8_t   micSck       = PIN_MIC_SCK;
  int8_t   micWs        = PIN_MIC_WS;
  int8_t   micSd        = PIN_MIC_SD;
  int8_t   encA         = -1;
  int8_t   encB         = -1;
  int8_t   encSw        = -1;
  int8_t   togglePin    = -1;
  uint8_t  toggleRole   = 0;     // 0 privacy (mute dictation), 1 screen off, 2 glance mode
  bool     batteryEnabled = false;
  uint16_t batteryDivider = 2000; // x1000: ADC millivolts * divider = battery millivolts (2.0 typical)
  uint8_t  chime        = 1;     // 0 off, 1 permission/needs-input only, 2 all alerts
  bool     glance       = false; // large type for the monitor-hook mount
  uint8_t  cpuMhz       = 240;   // 160 runs cooler in a sealed case
  char     wifiSsid[33] = "";
  char     wifiPass[65] = "";
  char     bridgeHost[64] = "";
  uint16_t bridgePort   = 7777;
  char     bridgeToken[65] = "";  // per-device bearer token (hex)
  char     bridgeName[32] = "";
  // Model / chat
  char     modelId[48]  = "";
  char     lastChat[12] = "";    // resume this chat after a reboot (the Mac resets us when it opens the USB port)
  // Lifecycle
  bool     setupDone    = false;
  uint16_t bootCount    = 0;
};

extern Settings g_settings;
void settingsLoad();
void settingsSave();
void settingsReset();
void settingsRotate();   // next rotation; swaps the X/Y inversion flags for 90-degree steps, clears offsets
void settingsSetRotation(uint8_t r);
