cmake_minimum_required(VERSION 3.10)
project(prysm_linux_audio LANGUAGES CXX)

set(PLUGIN_NAME "prysm_linux_audio_plugin")

add_library(${PLUGIN_NAME} SHARED
  "prysm_linux_audio_plugin.cc"
  "audio_devices.cc"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

find_package(PkgConfig REQUIRED)
pkg_check_modules(PULSE REQUIRED IMPORTED_TARGET libpulse)

target_include_directories(${PLUGIN_NAME} PRIVATE
  ${PULSE_INCLUDE_DIRS})

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::PULSE)

set(prysm_linux_audio_bundled_libraries
  ""
  PARENT_SCOPE
)
