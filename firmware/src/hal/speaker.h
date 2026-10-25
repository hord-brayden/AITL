#pragma once
#include <Arduino.h>
// Onboard speaker (DAC pin through the amp). Short chimes only; non-blocking sequences driven from tick().
namespace speaker {
  void begin();
  void chime(uint8_t kind);   // 0 tap, 1 attention (permission / needs input), 2 done, 3 error
  void tick();
}
