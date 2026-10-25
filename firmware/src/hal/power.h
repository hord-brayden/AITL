#pragma once
#include <Arduino.h>
// Battery gauge on an ADC pin through a divider (board-dependent; GPIO34 on the Hosyond 4"). Optional.
namespace power {
  void begin();
  void tick();
  bool enabled();
  uint16_t millivolts();   // battery voltage estimate
  uint8_t percent();       // Li-ion curve, 0..100
  bool low();              // below ~3.4 V
}
