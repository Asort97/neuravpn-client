#include "launch_uri_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include <windows.h>

namespace {
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

void LogDebug(const std::string& message) {
  OutputDebugStringA((std::string("[launch_uri] ") + message + "\n").c_str());
}
}  // namespace

void SetupLaunchUriChannel(flutter::BinaryMessenger* messenger) {
  if (g_channel != nullptr) {
    return;
  }

  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "neuravpn/windows_launch",
      &flutter::StandardMethodCodec::GetInstance());
  LogDebug("channel ready");
}

void TeardownLaunchUriChannel() {
  g_channel.reset();
}

void DispatchLaunchUri(const std::string& payload) {
  if (g_channel == nullptr || payload.empty()) {
    return;
  }

  LogDebug("dispatching handoff payload");
  g_channel->InvokeMethod(
      "handleLaunchUri",
      std::make_unique<flutter::EncodableValue>(payload));
}

void DispatchDuplicateInstanceSignal() {
  if (g_channel == nullptr) {
    return;
  }

  LogDebug("dispatching duplicate instance signal");
  g_channel->InvokeMethod(
      "handleDuplicateInstance",
      std::make_unique<flutter::EncodableValue>(true));
}
