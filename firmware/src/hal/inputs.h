#pragma once
#include <Arduino.h>
// Physical add-ons beyond touch: rotary encoder (A/B/SW) and a toggle switch. Pins come from settings; -1 = not fitted.
namespace inputs {
  enum class Ev : uint8_t { None, EncCw, EncCcw, EncPress, ToggleOn, ToggleOff };
  void begin();
  void applyPins();        // re-init after a settings change
  Ev poll();               // one event per call, debounced
  bool toggleState();      // current switch position (false when not fitted)
}
