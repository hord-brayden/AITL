#include "power.h"
#include "../core/settings.h"
#ifndef PIN_BATTERY_ADC
#define PIN_BATTERY_ADC 34
#endif
namespace power {
static uint16_t s_mv = 0; static uint32_t s_lastAt = 0; static float s_avg = 0;
void begin() { if (g_settings.batteryEnabled) { analogSetPinAttenuation(PIN_BATTERY_ADC, ADC_11db); pinMode(PIN_BATTERY_ADC, INPUT); } }
bool enabled() { return g_settings.batteryEnabled; }
void tick() {
  if (!g_settings.batteryEnabled || millis() - s_lastAt < 2000) return;
  s_lastAt = millis();
  uint32_t acc = 0; for (int i = 0; i < 16; i++) acc += analogReadMilliVolts(PIN_BATTERY_ADC);
  float mv = (acc / 16.0f) * (g_settings.batteryDivider / 1000.0f);
  s_avg = s_avg == 0 ? mv : (s_avg * 0.8f + mv * 0.2f);
  s_mv = (uint16_t)s_avg;
}
uint16_t millivolts() { return s_mv; }
uint8_t percent() {
  // single-cell Li-ion discharge curve, resting voltage
  static const struct { uint16_t mv; uint8_t pct; } pts[] = {{4200, 100}, {4100, 92}, {4000, 80}, {3900, 65}, {3800, 50}, {3700, 35}, {3600, 20}, {3500, 10}, {3400, 5}, {3300, 0}};
  if (s_mv >= pts[0].mv) return 100;
  for (size_t i = 1; i < sizeof(pts) / sizeof(pts[0]); i++) {
    if (s_mv >= pts[i].mv) { float f = (float)(s_mv - pts[i].mv) / (pts[i - 1].mv - pts[i].mv); return pts[i].pct + (uint8_t)(f * (pts[i - 1].pct - pts[i].pct)); }
  }
  return 0;
}
bool low() { return g_settings.batteryEnabled && s_mv > 0 && s_mv < 3400; }
}
