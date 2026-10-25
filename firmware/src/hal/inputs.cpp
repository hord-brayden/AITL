#include "inputs.h"
#include "../core/settings.h"
namespace inputs {
static int8_t sA = -1, sB = -1, sS = -1, sT = -1;
static uint8_t lastAB = 0; static int8_t accum = 0;
static bool swDown = false; static uint32_t swAt = 0;
static bool tState = false; static uint32_t tChangedAt = 0; static bool tInit = false;
static void setup(int8_t pin) { if (pin >= 0) pinMode(pin, (pin >= 34) ? INPUT : INPUT_PULLUP); }
void applyPins() {
  sA = g_settings.encA; sB = g_settings.encB; sS = g_settings.encSw; sT = g_settings.togglePin;
  setup(sA); setup(sB); setup(sS); setup(sT);
  if (sA >= 0 && sB >= 0) lastAB = (digitalRead(sA) << 1) | digitalRead(sB);
  if (sT >= 0) { tState = digitalRead(sT) == LOW; tInit = true; }
}
void begin() { applyPins(); }
bool toggleState() { return sT >= 0 && tState; }
Ev poll() {
  uint32_t now = millis();
  if (sA >= 0 && sB >= 0) {   // quadrature state table, 4 edges per detent (EC11)
    uint8_t ab = (digitalRead(sA) << 1) | digitalRead(sB);
    if (ab != lastAB) {
      static const int8_t table[16] = {0, -1, 1, 0, 1, 0, 0, -1, -1, 0, 0, 1, 0, 1, -1, 0};
      accum += table[(lastAB << 2) | ab]; lastAB = ab;
      if (accum >= 4) { accum = 0; return Ev::EncCw; }
      if (accum <= -4) { accum = 0; return Ev::EncCcw; }
    }
  }
  if (sS >= 0) {
    bool down = digitalRead(sS) == LOW;
    if (down && !swDown && now - swAt > 30) { swDown = true; swAt = now; }
    else if (!down && swDown && now - swAt > 30) { swDown = false; swAt = now; return Ev::EncPress; }
  }
  if (sT >= 0 && tInit) {
    bool st = digitalRead(sT) == LOW;
    if (st != tState && now - tChangedAt > 20) { tChangedAt = now; tState = st; return st ? Ev::ToggleOn : Ev::ToggleOff; }
  }
  return Ev::None;
}
}
