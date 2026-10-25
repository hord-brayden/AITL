#include "speaker.h"
#include "../config.h"
#ifndef PIN_SPEAKER
#define PIN_SPEAKER 26
#endif
#ifndef PIN_AUDIO_EN
#define PIN_AUDIO_EN -1
#endif
namespace speaker {
static const uint8_t CH = 5;
struct Note { uint16_t hz; uint16_t ms; };
static Note s_seq[6]; static uint8_t s_n = 0, s_i = 0; static uint32_t s_until = 0; static bool s_playing = false;
void begin() { ledcSetup(CH, 2000, 8); if (PIN_AUDIO_EN >= 0) { pinMode(PIN_AUDIO_EN, OUTPUT); digitalWrite(PIN_AUDIO_EN, LOW); } }
static void start() { ledcAttachPin(PIN_SPEAKER, CH); if (PIN_AUDIO_EN >= 0) digitalWrite(PIN_AUDIO_EN, HIGH); s_playing = true; s_i = 0; s_until = 0; }
static void stop() { ledcWriteTone(CH, 0); ledcDetachPin(PIN_SPEAKER); pinMode(PIN_SPEAKER, INPUT); if (PIN_AUDIO_EN >= 0) digitalWrite(PIN_AUDIO_EN, LOW); s_playing = false; }
void chime(uint8_t kind) {
  switch (kind) {
    case 0: s_seq[0] = {1200, 25}; s_n = 1; break;
    case 1: s_seq[0] = {880, 90}; s_seq[1] = {0, 60}; s_seq[2] = {1175, 90}; s_seq[3] = {0, 60}; s_seq[4] = {1568, 140}; s_n = 5; break;
    case 2: s_seq[0] = {1047, 70}; s_seq[1] = {1319, 110}; s_n = 2; break;
    default: s_seq[0] = {330, 120}; s_seq[1] = {0, 40}; s_seq[2] = {262, 180}; s_n = 3; break;
  }
  start();
}
void tick() {
  if (!s_playing) return;
  uint32_t now = millis();
  if (now < s_until) return;
  if (s_i >= s_n) { stop(); return; }
  ledcWriteTone(CH, s_seq[s_i].hz); s_until = now + s_seq[s_i].ms; s_i++;
}
}
