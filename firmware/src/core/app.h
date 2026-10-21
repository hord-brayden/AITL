#pragma once
#include <Arduino.h>
#include <vector>

// Application state + bridge protocol handling. The UI observes this through setUiCb().
namespace app {
  struct Model  { String id, label, provider; bool ok; };
  struct Chat   { String id, title; };
  struct Action { String id, label; };
  struct CcSession { String id, title, project, age; };
  struct Alert { String id, kind, title, text, project, session; bool twoWay; };
  struct Msg { uint8_t role; String text; };   // role: 0 user, 1 assistant, 2 error
  struct OvChat { String id, title, model, age, session, state; uint16_t turns; uint32_t tok; float cost; };
  struct OvSession { String id, title, project, age, state, app; bool live; };
  struct Overview { uint32_t turns = 0, tin = 0, tout = 0; float cost = 0; uint8_t devices = 0; std::vector<OvChat> chats; std::vector<OvSession> sessions; bool valid = false; };
  struct NowPlaying { String app, state, title, artist; bool playing() const { return state == "playing"; } };
  enum class Ev : uint8_t { Transcript, Lists, Status, Link, Toast, Error, Pairing, Provisioned, Alert, AlertClear, NowPlaying, Inbox, Overview };
  typedef void (*UiCb)(Ev ev, const char* arg);

  extern std::vector<Model>  models;
  extern std::vector<Chat>   chats;
  extern std::vector<Action> actions;
  extern std::vector<CcSession> ccSessions;
  extern Alert alert;              // current alert (empty id when none)
  extern std::vector<Alert> inbox;  // recent cards, newest first (max 20)
  extern uint8_t inboxUnread;
  extern NowPlaying np;
  extern Overview ov;
  extern String lastUsage;   // "1.2k tok • $0.004 • 3.1s" of the last reply
  extern String currentModel, currentChatId, currentChatTitle, currentChatSession, bridgeName, bridgeVersion, frontApp;
  extern bool currentChatLive;   // the bound Claude Code session has a known terminal window
  extern bool dictating, streaming, hasReply, capturing;   // capturing = device mic is recording
  extern String pairFingerprint, pairCode, pairName;

  void begin();
  void tick();
  void setUiCb(UiCb cb);

  const std::vector<Msg>& messages();
  bool transcriptEmpty();
  void clearTranscript();

  void sendPrompt(const String& text);
  void stopGeneration();
  void newChat();
  void openChat(const String& id);
  void deleteChat(const String& id);
  void setModel(const String& id);
  void runAction(const String& id);
  void refreshLists();
  void listSessions();              // ask the bridge for recent Claude Code sessions
  void requestOverview();
  void nextChat();                  // cycle through recent chats (BOOT double-tap)
  void openSession(const String& id);
  void replyAlert(const char* action);  // "allow" | "deny" | "dismiss"
  void inboxMarkRead();
  void inboxClear();

  void typeToMac(const String& text);   // honours g_settings.hidTarget
  void typeToSession(const String& text, bool enter = true);   // into the terminal running the current chat's Claude Code session
  void keyToMac(const char* combo);
  void dictation(const char* op);       // "start" | "stop" | "toggle" — routes to host Mac or device mic per settings
  void captureStart(); void captureStop(bool discard = false);
  void pasteLastReply();
  void copyLastReply();
  void mediaKey(uint16_t usage);

  void startNetworkPairing();
  void confirmPairing(bool accept);
  void forgetBridge();

  String deviceId();
  String linkSummary();                 // "USB" | "WIFI" | "--"
  bool bridgeLinked();
}
