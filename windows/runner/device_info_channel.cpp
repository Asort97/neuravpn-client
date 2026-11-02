#include "device_info_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>

#include "utils.h"

namespace {
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

std::string ReadModelField(const wchar_t* name) {
  wchar_t value[512] = {};
  DWORD bytes = static_cast<DWORD>(sizeof(value));
  const auto status = RegGetValueW(
      HKEY_LOCAL_MACHINE, L"HARDWARE\\DESCRIPTION\\System\\BIOS", name,
      RRF_RT_REG_SZ | RRF_ZEROONFAILURE, nullptr, value, &bytes);
  return status == ERROR_SUCCESS ? Utf8FromUtf16(value) : std::string();
}
}  // namespace

void SetupDeviceInfoChannel(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "neuravpn/device_info",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "getDeviceInfo") {
      result->NotImplemented();
      return;
    }
    const auto manufacturer = ReadModelField(L"SystemManufacturer");
    const auto product = ReadModelField(L"SystemProductName");
    auto model = manufacturer;
    if (!model.empty() && !product.empty()) model += " ";
    model += product;
    if (model.empty()) model = "PC";
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("os"), flutter::EncodableValue("Windows")},
        {flutter::EncodableValue("model"), flutter::EncodableValue(model)},
    }));
  });
}

void TeardownDeviceInfoChannel() { g_channel.reset(); }
