#include "windows_route_channel.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "utils.h"
#include "windows_elevation.h"

namespace {
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

// Keep these low enough to beat the physical default route. Cleanup matches
// the full tuple (interface, next hop and metric), so it never wipes a route
// that belongs to the user or another VPN client.
constexpr uint32_t kProtectedRouteMetric = 4;
constexpr uint32_t kTunDefaultRouteMetric = 5;

void LogDebug(const std::string& message) {
  OutputDebugStringA((std::string("[windows_route] ") + message + "\n").c_str());
}

struct UplinkInfo {
  std::string interface_name;
  uint32_t interface_index = 0;
  std::string gateway;
  std::string local_address;
  uint32_t route_metric = 0;
  uint32_t interface_metric = 0;
};

struct TunInfo {
  std::string name;
  uint32_t interface_index = 0;
};

std::string IpToString(const IN_ADDR& address) {
  char buffer[INET_ADDRSTRLEN] = {};
  if (inet_ntop(AF_INET, &address, buffer, sizeof(buffer)) == nullptr) {
    return {};
  }
  return std::string(buffer);
}

std::optional<IN_ADDR> ParseIpv4(const std::string& value) {
  IN_ADDR address = {};
  if (inet_pton(AF_INET, value.c_str(), &address) != 1) {
    return std::nullopt;
  }
  return address;
}

bool IsBadLocalAddress(const IN_ADDR& address) {
  const uint32_t host = ntohl(address.S_un.S_addr);
  return host == 0 || (host >> 24) == 127 ||
         ((host >> 16) & 0xffff) == 0xa9fe;  // 169.254/16
}

bool SameIpv4(const SOCKADDR_INET& value, const IN_ADDR& expected) {
  return value.si_family == AF_INET &&
         value.Ipv4.sin_addr.S_un.S_addr == expected.S_un.S_addr;
}

bool PrefixMatches(const MIB_IPFORWARD_ROW2& row, const IN_ADDR& address,
                   uint8_t prefix_length) {
  return row.DestinationPrefix.Prefix.si_family == AF_INET &&
         row.DestinationPrefix.PrefixLength == prefix_length &&
         row.DestinationPrefix.Prefix.Ipv4.sin_addr.S_un.S_addr ==
             address.S_un.S_addr;
}

std::string InterfaceAlias(uint32_t interface_index) {
  MIB_IF_ROW2 row = {};
  row.InterfaceIndex = interface_index;
  if (GetIfEntry2(&row) != NO_ERROR) {
    return {};
  }
  return Utf8FromUtf16(row.Alias);
}

uint32_t InterfaceMetric(uint32_t interface_index) {
  MIB_IPINTERFACE_ROW row = {};
  InitializeIpInterfaceEntry(&row);
  row.Family = AF_INET;
  row.InterfaceIndex = interface_index;
  if (GetIpInterfaceEntry(&row) != NO_ERROR) {
    return 9999;
  }
  return row.Metric;
}

bool InterfaceIsUsable(uint32_t interface_index) {
  MIB_IF_ROW2 row = {};
  row.InterfaceIndex = interface_index;
  if (GetIfEntry2(&row) != NO_ERROR) {
    return false;
  }
  if (row.Type == IF_TYPE_SOFTWARE_LOOPBACK) {
    return false;
  }
  return row.OperStatus == IfOperStatusUp;
}

std::optional<std::string> LocalAddressForInterface(uint32_t interface_index) {
  MIB_UNICASTIPADDRESS_TABLE* table = nullptr;
  if (GetUnicastIpAddressTable(AF_INET, &table) != NO_ERROR || table == nullptr) {
    return std::nullopt;
  }

  const MIB_UNICASTIPADDRESS_ROW* best = nullptr;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const auto& row = table->Table[i];
    if (row.InterfaceIndex != interface_index ||
        row.Address.si_family != AF_INET ||
        IsBadLocalAddress(row.Address.Ipv4.sin_addr)) {
      continue;
    }
    if (best == nullptr) {
      best = &row;
      continue;
    }
    if (best->SkipAsSource && !row.SkipAsSource) {
      best = &row;
      continue;
    }
    if (best->SkipAsSource == row.SkipAsSource &&
        row.OnLinkPrefixLength > best->OnLinkPrefixLength) {
      best = &row;
    }
  }

  std::optional<std::string> result;
  if (best != nullptr) {
    result = IpToString(best->Address.Ipv4.sin_addr);
  }
  FreeMibTable(table);
  return result;
}

std::optional<UplinkInfo> DiscoverPrimaryUplinkNative() {
  MIB_IPFORWARD_TABLE2* table = nullptr;
  if (GetIpForwardTable2(AF_INET, &table) != NO_ERROR || table == nullptr) {
    return std::nullopt;
  }

  std::vector<UplinkInfo> candidates;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const auto& row = table->Table[i];
    if (row.DestinationPrefix.PrefixLength != 0 ||
        row.NextHop.si_family != AF_INET ||
        row.NextHop.Ipv4.sin_addr.S_un.S_addr == 0 ||
        !InterfaceIsUsable(row.InterfaceIndex)) {
      continue;
    }
    const auto local = LocalAddressForInterface(row.InterfaceIndex);
    if (!local.has_value()) {
      continue;
    }
    UplinkInfo item;
    item.interface_index = row.InterfaceIndex;
    item.interface_name = InterfaceAlias(row.InterfaceIndex);
    item.gateway = IpToString(row.NextHop.Ipv4.sin_addr);
    item.local_address = local.value();
    item.route_metric = row.Metric;
    item.interface_metric = InterfaceMetric(row.InterfaceIndex);
    if (!item.interface_name.empty() && !item.gateway.empty()) {
      candidates.push_back(item);
    }
  }
  FreeMibTable(table);

  if (candidates.empty()) {
    return std::nullopt;
  }
  std::sort(candidates.begin(), candidates.end(),
            [](const UplinkInfo& a, const UplinkInfo& b) {
              if (a.route_metric != b.route_metric) {
                return a.route_metric < b.route_metric;
              }
              return a.interface_metric < b.interface_metric;
            });
  return candidates.front();
}

int TunPriority(const std::string& name, const std::string& preferred) {
  if (!preferred.empty() && name == preferred) return 0;
  if (name == "xray0") return 1;
  if (name.rfind("xray", 0) == 0) return 2;
  if (name.rfind("tun-in", 0) == 0) return 3;
  if (name.rfind("wintun", 0) == 0) return 4;
  return 99;
}

std::optional<TunInfo> FindTunInterfaceNative(const std::string& preferred) {
  MIB_IF_TABLE2* table = nullptr;
  if (GetIfTable2(&table) != NO_ERROR || table == nullptr) {
    return std::nullopt;
  }

  std::optional<TunInfo> selected;
  int selected_priority = 100;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const auto& row = table->Table[i];
    const std::string name = Utf8FromUtf16(row.Alias);
    const int priority = TunPriority(name, preferred);
    if (priority >= selected_priority || priority >= 99) {
      continue;
    }
    selected = TunInfo{name, row.InterfaceIndex};
    selected_priority = priority;
  }
  FreeMibTable(table);
  return selected;
}

std::optional<std::string> AdapterStatusNative(const std::string& name) {
  MIB_IF_TABLE2* table = nullptr;
  if (GetIfTable2(&table) != NO_ERROR || table == nullptr) {
    return std::nullopt;
  }

  std::optional<std::string> status;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const auto& row = table->Table[i];
    if (Utf8FromUtf16(row.Alias) != name) {
      continue;
    }
    switch (row.OperStatus) {
      case IfOperStatusUp:
        status = "up";
        break;
      case IfOperStatusDown:
        status = "down";
        break;
      default:
        status = "unknown";
        break;
    }
    break;
  }
  FreeMibTable(table);
  return status;
}

void DeleteMatchingRoutes(uint32_t interface_index, const IN_ADDR& destination,
                          uint8_t prefix_length,
                          const std::optional<IN_ADDR>& next_hop,
                          const std::optional<uint32_t>& metric =
                              std::nullopt) {
  MIB_IPFORWARD_TABLE2* table = nullptr;
  if (GetIpForwardTable2(AF_INET, &table) != NO_ERROR || table == nullptr) {
    return;
  }
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    auto row = table->Table[i];
    if (row.InterfaceIndex != interface_index ||
        !PrefixMatches(row, destination, prefix_length)) {
      continue;
    }
    if (next_hop.has_value() && !SameIpv4(row.NextHop, next_hop.value())) {
      continue;
    }
    if (metric.has_value() && row.Metric != metric.value()) {
      continue;
    }
    DeleteIpForwardEntry2(&row);
  }
  FreeMibTable(table);
}

DWORD CreateIpv4Route(uint32_t interface_index, const IN_ADDR& destination,
                      uint8_t prefix_length, const IN_ADDR& next_hop,
                      uint32_t metric) {
  MIB_IPFORWARD_ROW2 row = {};
  InitializeIpForwardEntry(&row);
  row.InterfaceIndex = interface_index;
  row.DestinationPrefix.Prefix.si_family = AF_INET;
  row.DestinationPrefix.Prefix.Ipv4.sin_family = AF_INET;
  row.DestinationPrefix.Prefix.Ipv4.sin_addr = destination;
  row.DestinationPrefix.PrefixLength = prefix_length;
  row.NextHop.si_family = AF_INET;
  row.NextHop.Ipv4.sin_family = AF_INET;
  row.NextHop.Ipv4.sin_addr = next_hop;
  row.Metric = metric;
  row.Protocol = MIB_IPPROTO_NETMGMT;
  const DWORD status = CreateIpForwardEntry2(&row);
  if (status == ERROR_OBJECT_ALREADY_EXISTS) {
    return NO_ERROR;
  }
  return status;
}

void DeleteApipaAddresses(uint32_t interface_index) {
  MIB_UNICASTIPADDRESS_TABLE* table = nullptr;
  if (GetUnicastIpAddressTable(AF_INET, &table) != NO_ERROR ||
      table == nullptr) {
    return;
  }
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    auto row = table->Table[i];
    if (row.InterfaceIndex != interface_index ||
        row.Address.si_family != AF_INET) {
      continue;
    }
    const uint32_t host = ntohl(row.Address.Ipv4.sin_addr.S_un.S_addr);
    if (((host >> 16) & 0xffff) == 0xa9fe) {
      DeleteUnicastIpAddressEntry(&row);
    }
  }
  FreeMibTable(table);
}

bool HasUnicastAddress(uint32_t interface_index, const IN_ADDR& address) {
  MIB_UNICASTIPADDRESS_TABLE* table = nullptr;
  if (GetUnicastIpAddressTable(AF_INET, &table) != NO_ERROR ||
      table == nullptr) {
    return false;
  }
  bool found = false;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const auto& row = table->Table[i];
    if (row.InterfaceIndex == interface_index &&
        row.Address.si_family == AF_INET &&
        row.Address.Ipv4.sin_addr.S_un.S_addr == address.S_un.S_addr) {
      found = true;
      break;
    }
  }
  FreeMibTable(table);
  return found;
}

DWORD EnsureUnicastAddress(uint32_t interface_index, const IN_ADDR& address,
                           uint8_t prefix_length) {
  if (HasUnicastAddress(interface_index, address)) {
    return NO_ERROR;
  }
  DeleteApipaAddresses(interface_index);

  MIB_UNICASTIPADDRESS_ROW row = {};
  InitializeUnicastIpAddressEntry(&row);
  row.InterfaceIndex = interface_index;
  row.Address.si_family = AF_INET;
  row.Address.Ipv4.sin_family = AF_INET;
  row.Address.Ipv4.sin_addr = address;
  row.OnLinkPrefixLength = prefix_length;
  row.SkipAsSource = false;
  row.DadState = IpDadStatePreferred;

  const DWORD status = CreateUnicastIpAddressEntry(&row);
  if (status == ERROR_OBJECT_ALREADY_EXISTS) {
    return NO_ERROR;
  }
  return status;
}

DWORD EnsureUnicastAddressWithRetry(uint32_t interface_index,
                                    const IN_ADDR& address,
                                    uint8_t prefix_length) {
  DWORD status = NO_ERROR;
  for (int attempt = 0; attempt < 8; ++attempt) {
    status = EnsureUnicastAddress(interface_index, address, prefix_length);
    if (status == NO_ERROR) {
      return NO_ERROR;
    }
    Sleep(attempt < 2 ? 25 : 50);
  }
  return status;
}

DWORD CreateIpv4RouteWithRetry(uint32_t interface_index,
                               const IN_ADDR& destination,
                               uint8_t prefix_length,
                               const IN_ADDR& next_hop, uint32_t metric) {
  DWORD status = NO_ERROR;
  for (int attempt = 0; attempt < 6; ++attempt) {
    status = CreateIpv4Route(interface_index, destination, prefix_length,
                             next_hop, metric);
    if (status == NO_ERROR) {
      return NO_ERROR;
    }
    Sleep(attempt < 2 ? 25 : 50);
  }
  return status;
}

flutter::EncodableMap ErrorMap(const std::string& error, DWORD code = 0) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("success")] = flutter::EncodableValue(false);
  map[flutter::EncodableValue("error")] = flutter::EncodableValue(error);
  if (code != 0) {
    map[flutter::EncodableValue("code")] =
        flutter::EncodableValue(static_cast<int64_t>(code));
  }
  return map;
}

flutter::EncodableMap UplinkMap(const UplinkInfo& uplink) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("success")] = flutter::EncodableValue(true);
  map[flutter::EncodableValue("interfaceName")] =
      flutter::EncodableValue(uplink.interface_name);
  map[flutter::EncodableValue("interfaceIndex")] =
      flutter::EncodableValue(static_cast<int64_t>(uplink.interface_index));
  map[flutter::EncodableValue("gateway")] =
      flutter::EncodableValue(uplink.gateway);
  map[flutter::EncodableValue("localAddress")] =
      flutter::EncodableValue(uplink.local_address);
  return map;
}

std::string GetStringArg(const flutter::EncodableMap& map,
                         const std::string& key) {
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
  return 0;
}

std::vector<std::string> GetStringListArg(const flutter::EncodableMap& map,
                                          const std::string& key) {
  std::vector<std::string> result;
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return result;
  const auto* list = std::get_if<flutter::EncodableList>(&it->second);
  if (list == nullptr) return result;
  for (const auto& item : *list) {
    if (const auto* value = std::get_if<std::string>(&item)) {
      result.push_back(*value);
    }
  }
  return result;
}

flutter::EncodableMap ApplyRoutesNative(const flutter::EncodableMap& args) {
  const std::string preferred = GetStringArg(args, "preferredTunInterface");
  const std::string tun_address_raw = GetStringArg(args, "tunAddress");
  const auto tun_address = ParseIpv4(tun_address_raw);
  if (!tun_address.has_value()) {
    return ErrorMap("bad_tun_address");
  }

  const auto uplink_gateway = ParseIpv4(GetStringArg(args, "uplinkGateway"));
  if (!uplink_gateway.has_value()) {
    return ErrorMap("bad_uplink_gateway");
  }

  const uint32_t uplink_index =
      static_cast<uint32_t>(GetIntArg(args, "uplinkInterfaceIndex"));
  if (uplink_index == 0) {
    return ErrorMap("bad_uplink_index");
  }
  int64_t prefix_raw = GetIntArg(args, "tunPrefixLength");
  if (prefix_raw <= 0 || prefix_raw > 32) {
    prefix_raw = 30;
  }
  const auto tun_prefix_length = static_cast<uint8_t>(prefix_raw);

  const auto tun = FindTunInterfaceNative(preferred);
  if (!tun.has_value()) {
    return ErrorMap("tun_not_found");
  }

  DWORD status = EnsureUnicastAddressWithRetry(
      tun->interface_index, tun_address.value(), tun_prefix_length);
  if (status != NO_ERROR) {
    return ErrorMap("tun_address_assign_failed", status);
  }
  const auto protected_prefixes = GetStringListArg(args, "protectedPrefixes");
  const auto cleanup_owned_routes = [&]() {
    for (const auto& prefix : protected_prefixes) {
      const auto address = ParseIpv4(prefix);
      if (address.has_value()) {
        DeleteMatchingRoutes(uplink_index, address.value(), 32,
                             uplink_gateway, kProtectedRouteMetric);
      }
    }
    IN_ADDR zero = {};
    DeleteMatchingRoutes(tun->interface_index, zero, 0, zero,
                         kTunDefaultRouteMetric);
  };
  for (const auto& prefix : protected_prefixes) {
    const auto address = ParseIpv4(prefix);
    if (!address.has_value()) {
      continue;
    }
    DeleteMatchingRoutes(uplink_index, address.value(), 32, uplink_gateway,
                         kProtectedRouteMetric);
    status = CreateIpv4RouteWithRetry(uplink_index, address.value(), 32,
                                      uplink_gateway.value(),
                                      kProtectedRouteMetric);
    if (status != NO_ERROR) {
      cleanup_owned_routes();
      return ErrorMap("protected_route_failed", status);
    }
  }

  IN_ADDR zero = {};
  DeleteMatchingRoutes(tun->interface_index, zero, 0, zero,
                       kTunDefaultRouteMetric);

  status = CreateIpv4RouteWithRetry(tun->interface_index, zero, 0, zero,
                                     kTunDefaultRouteMetric);
  if (status != NO_ERROR) {
    cleanup_owned_routes();
    return ErrorMap("default_route_failed", status);
  }

  flutter::EncodableMap map;
  map[flutter::EncodableValue("success")] = flutter::EncodableValue(true);
  map[flutter::EncodableValue("tunInterfaceName")] =
      flutter::EncodableValue(tun->name);
  map[flutter::EncodableValue("tunInterfaceIndex")] =
      flutter::EncodableValue(static_cast<int64_t>(tun->interface_index));
  map[flutter::EncodableValue("tunAddress")] =
      flutter::EncodableValue(tun_address_raw);
  return map;
}

}  // namespace

void SetupWindowsRouteChannel(flutter::BinaryMessenger* messenger) {
  if (g_channel) {
    return;
  }
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "happycat.vpn/windows_route",
      &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const auto& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const auto& method = call.method_name();
        if (method == "discoverPrimaryUplink") {
          const auto uplink = DiscoverPrimaryUplinkNative();
          if (!uplink.has_value()) {
            result->Success(flutter::EncodableValue(ErrorMap("uplink_not_found")));
            return;
          }
          result->Success(flutter::EncodableValue(UplinkMap(uplink.value())));
          return;
        }

        if (method == "applyRoutes") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("bad_args", "Expected map for applyRoutes");
            return;
          }
          result->Success(flutter::EncodableValue(ApplyRoutesNative(*args)));
          return;
        }

        if (method == "isElevated") {
          const auto elevated = QueryCurrentProcessElevation();
          if (!elevated.has_value()) {
            result->Success(flutter::EncodableValue());
            return;
          }
          result->Success(flutter::EncodableValue(elevated.value()));
          return;
        }

        if (method == "adapterStatus") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("bad_args", "Expected map for adapterStatus");
            return;
          }
          const auto status = AdapterStatusNative(GetStringArg(*args, "name"));
          if (!status.has_value()) {
            result->Success(flutter::EncodableValue());
            return;
          }
          result->Success(flutter::EncodableValue(status.value()));
          return;
        }

        result->NotImplemented();
      });
  LogDebug("channel ready");
}

void TeardownWindowsRouteChannel() {
  g_channel.reset();
}
