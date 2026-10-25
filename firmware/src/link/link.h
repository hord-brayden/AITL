#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

// Transport-agnostic NDJSON link to the AITL bridge (USB serial and/or Wi-Fi WebSocket).
// Every frame is one JSON object per line. Device log lines start with '#' so the bridge can skip them.
namespace bridge {
  enum class Transport : uint8_t { None, Serial, WiFi, Ble };
  typedef void (*Handler)(JsonDocument& doc, Transport from);

  void begin();
  void setDeviceId(const String& id);   // used in the signed Wi-Fi handshake
  void tick();
  void setHandler(Handler h);

  bool send(JsonDocument& doc);          // routes to the preferred connected transport
  bool sendVia(Transport t, JsonDocument& doc);
  bool connected();                      // a bridge has acked hello on some transport
  Transport active();
  void markHello(Transport t, bool ok);  // app calls when hello.ack arrives / link drops

  // Wi-Fi + bridge
  void wifiApply();                      // (re)connect using g_settings
  void wifiDisconnect();
  String wifiStatus();                   // human string for the UI
  String bridgeStatus();
  String ipAddress();
  int rssi();
  bool wifiUp();
  bool wsUp();
  void setPairingMode(bool on);          // allow unpinned TLS for TOFU pairing
  bool pairingMode();
  bool storeBridgeCert(const String& pem);
  bool hasBridgeCert();
  String bridgeCertFingerprint();        // "AB:CD:..." sha256 of stored cert (DER)
  void log(const char* fmt, ...);        // '#'-prefixed serial log
  // Saved Wi-Fi networks (LittleFS /wifi.json). The net task scans and joins the strongest known one.
  void wifiNetworks(JsonArray out);      // [{ssid, prio, current}]
  bool wifiAdd(const char* ssid, const char* pass, int prio = 0);   // upsert, becomes current
  bool wifiRemove(const char* ssid);
  bool wifiUse(const char* ssid);        // force this one next
  void wifiScanRequest();                // async; results arrive via scanResults()
  bool wifiScanResults(JsonArray out);   // true when a fresh scan is available: [{ssid, rssi}]
  bool bleUp();                          // NUS subscribed
}
