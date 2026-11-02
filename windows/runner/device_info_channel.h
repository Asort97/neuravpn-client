#ifndef RUNNER_DEVICE_INFO_CHANNEL_H_
#define RUNNER_DEVICE_INFO_CHANNEL_H_

#include <flutter/binary_messenger.h>

void SetupDeviceInfoChannel(flutter::BinaryMessenger* messenger);
void TeardownDeviceInfoChannel();

#endif  // RUNNER_DEVICE_INFO_CHANNEL_H_
