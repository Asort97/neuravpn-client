#pragma once

#include <flutter/binary_messenger.h>

#include <string>

#include <windows.h>

inline constexpr ULONG_PTR kLaunchUriCopyDataId = 0x4E56555249554C31ULL;
inline constexpr ULONG_PTR kDuplicateInstanceCopyDataId = 0x4E56445550494E53ULL;

void SetupLaunchUriChannel(flutter::BinaryMessenger* messenger);
void TeardownLaunchUriChannel();
void DispatchLaunchUri(const std::string& payload);
void DispatchDuplicateInstanceSignal();
