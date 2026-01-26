#ifndef PROCESS_SPLIT_CHANNEL_H_
#define PROCESS_SPLIT_CHANNEL_H_

#include <flutter/binary_messenger.h>

// Method channel to control WinDivert-based process split routing.
// Dart side calls start/update/stop; implementation lives in process_split_channel.cpp.
void SetupProcessSplitChannel(flutter::BinaryMessenger* messenger);
void TeardownProcessSplitChannel();

#endif  // PROCESS_SPLIT_CHANNEL_H_
