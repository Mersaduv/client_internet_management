#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>
#include <shlobj.h>

#include <iostream>
#include <string>

namespace {

bool DirectoryExists(const std::wstring& path) {
  const DWORD attrs = ::GetFileAttributesW(path.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES &&
         (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

bool EnsureDirectoryTree(const std::wstring& path) {
  if (DirectoryExists(path)) {
    return true;
  }
  const size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos && slash > 0) {
    if (!EnsureDirectoryTree(path.substr(0, slash))) {
      return false;
    }
  }
  return ::CreateDirectoryW(path.c_str(), nullptr) != 0 ||
         ::GetLastError() == ERROR_ALREADY_EXISTS;
}

}  // namespace

void EnsureWebView2UserDataFolder() {
  // Respect an explicit override from the environment / launcher.
  wchar_t existing[MAX_PATH] = {};
  const DWORD existing_len =
      ::GetEnvironmentVariableW(L"WEBVIEW2_USER_DATA_FOLDER", existing, MAX_PATH);
  if (existing_len > 0 && existing_len < MAX_PATH) {
    return;
  }

  wchar_t local_app_data[MAX_PATH] = {};
  if (FAILED(::SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr,
                                SHGFP_TYPE_CURRENT, local_app_data))) {
    return;
  }

  const std::wstring user_data =
      std::wstring(local_app_data) + L"\\Ariyabod\\WebView2";
  if (!EnsureDirectoryTree(user_data)) {
    return;
  }

  ::SetEnvironmentVariableW(L"WEBVIEW2_USER_DATA_FOLDER", user_data.c_str());
}

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  unsigned int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
