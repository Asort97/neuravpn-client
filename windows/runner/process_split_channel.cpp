#include "process_split_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <TlHelp32.h>

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")

namespace {
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

struct TargetConfig {
  std::set<DWORD> pids;
  bool whitelist = true;
  UINT32 direct_ifidx = 0;
};

TargetConfig g_config;
std::mutex g_config_mutex;

HMODULE g_windivert_module = nullptr;
std::thread g_worker;
std::atomic_bool g_stop{false};
HANDLE g_handle = INVALID_HANDLE_VALUE;

typedef enum { WINDIVERT_LAYER_NETWORK = 0 } WINDIVERT_LAYER;
typedef enum {
  WINDIVERT_FLAG_SNIFF = 1,
} WINDIVERT_FLAG;

typedef struct {
  UINT32 IfIdx;
  UINT32 SubIfIdx;
} WINDIVERT_DATA_NETWORK;

typedef struct {
  INT64 Timestamp;
  UINT32 Layer : 8;
  UINT32 Event : 8;
  UINT32 Sniffed : 1;
  UINT32 Outbound : 1;
  UINT32 Loopback : 1;
  UINT32 Impostor : 1;
  UINT32 IPv6 : 1;
  UINT32 IPChecksum : 1;
  UINT32 TCPChecksum : 1;
  UINT32 UDPChecksum : 1;
  UINT32 Reserved1 : 8;
  UINT32 Reserved2;
  union {
    WINDIVERT_DATA_NETWORK Network;
    UINT8 Reserved3[64];
  };
  UINT32 ProcessId;
  UINT32 EndpointId;
} WINDIVERT_ADDRESS;

typedef HANDLE(WINAPI* WinDivertOpen_t)(
    const char* filter, WINDIVERT_LAYER layer, INT16 priority, UINT64 flags);
typedef BOOL(WINAPI* WinDivertRecv_t)(HANDLE handle,
                                      VOID* pPacket,
                                      UINT packetLen,
                                      UINT* pRecvLen,
                                      WINDIVERT_ADDRESS* pAddr);
typedef BOOL(WINAPI* WinDivertSend_t)(HANDLE handle,
                                      const VOID* pPacket,
                                      UINT packetLen,
                                      UINT* pSendLen,
                                      const WINDIVERT_ADDRESS* pAddr);
typedef BOOL(WINAPI* WinDivertShutdown_t)(HANDLE handle, UINT64 how);
typedef BOOL(WINAPI* WinDivertClose_t)(HANDLE handle);
typedef VOID(WINAPI* WinDivertHelperCalcChecksums_t)(
    PVOID pPacket, UINT packetLen, WINDIVERT_ADDRESS* pAddr, UINT64 flags);

WinDivertOpen_t WinDivertOpenPtr = nullptr;
WinDivertRecv_t WinDivertRecvPtr = nullptr;
WinDivertSend_t WinDivertSendPtr = nullptr;
WinDivertShutdown_t WinDivertShutdownPtr = nullptr;
WinDivertClose_t WinDivertClosePtr = nullptr;
WinDivertHelperCalcChecksums_t WinDivertHelperCalcChecksumsPtr = nullptr;

void LogDebug(const std::string& msg) {
  const std::string line = "[process_split] " + msg + "\n";
  OutputDebugStringA(line.c_str());
  fprintf(stderr, "%s", line.c_str());
}

bool LoadWinDivert() {
  if (WinDivertOpenPtr) return true;
  if (!g_windivert_module) {
    g_windivert_module = LoadLibraryW(L"WinDivert.dll");
  }
  if (!g_windivert_module) {
    LogDebug("WinDivert.dll not loaded");
    return false;
  }
  WinDivertOpenPtr = reinterpret_cast<WinDivertOpen_t>(
      GetProcAddress(g_windivert_module, "WinDivertOpen"));
  WinDivertRecvPtr = reinterpret_cast<WinDivertRecv_t>(
      GetProcAddress(g_windivert_module, "WinDivertRecv"));
  WinDivertSendPtr = reinterpret_cast<WinDivertSend_t>(
      GetProcAddress(g_windivert_module, "WinDivertSend"));
  WinDivertShutdownPtr = reinterpret_cast<WinDivertShutdown_t>(
      GetProcAddress(g_windivert_module, "WinDivertShutdown"));
  WinDivertClosePtr = reinterpret_cast<WinDivertClose_t>(
      GetProcAddress(g_windivert_module, "WinDivertClose"));
  WinDivertHelperCalcChecksumsPtr =
      reinterpret_cast<WinDivertHelperCalcChecksums_t>(
          GetProcAddress(g_windivert_module, "WinDivertHelperCalcChecksums"));

  const bool ok = WinDivertOpenPtr && WinDivertRecvPtr && WinDivertSendPtr &&
                  WinDivertShutdownPtr && WinDivertClosePtr &&
                  WinDivertHelperCalcChecksumsPtr;
  if (!ok) {
    LogDebug("WinDivert symbols missing");
  }
  return ok;
}

std::wstring ToWide(const std::string& s) {
  if (s.empty()) return L"";
  const int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (len <= 0) return L"";
  std::wstring ws(len - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &ws[0], len);
  return ws;
}

std::string ToLower(const std::string& s) {
  std::string r = s;
  for (auto& c : r) c = static_cast<char>(::tolower(c));
  return r;
}

bool GetProcessPath(DWORD pid, std::string& out_path) {
  const HANDLE h =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, FALSE,
                  pid);
  if (!h) return false;
  wchar_t buffer[MAX_PATH];
  DWORD size = MAX_PATH;
  bool ok = false;
  if (QueryFullProcessImageNameW(h, 0, buffer, &size)) {
    std::wstring ws(buffer, size);
    int len = WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1, nullptr, 0,
                                  nullptr, nullptr);
    if (len > 0) {
      std::string utf8(len - 1, '\0');
      WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1, &utf8[0], len, nullptr,
                          nullptr);
      out_path = ToLower(utf8);
      ok = true;
    }
  }
  CloseHandle(h);
  return ok;
}

std::set<DWORD> ResolvePids(const std::vector<std::string>& apps) {
  std::set<DWORD> result;
  if (apps.empty()) return result;

  std::vector<std::string> paths;
  std::vector<std::string> names;
  paths.reserve(apps.size());
  names.reserve(apps.size());
  for (const auto& a : apps) {
    const auto lower = ToLower(a);
    if (lower.find('\\') != std::string::npos ||
        lower.find('/') != std::string::npos) {
      paths.push_back(lower);
      const size_t pos = lower.find_last_of("\\/");
      if (pos != std::string::npos && pos + 1 < lower.size()) {
        names.push_back(lower.substr(pos + 1));
      }
    } else {
      names.push_back(lower);
    }
  }

  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return result;
  PROCESSENTRY32W pe;
  pe.dwSize = sizeof(pe);
  if (Process32FirstW(snap, &pe)) {
    do {
      std::wstring exe(pe.szExeFile);
      int len =
          WideCharToMultiByte(CP_UTF8, 0, exe.c_str(), -1, nullptr, 0, nullptr,
                              nullptr);
      std::string exeLower;
      if (len > 0) {
        exeLower.resize(len - 1);
        WideCharToMultiByte(CP_UTF8, 0, exe.c_str(), -1, &exeLower[0], len,
                            nullptr, nullptr);
        exeLower = ToLower(exeLower);
      }
      std::string fullPath;
      const bool hasPath = GetProcessPath(pe.th32ProcessID, fullPath);

      bool match = false;
      if (hasPath && std::find(paths.begin(), paths.end(), fullPath) !=
                         paths.end()) {
        match = true;
      }
      if (!match &&
          std::find(names.begin(), names.end(), exeLower) != names.end()) {
        match = true;
      }
      if (match) {
        result.insert(pe.th32ProcessID);
      }
    } while (Process32NextW(snap, &pe));
  }
  CloseHandle(snap);
  return result;
}

UINT32 GetDefaultInterface() {
  ULONG idx = 0;
  DWORD res = GetBestInterface(0, &idx);
  if (res == NO_ERROR) return idx;

  ULONG bufLen = 15 * 1024;
  std::vector<IP_ADAPTER_ADDRESSES> adapters(bufLen / sizeof(IP_ADAPTER_ADDRESSES));
  ULONG outLen = bufLen;
  res = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                                           GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_SKIP_FRIENDLY_NAME,
                             nullptr, adapters.data(), &outLen);
  if (res == ERROR_BUFFER_OVERFLOW) {
    adapters.resize(outLen / sizeof(IP_ADAPTER_ADDRESSES) + 1);
    res = GetAdaptersAddresses(AF_UNSPEC,
                               GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                                   GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_SKIP_FRIENDLY_NAME,
                               nullptr, adapters.data(), &outLen);
  }
  if (res != NO_ERROR) return 0;

  IP_ADAPTER_ADDRESSES* aa = adapters.data();
  while (aa) {
    if (aa->IfType != IF_TYPE_SOFTWARE_LOOPBACK &&
        !(aa->OperStatus == IfOperStatusUp && aa->IfIndex == 0)) {
      const std::wstring name = aa->FriendlyName ? aa->FriendlyName : L"";
      if (name.find(L"wintun") == std::wstring::npos &&
          name.find(L"TAP") == std::wstring::npos) {
        return aa->IfIndex;
      }
    }
    aa = aa->Next;
  }
  return 0;
}

void WorkerLoop() {
  const UINT bufSize = 0xFFFF;
  std::vector<char> packet(bufSize);
  WINDIVERT_ADDRESS addr;

  while (!g_stop.load()) {
    UINT recvLen = 0;
    if (!WinDivertRecvPtr(g_handle, packet.data(), bufSize, &recvLen, &addr)) {
      const DWORD err = GetLastError();
      if (err == ERROR_OPERATION_ABORTED || g_stop.load()) break;
      continue;
    }

    TargetConfig cfg;
    {
      std::lock_guard<std::mutex> lock(g_config_mutex);
      cfg = g_config;
    }

    const DWORD pid = addr.ProcessId;
    const bool inList = cfg.pids.find(pid) != cfg.pids.end();
    const bool allowVpn = cfg.whitelist ? inList : !inList;

    if (!allowVpn && cfg.direct_ifidx != 0) {
      addr.Network.IfIdx = cfg.direct_ifidx;
      addr.Network.SubIfIdx = 0;
      WinDivertHelperCalcChecksumsPtr(packet.data(), recvLen, &addr, 0);
    }

    WinDivertSendPtr(g_handle, packet.data(), recvLen, nullptr, &addr);
  }
}

void StopWorker() {
  g_stop.store(true);
  HANDLE h = INVALID_HANDLE_VALUE;
  {
    std::lock_guard<std::mutex> lock(g_config_mutex);
    h = g_handle;
  }
  if (h != INVALID_HANDLE_VALUE && WinDivertShutdownPtr) {
    WinDivertShutdownPtr(h, 3);
  }
  if (g_worker.joinable()) g_worker.join();
  if (h != INVALID_HANDLE_VALUE && WinDivertClosePtr) {
    WinDivertClosePtr(h);
  }
  {
    std::lock_guard<std::mutex> lock(g_config_mutex);
    g_handle = INVALID_HANDLE_VALUE;
    g_config.pids.clear();
  }
}

bool StartWorker(bool whitelist, const std::vector<std::string>& apps) {
  StopWorker();
  if (!LoadWinDivert()) return false;
  const auto pids = ResolvePids(apps);
  TargetConfig cfg;
  cfg.whitelist = whitelist;
  cfg.pids = pids;
  cfg.direct_ifidx = GetDefaultInterface();

  HANDLE handle =
      WinDivertOpenPtr("true", WINDIVERT_LAYER_NETWORK, 0, 0);
  if (handle == INVALID_HANDLE_VALUE) {
    LogDebug("WinDivertOpen failed");
    return false;
  }

  {
    std::lock_guard<std::mutex> lock(g_config_mutex);
    g_config = cfg;
    g_handle = handle;
  }
  g_stop.store(false);
  g_worker = std::thread(WorkerLoop);
  return true;
}

void UpdateConfig(bool whitelist, const std::vector<std::string>& apps) {
  const auto pids = ResolvePids(apps);
  const UINT32 ifidx = GetDefaultInterface();
  std::lock_guard<std::mutex> lock(g_config_mutex);
  g_config.whitelist = whitelist;
  g_config.pids = pids;
  g_config.direct_ifidx = ifidx;
}

std::vector<std::string> GetStringListArg(
    const flutter::EncodableMap& map, const std::string& key) {
  std::vector<std::string> out;
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return out;
  if (const auto* list = std::get_if<flutter::EncodableList>(&it->second)) {
    for (const auto& v : *list) {
      if (const auto* s = std::get_if<std::string>(&v)) {
        if (!s->empty()) out.push_back(*s);
      }
    }
  }
  return out;
}

bool GetWhitelistArg(const flutter::EncodableMap& map) {
  const auto it = map.find(flutter::EncodableValue("mode"));
  if (it == map.end()) return true;
  if (const auto* s = std::get_if<std::string>(&it->second)) {
    return *s != "blacklist";
  }
  return true;
}

}  // namespace

void SetupProcessSplitChannel(flutter::BinaryMessenger* messenger) {
  if (g_channel) return;
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "happycat.vpn/process_split",
      &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const auto& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto& method = call.method_name();
        if (method == "startProcessSplit") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("bad_args", "Expected map");
            return;
          }
          const bool whitelist = GetWhitelistArg(*args);
          const auto apps = GetStringListArg(*args, "apps");
          const bool ok = StartWorker(whitelist, apps);
          result->Success(flutter::EncodableValue(ok));
          return;
        }
        if (method == "updateProcessSplit") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("bad_args", "Expected map");
            return;
          }
          const bool whitelist = GetWhitelistArg(*args);
          const auto apps = GetStringListArg(*args, "apps");
          UpdateConfig(whitelist, apps);
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "stopProcessSplit") {
          StopWorker();
          result->Success(flutter::EncodableValue(true));
          return;
        }
        result->NotImplemented();
      });
}

void TeardownProcessSplitChannel() {
  StopWorker();
  g_channel.reset();
}
