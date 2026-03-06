#pragma once

#include <flutter/binary_messenger.h>

#include <string>

#include <windows.h>

inline constexpr ULONG_PTR kLaunchUriCopyDataId = 0x4E56555249554C31ULL;

void SetupLaunchUriChannel(flutter::BinaryMessenger* messenger);
void TeardownLaunchUriChannel();
void DispatchLaunchUri(const std::string& payload);
