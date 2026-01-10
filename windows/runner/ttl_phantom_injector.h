#pragma once

// Keep include order: winsock2 before windows.h to avoid winsock.h conflicts.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

bool start_ttl_phantom_injector(const char* server_ip,
                                UINT16 server_port,
                                bool enable_window_clamp,
                                bool enable_sni_randomization);
void stop_ttl_phantom_injector();
