#include "diag.h"
#include <Preferences.h>
#include <esp_system.h>
namespace diag {
RTC_NOINIT_ATTR static uint32_t rtcMagic, rtcUpS, rtcMinHeap;
static const uint32_t MAGIC = 0xA17D1A60;
struct Entry { uint8_t reason; uint32_t up; uint32_t minHeap; };
static Entry s_ring[5]; static uint8_t s_count = 0; static uint32_t s_minHeap = 0xFFFFFFFF; static uint32_t s_lastTick = 0;
static const char* names[] = {"unknown", "power-on", "external", "software", "panic", "int-wdt", "task-wdt", "wdt", "deep-sleep", "brownout", "sdio"};
const char* lastReason() { int r = (int)esp_reset_reason(); return (r >= 0 && r <= 10) ? names[r] : "?"; }
void begin() {
  Preferences p; p.begin("diag", false);
  s_count = p.getBytesLength("ring") / sizeof(Entry); if (s_count > 5) s_count = 5;
  if (s_count) p.getBytes("ring", s_ring, s_count * sizeof(Entry));
  Entry e{(uint8_t)esp_reset_reason(), (rtcMagic == MAGIC) ? rtcUpS : 0, (rtcMagic == MAGIC) ? rtcMinHeap : 0};
  if (s_count == 5) { memmove(s_ring, s_ring + 1, 4 * sizeof(Entry)); s_count = 4; }
  s_ring[s_count++] = e;
  p.putBytes("ring", s_ring, s_count * sizeof(Entry)); p.end();
  rtcMagic = MAGIC; rtcUpS = 0; rtcMinHeap = ESP.getFreeHeap();
}
void tick() {
  uint32_t now = millis(); if (now - s_lastTick < 1000) return; s_lastTick = now;
  rtcUpS = now / 1000; uint32_t h = ESP.getFreeHeap(); if (h < rtcMinHeap) rtcMinHeap = h;
}
void fill(JsonArray out) {
  for (int i = s_count - 1; i >= 0 && i >= (int)s_count - 3; i--) {
    JsonObject o = out.createNestedObject(); int r = s_ring[i].reason; o["reason"] = (r >= 0 && r <= 10) ? names[r] : "?"; o["up"] = s_ring[i].up; o["minheap"] = s_ring[i].minHeap;
  }
}
}
