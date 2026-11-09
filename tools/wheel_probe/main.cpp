// wheel_probe: reports joysticks exactly as the game's SDL sees them, so the
// launcher's wheel wizard can build an SDL gamepad mapping for a wheel.
//
//   wheel_probe list
//       JSON array: [{"guid","name","type","gamepad","axes","buttons","hats"}...]
//   wheel_probe watch <guid> <state_file> <parent_pid>
//       Rewrites <state_file> ~20x/s with {"axes":[..],"buttons":[..],"hats":[..]}
//       until the parent process exits (or 30 minutes pass).
//
// Uses SDL's default hints, like the game, so GUIDs match what the game sees.
#include <SDL3/SDL.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace {

std::string JsonString(const char* s) {
  std::string out = "\"";
  for (const char* p = s ? s : ""; *p; ++p) {
    unsigned char c = static_cast<unsigned char>(*p);
    if (c == '"' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c < 0x20) {
      char buf[8];
      std::snprintf(buf, sizeof(buf), "\\u%04x", c);
      out += buf;
    } else {
      out += static_cast<char>(c);
    }
  }
  return out + "\"";
}

const char* TypeName(SDL_JoystickType t) {
  switch (t) {
    case SDL_JOYSTICK_TYPE_GAMEPAD: return "gamepad";
    case SDL_JOYSTICK_TYPE_WHEEL: return "wheel";
    case SDL_JOYSTICK_TYPE_ARCADE_STICK: return "arcade_stick";
    case SDL_JOYSTICK_TYPE_FLIGHT_STICK: return "flight_stick";
    case SDL_JOYSTICK_TYPE_DANCE_PAD: return "dance_pad";
    case SDL_JOYSTICK_TYPE_GUITAR: return "guitar";
    case SDL_JOYSTICK_TYPE_DRUM_KIT: return "drum_kit";
    case SDL_JOYSTICK_TYPE_ARCADE_PAD: return "arcade_pad";
    case SDL_JOYSTICK_TYPE_THROTTLE: return "throttle";
    default: return "unknown";
  }
}

std::string GuidString(SDL_GUID guid) {
  char buf[64] = {};
  SDL_GUIDToString(guid, buf, sizeof(buf));
  return buf;
}

// Give backends time to enumerate devices.
void Settle() {
  for (int i = 0; i < 20; ++i) {
    SDL_PumpEvents();
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
}

bool ParentAlive(unsigned long pid) {
#ifdef _WIN32
  if (!pid) return true;
  HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (!h) return false;
  DWORD r = WaitForSingleObject(h, 0);
  CloseHandle(h);
  return r == WAIT_TIMEOUT;
#else
  (void)pid;
  return true;
#endif
}

int List() {
  int count = 0;
  SDL_JoystickID* ids = SDL_GetJoysticks(&count);
  std::printf("[");
  for (int i = 0; i < count; ++i) {
    SDL_Joystick* j = SDL_OpenJoystick(ids[i]);
    int axes = j ? SDL_GetNumJoystickAxes(j) : 0;
    int buttons = j ? SDL_GetNumJoystickButtons(j) : 0;
    int hats = j ? SDL_GetNumJoystickHats(j) : 0;
    std::printf("%s{\"guid\":%s,\"name\":%s,\"type\":\"%s\",\"gamepad\":%s,"
                "\"axes\":%d,\"buttons\":%d,\"hats\":%d}",
                i ? "," : "", JsonString(GuidString(SDL_GetJoystickGUIDForID(ids[i])).c_str()).c_str(),
                JsonString(SDL_GetJoystickNameForID(ids[i])).c_str(),
                TypeName(SDL_GetJoystickTypeForID(ids[i])),
                SDL_IsGamepad(ids[i]) ? "true" : "false", axes, buttons, hats);
    if (j) SDL_CloseJoystick(j);
  }
  std::printf("]\n");
  SDL_free(ids);
  return 0;
}

int Watch(const std::string& guid, const std::filesystem::path& out, unsigned long parent) {
  int count = 0;
  SDL_JoystickID* ids = SDL_GetJoysticks(&count);
  SDL_Joystick* joy = nullptr;
  for (int i = 0; i < count && !joy; ++i) {
    if (GuidString(SDL_GetJoystickGUIDForID(ids[i])) == guid) joy = SDL_OpenJoystick(ids[i]);
  }
  SDL_free(ids);
  if (!joy) {
    std::fprintf(stderr, "joystick %s not found\n", guid.c_str());
    return 2;
  }
  const int axes = SDL_GetNumJoystickAxes(joy);
  const int buttons = SDL_GetNumJoystickButtons(joy);
  const int hats = SDL_GetNumJoystickHats(joy);
  const auto tmp = std::filesystem::path(out).concat(".tmp");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::minutes(30);

  while (ParentAlive(parent) && std::chrono::steady_clock::now() < deadline) {
    SDL_PumpEvents();
    SDL_UpdateJoysticks();
    std::string s = "{\"axes\":[";
    for (int a = 0; a < axes; ++a) {
      s += (a ? "," : "") + std::to_string(SDL_GetJoystickAxis(joy, a));
    }
    s += "],\"buttons\":[";
    for (int b = 0; b < buttons; ++b) {
      s += (b ? "," : "") + std::to_string(SDL_GetJoystickButton(joy, b) ? 1 : 0);
    }
    s += "],\"hats\":[";
    for (int h = 0; h < hats; ++h) {
      s += (h ? "," : "") + std::to_string(SDL_GetJoystickHat(joy, h));
    }
    s += "]}\n";
    {
      std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
      f << s;
    }
    std::error_code ec;
    std::filesystem::rename(tmp, out, ec);  // replace atomically-ish
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  SDL_CloseJoystick(joy);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  // Read input even though this console tool has no focused window.
  SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
  if (!SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD)) {
    std::fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
    return 1;
  }
  Settle();
  int rc = 1;
  const std::string cmd = argc > 1 ? argv[1] : "";
  if (cmd == "list") {
    rc = List();
  } else if (cmd == "watch" && argc >= 4) {
    rc = Watch(argv[2], argv[3], argc >= 5 ? std::strtoul(argv[4], nullptr, 10) : 0);
  } else {
    std::fprintf(stderr, "usage: wheel_probe list | watch <guid> <state_file> [parent_pid]\n");
  }
  SDL_Quit();
  return rc;
}
