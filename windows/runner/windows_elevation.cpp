#include "windows_elevation.h"

std::optional<bool> QueryProcessElevation(HANDLE process) {
  if (process == nullptr) {
    return std::nullopt;
  }

  HANDLE token = nullptr;
  if (::OpenProcessToken(process, TOKEN_QUERY, &token) == 0) {
    return std::nullopt;
  }

  TOKEN_ELEVATION elevation = {};
  DWORD returned_size = 0;
  const BOOL queried = ::GetTokenInformation(
      token, TokenElevation, &elevation, sizeof(elevation), &returned_size);
  ::CloseHandle(token);
  if (queried == 0 || returned_size < sizeof(elevation)) {
    return std::nullopt;
  }
  return elevation.TokenIsElevated != 0;
}

std::optional<bool> QueryProcessElevation(DWORD process_id) {
  if (process_id == 0) {
    return std::nullopt;
  }

  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return std::nullopt;
  }
  const auto result = QueryProcessElevation(process);
  ::CloseHandle(process);
  return result;
}

std::optional<bool> QueryCurrentProcessElevation() {
  return QueryProcessElevation(::GetCurrentProcess());
}
