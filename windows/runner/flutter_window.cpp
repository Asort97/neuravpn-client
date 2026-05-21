#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "dpi_evasion_channel.h"
#include "launch_uri_channel.h"
#include "utils.h"
#include "windows_route_channel.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetupDpiEvasionChannel(flutter_controller_->engine()->messenger());
  SetupLaunchUriChannel(flutter_controller_->engine()->messenger());
  SetupWindowsRouteChannel(flutter_controller_->engine()->messenger());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    TeardownWindowsRouteChannel();
    TeardownDpiEvasionChannel();
    TeardownLaunchUriChannel();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_COPYDATA: {
      const auto* copy_data =
          reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (copy_data != nullptr &&
          copy_data->dwData == kLaunchUriCopyDataId &&
          copy_data->lpData != nullptr &&
          copy_data->cbData >= sizeof(wchar_t)) {
        const auto* payload =
            reinterpret_cast<const wchar_t*>(copy_data->lpData);
        const std::string utf8_payload = Utf8FromUtf16(payload);
        if (!utf8_payload.empty()) {
          DispatchLaunchUri(utf8_payload);
          return 1;
        }
      }
      if (copy_data != nullptr &&
          copy_data->dwData == kDuplicateInstanceCopyDataId) {
        DispatchDuplicateInstanceSignal();
        return 1;
      }
      break;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
