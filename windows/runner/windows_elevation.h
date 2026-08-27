#ifndef RUNNER_WINDOWS_ELEVATION_H_
#define RUNNER_WINDOWS_ELEVATION_H_

#include <windows.h>

#include <optional>

// Returns nullopt when Windows cannot query the token. Callers must not treat
// an unavailable diagnostic as proof that the process is not elevated.
std::optional<bool> QueryProcessElevation(HANDLE process);
std::optional<bool> QueryProcessElevation(DWORD process_id);
std::optional<bool> QueryCurrentProcessElevation();

#endif  // RUNNER_WINDOWS_ELEVATION_H_
