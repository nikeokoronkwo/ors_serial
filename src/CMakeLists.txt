# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(ors_serial_library VERSION 0.0.1 LANGUAGES C)

add_library(ors_serial SHARED
  "ors_serial.c"
)

set_target_properties(ors_serial PROPERTIES
  PUBLIC_HEADER ors_serial.h
  OUTPUT_NAME "ors_serial"
)

target_compile_definitions(ors_serial PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(ors_serial PRIVATE "-Wl,-z,max-page-size=16384")
endif()
