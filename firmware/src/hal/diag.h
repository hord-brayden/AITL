#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>
// Boot diagnostics: why did we reset, how long did the previous boot run, how low did its heap get.
// Survives panics and watchdog resets via RTC memory; the last entries are kept in NVS and reported in `hello`.
namespace diag {
  void begin();                       // call first thing in setup()
  void tick();                        // updates uptime / min-heap trackers
  void fill(JsonArray out);           // last boots: {reason, up, minheap}
  const char* lastReason();
}
