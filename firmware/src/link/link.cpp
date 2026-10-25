#include "link.h"
#include <WiFi.h>
#include <ESPmDNS.h>
#include <WebSocketsClient.h>
#include <LittleFS.h>
#include <mbedtls/sha256.h>
#include <mbedtls/md.h>
#include <mbedtls/base64.h>
#include "../config.h"
#include "../core/settings.h"
#include "../ble/ble_hid.h"

namespace bridge {
static Handler s_handler = nullptr;
static bool s_serialHello = false, s_wifiHello = false, s_bleHello = false;
static char s_rx[LINK_MAX_MSG]; static size_t s_rxLen = 0;   // (static 6 KB; the Wi-Fi path uses heap strings instead)
static WebSocketsClient s_ws; static bool s_wsStarted = false, s_wsConnected = false;
static bool s_pairing = false;
static volatile bool s_reqRestartWs = false;   // defined early: used by setPairingMode/storeBridgeCert above the net task
// ---- signed-frame link (Wi-Fi mode 0): HMAC-SHA256 over "sid.n.m" with key = SHA256(token); counters per direction ----
static String s_deviceId;
static uint8_t s_hmacKey[32]; static bool s_hmacKeyOk = false;
static uint32_t s_txN = 0; static int64_t s_rxN = -1; static String s_sid;
static void signedReset() { s_txN = (uint32_t)(esp_random() & 0x3fffffff); s_rxN = -1; s_sid = ""; }
static void deriveKey() {
  mbedtls_sha256((const uint8_t*)g_settings.bridgeToken, strlen(g_settings.bridgeToken), s_hmacKey, 0);
  s_hmacKeyOk = g_settings.bridgeToken[0] != 0;
}
static String hmacHex(const String& sid, uint32_t n, const String& m) {
  String input = sid + "." + String(n) + "." + m;
  uint8_t out[32];
  mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), s_hmacKey, 32, (const uint8_t*)input.c_str(), input.length(), out);
  char hex[65]; for (int i = 0; i < 32; i++) sprintf(hex + i * 2, "%02x", out[i]); hex[64] = 0;
  return String(hex);
}
static bool signedMode() { return g_settings.wifiMode == 0 && !s_pairing; }
static String wrapSigned(const String& m) {
  s_txN++;
  DynamicJsonDocument env(m.length() + 256);
  env["n"] = s_txN; env["sid"] = s_sid; env["m"] = m; env["s"] = hmacHex(s_sid, s_txN, m);
  String out; serializeJson(env, out); return out;
}
// returns the inner message (or empty) after verifying signature, session and counter
static String unwrapSigned(const char* raw, size_t len) {
  DynamicJsonDocument env(len + 512);
  if (deserializeJson(env, raw, len) != DeserializationError::Ok) return "";
  uint32_t n = env["n"] | 0; const char* sid = env["sid"] | ""; const char* m = env["m"] | ""; const char* sig = env["s"] | "";
  if (!*m || !*sig) return "";
  if (!s_sid.length()) s_sid = sid;             // the bridge's first signed frame establishes the session nonce
  else if (s_sid != sid) return "";
  if ((int64_t)n <= s_rxN) return "";          // replay / reorder
  String expect = hmacHex(String(sid), n, String(m));
  if (expect.length() != strlen(sig)) return "";
  uint8_t diff = 0; for (size_t i = 0; i < expect.length(); i++) diff |= (uint8_t)(expect[i] ^ sig[i]);
  if (diff) return "";
  s_rxN = n;
  return String(m);
}
static String s_caPem;
static uint32_t s_lastWifiTry = 0, s_lastPing = 0;
static const char* CA_PATH = "/bridge_ca.pem";
static const char* WIFI_PATH = "/wifi.json";
static bool s_fsOk;
static TaskHandle_t s_netTask;
static volatile bool s_reqApply;
struct Net { String ssid, pass; int prio; };
static std::vector<Net> s_nets; static String s_forceSsid;
static volatile bool s_scanReq = false, s_scanReady = false; static uint8_t s_wifiFails = 0; static std::vector<std::pair<String, int>> s_scan;
static void netsLoad() {
  s_nets.clear(); if (!s_fsOk || !LittleFS.exists(WIFI_PATH)) return;
  File f = LittleFS.open(WIFI_PATH, "r"); DynamicJsonDocument d(3072); if (deserializeJson(d, f) == DeserializationError::Ok) for (JsonObject o : d.as<JsonArray>()) s_nets.push_back({(const char*)(o["ssid"] | ""), (const char*)(o["pass"] | ""), (int)(o["prio"] | 0)});
  f.close();
}
static void netsSave() {
  if (!s_fsOk) return; DynamicJsonDocument d(3072); JsonArray a = d.to<JsonArray>();
  for (auto& n : s_nets) { JsonObject o = a.createNestedObject(); o["ssid"] = n.ssid; o["pass"] = n.pass; o["prio"] = n.prio; }
  File f = LittleFS.open(WIFI_PATH, "w"); if (f) { serializeJson(d, f); f.close(); }
}
// s_fsOk declared above

void log(const char* fmt, ...) {
  char buf[256]; va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
  Serial.print("# "); Serial.println(buf);
}

void setHandler(Handler h) { s_handler = h; }
void wifiNetworks(JsonArray out) { for (auto& n : s_nets) { JsonObject o = out.createNestedObject(); o["ssid"] = n.ssid; o["prio"] = n.prio; o["current"] = (n.ssid == g_settings.wifiSsid); } }
bool wifiAdd(const char* ssid, const char* pass, int prio) {
  if (!ssid || !*ssid) return false;
  bool found = false; for (auto& n : s_nets) if (n.ssid == ssid) { n.pass = pass; n.prio = prio; found = true; }
  if (!found) { if (s_nets.size() >= 8) s_nets.erase(s_nets.begin()); s_nets.push_back({ssid, pass, prio}); }
  netsSave(); strlcpy(g_settings.wifiSsid, ssid, sizeof(g_settings.wifiSsid)); strlcpy(g_settings.wifiPass, pass, sizeof(g_settings.wifiPass)); settingsSave();
  return true;
}
bool wifiRemove(const char* ssid) { for (size_t i = 0; i < s_nets.size(); i++) if (s_nets[i].ssid == ssid) { s_nets.erase(s_nets.begin() + i); netsSave(); return true; } return false; }
bool wifiUse(const char* ssid) { for (auto& n : s_nets) if (n.ssid == ssid) { s_forceSsid = ssid; strlcpy(g_settings.wifiSsid, n.ssid.c_str(), sizeof(g_settings.wifiSsid)); strlcpy(g_settings.wifiPass, n.pass.c_str(), sizeof(g_settings.wifiPass)); settingsSave(); if (s_netTask) s_reqApply = true; return true; } return false; }
void wifiScanRequest() { s_scanReq = true; }
bool wifiScanResults(JsonArray out) { if (!s_scanReady) return false; for (auto& r : s_scan) { JsonObject o = out.createNestedObject(); o["ssid"] = r.first; o["rssi"] = r.second; } s_scanReady = false; return true; }
void setDeviceId(const String& id) { s_deviceId = id; }
bool connected() { return s_serialHello || s_wifiHello || s_bleHello; }
bool bleUp() { return blehid::linkSubscribed(); }
Transport active() { return s_serialHello ? Transport::Serial : (s_wifiHello ? Transport::WiFi : (s_bleHello ? Transport::Ble : Transport::None)); }
void markHello(Transport t, bool ok) { if (t == Transport::Serial) s_serialHello = ok; else if (t == Transport::WiFi) s_wifiHello = ok; else if (t == Transport::Ble) s_bleHello = ok; }
bool wifiUp() { return WiFi.status() == WL_CONNECTED; }
bool wsUp() { return s_wsConnected; }
bool pairingMode() { return s_pairing; }
void setPairingMode(bool on) { s_pairing = on; s_reqRestartWs = true; }
String ipAddress() { return wifiUp() ? WiFi.localIP().toString() : String(""); }
int rssi() { return wifiUp() ? WiFi.RSSI() : 0; }
bool hasBridgeCert() { return s_caPem.length() > 0; }

bool storeBridgeCert(const String& pem) {
  if (!s_fsOk) return false;
  File f = LittleFS.open(CA_PATH, "w"); if (!f) return false;
  f.print(pem); f.close(); s_caPem = pem; s_reqRestartWs = true; return true;
}

String bridgeCertFingerprint() {
  if (!s_caPem.length()) return "";
  int b = s_caPem.indexOf("-----BEGIN CERTIFICATE-----"); int e = s_caPem.indexOf("-----END CERTIFICATE-----");
  if (b < 0 || e < 0) return "";
  String body; for (int i = b + 27; i < e; i++) { char c = s_caPem[i]; if (c != '\n' && c != '\r' && c != ' ') body += c; }
  size_t derLen = 0; std::vector<uint8_t> der(body.length());
  if (mbedtls_base64_decode(der.data(), der.size(), &derLen, (const uint8_t*)body.c_str(), body.length()) != 0) return "";
  uint8_t h[32]; mbedtls_sha256((const uint8_t*)der.data(), derLen, h, 0);
  char out[96]; for (int i = 0; i < 32; i++) sprintf(out + i * 3, "%02X%s", h[i], i < 31 ? ":" : "");
  return String(out);
}

static void dispatch(const char* json, size_t len, Transport from) {
  if (!s_handler) return;
  DynamicJsonDocument doc(LINK_MAX_MSG + 1024);
  if (deserializeJson(doc, json, len) != DeserializationError::Ok) { log("bad json from %d", (int)from); return; }
  s_handler(doc, from);
}

// ---------------- Wi-Fi + WebSocket run on their own task (core 0) ----------------
// TLS handshakes, DNS/mDNS lookups and reconnects block for seconds; keeping them off the UI core keeps LVGL fluid.
// Frames cross between the tasks through mutex-protected queues; the protocol handler always runs on the main loop.
#include <vector>
#include <string>
// s_netTask declared above
static SemaphoreHandle_t s_qLock = nullptr;
static std::vector<std::string> s_wsIn, s_wsOut;
static volatile bool s_reqDisconnect = false, s_reqSignedReset = false;
static volatile bool s_mdnsUp = false;

static void qPush(std::vector<std::string>& q, const char* data, size_t len) {
  if (!s_qLock) return;
  xSemaphoreTake(s_qLock, portMAX_DELAY);
  if (q.size() < 32) q.emplace_back(data, len);
  xSemaphoreGive(s_qLock);
}
static bool qPop(std::vector<std::string>& q, std::string& out) {
  if (!s_qLock) return false;
  xSemaphoreTake(s_qLock, portMAX_DELAY);
  bool ok = !q.empty(); if (ok) { out = std::move(q.front()); q.erase(q.begin()); }
  xSemaphoreGive(s_qLock);
  return ok;
}

static void wsEvent(WStype_t type, uint8_t* payload, size_t length) {   // net task context
  switch (type) {
    case WStype_CONNECTED: s_wsConnected = true; s_reqSignedReset = true; log("ws connected"); break;   // new socket = new signing session
    case WStype_DISCONNECTED: if (s_wsConnected) log("ws disconnected"); s_wsConnected = false; s_wifiHello = false; break;
    case WStype_TEXT: qPush(s_wsIn, (const char*)payload, length); break;
    case WStype_ERROR: log("ws error (%u bytes)", (unsigned)length); break;
    default: break;
  }
}

static void wsStart() {   // net task context
  if (s_wsStarted || !wifiUp() || !g_settings.bridgeHost[0]) return;
  String path = "/ws";
  if (signedMode()) {
    if (!g_settings.bridgeToken[0]) return;         // not provisioned
    deriveKey(); signedReset();
    String hdr = String("Authorization: Bearer signed\r\nX-AITL-Device: ") + s_deviceId;   // the token itself never travels
    s_ws.setExtraHeaders(hdr.c_str());
    s_ws.begin(g_settings.bridgeHost, g_settings.bridgePort, path.c_str());
  } else {
    String auth = String("Authorization: Bearer ") + (g_settings.bridgeToken[0] ? g_settings.bridgeToken : "pairing");
    s_ws.setExtraHeaders(auth.c_str());
    if (s_caPem.length() && !s_pairing) s_ws.beginSslWithCA(g_settings.bridgeHost, g_settings.bridgePort, path.c_str(), s_caPem.c_str());
    else if (s_pairing) s_ws.beginSSL(g_settings.bridgeHost, g_settings.bridgePort, path.c_str());  // unpinned: pairing only
    else return;  // no cert and not pairing: refuse to connect unpinned
  }
  s_ws.onEvent(wsEvent);
  s_ws.setReconnectInterval(5000);
  s_ws.enableHeartbeat(15000, 4000, 2);
  s_wsStarted = true;
  log("ws -> %s:%u (%s) heap=%u", g_settings.bridgeHost, g_settings.bridgePort, s_pairing ? "PAIRING/unpinned" : signedMode() ? "signed" : "tls pinned", ESP.getFreeHeap());
}
static void wsStop() { if (s_wsStarted) { s_ws.disconnect(); s_wsStarted = false; } s_wsConnected = false; s_wifiHello = false; }

static void doScan() {   // net task context, blocking ~2 s
  WiFi.mode(WIFI_STA);
  if (!wifiUp()) { WiFi.disconnect(false, false); vTaskDelay(pdMS_TO_TICKS(150)); }   // a connect in progress makes the scan fail
  int n = WiFi.scanNetworks(false, false, false, 300);
  if (n < 0) { log("wifi scan failed (%d)", n); vTaskDelay(pdMS_TO_TICKS(500)); n = WiFi.scanNetworks(false, false, false, 300); }
  log("wifi scan: %d networks", n);
  s_scan.clear();
  for (int i = 0; i < n && s_scan.size() < 20; i++) { String ss = WiFi.SSID(i); if (!ss.length()) continue; bool dup = false; for (auto& x : s_scan) if (x.first == ss) { dup = true; if (WiFi.RSSI(i) > x.second) x.second = WiFi.RSSI(i); } if (!dup) s_scan.push_back({ss, WiFi.RSSI(i)}); }
  WiFi.scanDelete();
  s_scanReady = true;
}
static void wifiConnectNow() {   // net task context
  WiFi.mode(WIFI_STA); WiFi.setHostname(AITL_HOSTNAME); WiFi.setSleep(true);
  const char* ssid = g_settings.wifiSsid; const char* pass = g_settings.wifiPass;
  if (s_forceSsid.length()) { for (auto& n : s_nets) if (n.ssid == s_forceSsid) { ssid = n.ssid.c_str(); pass = n.pass.c_str(); } s_forceSsid = ""; }
  else if (s_nets.size() > 1) {   // several saved: pick the strongest visible one (ties -> higher prio)
    doScan(); int best = -1000; const Net* pick = nullptr;
    for (auto& r : s_scan) for (auto& n : s_nets) if (n.ssid == r.first) { int score = r.second + n.prio * 20; if (score > best) { best = score; pick = &n; } }
    if (pick) { ssid = pick->ssid.c_str(); pass = pick->pass.c_str(); strlcpy(g_settings.wifiSsid, ssid, sizeof(g_settings.wifiSsid)); strlcpy(g_settings.wifiPass, pass, sizeof(g_settings.wifiPass)); }
  }
  if (!*ssid) { s_lastWifiTry = millis(); return; }
  WiFi.begin(ssid, pass);
  s_lastWifiTry = millis();
  log("wifi -> %s (%u saved)", ssid, (unsigned)s_nets.size());
}

static void netTask(void*) {
  for (;;) {
    if (s_reqDisconnect) { s_reqDisconnect = false; wsStop(); WiFi.disconnect(true, true); WiFi.mode(WIFI_OFF); s_mdnsUp = false; }
    if (s_reqApply) { s_reqApply = false; wsStop(); if (g_settings.wifiEnabled && (g_settings.wifiSsid[0] || !s_nets.empty())) wifiConnectNow(); }
    if (s_reqRestartWs) { s_reqRestartWs = false; wsStop(); }
    if (s_scanReq) { s_scanReq = false; bool wasUp = wifiUp(); doScan(); if (!wasUp) s_lastWifiTry = 0; }   // reconnect right after an on-demand scan
    if (g_settings.wifiEnabled && (g_settings.wifiSsid[0] || !s_nets.empty())) {
      if (!wifiUp()) {
        if (s_wsStarted) wsStop();
        s_mdnsUp = false;
        if (millis() - s_lastWifiTry > 20000UL * (1 + (s_wifiFails < 5 ? s_wifiFails : 5))) { if (s_lastWifiTry) s_wifiFails++; wifiConnectNow(); }   // back off to 2 min when the network is away
      } else {
        s_wifiFails = 0;
        if (!s_mdnsUp) { s_mdnsUp = MDNS.begin(AITL_HOSTNAME); log("wifi up ip=%s gw=%s rssi=%d -> bridge %s:%u", WiFi.localIP().toString().c_str(), WiFi.gatewayIP().toString().c_str(), WiFi.RSSI(), g_settings.bridgeHost, g_settings.bridgePort); }
        if (!s_wsStarted) wsStart();
        if (s_wsStarted) {
          s_ws.loop();
          std::string out; int n = 0;
          while (s_wsConnected && n++ < 8 && qPop(s_wsOut, out)) s_ws.sendTXT(out.c_str(), out.size());
        }
      }
    }
    vTaskDelay(pdMS_TO_TICKS(5));
  }
}
static void netEnsureTask() {
  if (s_netTask) return;
  if (!s_qLock) s_qLock = xSemaphoreCreateMutex();
  xTaskCreatePinnedToCore(netTask, "aitl-net", 12288, nullptr, 1, &s_netTask, 0);   // core 0; TLS needs the big stack
}

void wifiApply() {
  if (!g_settings.wifiEnabled || (!g_settings.wifiSsid[0] && s_nets.empty())) { wifiDisconnect(); return; }
  netEnsureTask(); s_reqApply = true;
}
void wifiDisconnect() { if (s_netTask) s_reqDisconnect = true; }
String wifiStatus() {
  if (!g_settings.wifiEnabled) return "off";
  if (!g_settings.wifiSsid[0]) return "no network set";
  if (wifiUp()) return String(g_settings.wifiSsid) + " " + ipAddress();
  return String("joining ") + g_settings.wifiSsid + "...";
}
String bridgeStatus() {
  if (!g_settings.bridgeHost[0]) return "not paired";
  if (s_wifiHello) return String("linked: ") + (g_settings.bridgeName[0] ? g_settings.bridgeName : g_settings.bridgeHost);
  if (s_wsConnected) return "handshake...";
  if (!s_caPem.length() && !s_pairing) return "needs pairing (no cert)";
  return wifiUp() ? String("connecting to ") + g_settings.bridgeHost : "waiting for wifi";
}

bool sendVia(Transport t, JsonDocument& doc) {
  if (t == Transport::Serial) { serializeJson(doc, Serial); Serial.print('\n'); return true; }
  if (t == Transport::WiFi && s_wsConnected) { String s; serializeJson(doc, s); if (signedMode()) s = wrapSigned(s); qPush(s_wsOut, s.c_str(), s.length()); return true; }
  if (t == Transport::Ble && blehid::linkSubscribed()) { String s; serializeJson(doc, s); s += '\n'; return blehid::linkSend(s.c_str(), s.length()); }
  return false;
}
bool send(JsonDocument& doc) {
  Transport t = active();
  if (t == Transport::None) { // not acked yet: try every transport that is up so hello can go out
    bool ok = sendVia(Transport::Serial, doc); if (s_wsConnected) ok |= sendVia(Transport::WiFi, doc); if (blehid::linkSubscribed()) ok |= sendVia(Transport::Ble, doc); return ok;
  }
  return sendVia(t, doc);
}

static void bleLine(const char* line, size_t len) { if (len && line[0] == '{') dispatch(line, len, Transport::Ble); }

void begin() {
  blehid::setLineHandler(bleLine);
  s_fsOk = LittleFS.begin(true);
  if (s_fsOk && LittleFS.exists(CA_PATH)) { File f = LittleFS.open(CA_PATH, "r"); s_caPem = f.readString(); f.close(); }
  netsLoad();
  if (s_nets.empty() && g_settings.wifiSsid[0]) { s_nets.push_back({g_settings.wifiSsid, g_settings.wifiPass, 0}); netsSave(); }   // migrate the single network
  log("littlefs %s, cert %s, %u wifi networks", s_fsOk ? "ok" : "FAIL", s_caPem.length() ? "present" : "none", (unsigned)s_nets.size());
  if (g_settings.wifiEnabled) wifiApply();
}

void tick() {   // main loop
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (s_rxLen) { s_rx[s_rxLen] = 0; if (s_rx[0] == '{') dispatch(s_rx, s_rxLen, Transport::Serial); s_rxLen = 0; }
    } else if (s_rxLen < sizeof(s_rx) - 1) s_rx[s_rxLen++] = c; else s_rxLen = 0;
  }
  if (s_reqSignedReset) { s_reqSignedReset = false; signedReset(); }
  std::string in; int n = 0;
  while (n++ < 4 && qPop(s_wsIn, in)) {
    if (in.empty() || in[0] != '{') continue;
    if (signedMode()) { String m = unwrapSigned(in.c_str(), in.size()); if (m.length()) dispatch(m.c_str(), m.length(), Transport::WiFi); else log("dropped unverifiable wifi frame"); }
    else dispatch(in.c_str(), in.size(), Transport::WiFi);
  }
}
}  // namespace bridge
