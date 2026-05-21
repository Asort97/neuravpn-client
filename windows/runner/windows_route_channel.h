#pragma once

#include <flutter/binary_messenger.h>

void SetupWindowsRouteChannel(flutter::BinaryMessenger* messenger);
void TeardownWindowsRouteChannel();
