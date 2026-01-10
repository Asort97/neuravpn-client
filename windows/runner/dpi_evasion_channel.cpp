#include "dpi_evasion_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include <windows.h>

#include "ttl_phantom_injector.h"

namespace {
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

void LogDebug(const std::string& msg) {
  OutputDebugStringA((std::string("[dpi_evasion] ") + msg + "\n").c_str());
}

std::string GetStringArg(const flutter::EncodableMap& map, const std::string& key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return {};
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return {};
}

int64_t GetIntArg(const flutter::EncodableMap& map, const std::string& key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return 0;
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<int64_t>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    return static_cast<int64_t>(*value);
  }
  return 0;
}

bool GetBoolArg(const flutter::EncodableMap& map, const std::string& key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return false;
  if (const auto* value = std::get_if<bool>(&it->second)) {
    return *value;
  }
  return false;
}
}  // namespace

void SetupDpiEvasionChannel(flutter::BinaryMessenger* messenger) {
  if (g_channel) {
    return;
  }
  LogDebug("SetupDpiEvasionChannel()");
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "happycat.vpn/dpi", &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const auto& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto& method = call.method_name();
        LogDebug(std::string("MethodCall: ") + method);
        if (method == "startTtlInjector") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            LogDebug("startTtlInjector bad_args: not a map");
            result->Error("bad_args", "Expected map for startTtlInjector");
            return;
          }
          const std::string serverIp = GetStringArg(*args, "serverIp");
          const int64_t port = GetIntArg(*args, "serverPort");
          const bool enableWindowClamp =
              GetBoolArg(*args, "enableTcpWindowClamp");
          const bool enableSniRandomization =
              GetBoolArg(*args, "enableSniRandomization");
          if (serverIp.empty() || port <= 0 || port > 65535) {
            LogDebug("startTtlInjector bad_args: missing ip/port");
            result->Error("bad_args", "Missing serverIp/serverPort");
            return;
          }
          LogDebug("startTtlInjector start " + serverIp + ":" + std::to_string(port));
          const bool ok = start_ttl_phantom_injector(
              serverIp.c_str(),
              static_cast<UINT16>(port),
              enableWindowClamp,
              enableSniRandomization);
          LogDebug(std::string("startTtlInjector result ok=") + (ok ? "true" : "false"));
          result->Success(flutter::EncodableValue(ok));
          return;
        }

        if (method == "stopTtlInjector") {
          LogDebug("stopTtlInjector");
          stop_ttl_phantom_injector();
          result->Success(flutter::EncodableValue(true));
          return;
        }

        result->NotImplemented();
      });
}

void TeardownDpiEvasionChannel() {
  stop_ttl_phantom_injector();
  g_channel.reset();
}
