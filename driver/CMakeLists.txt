cmake_minimum_required(VERSION 3.15)
project(phonevr_driver CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Everything SteamVR needs ends up in <build>/package/phonevr:
#   phonevr/driver.vrdrivermanifest
#   phonevr/resources/...
#   phonevr/bin/win64/driver_phonevr.dll
set(PKG_DIR "${CMAKE_BINARY_DIR}/package/phonevr")
if(WIN32)
  set(BIN_DIR "${PKG_DIR}/bin/win64")
else()
  set(BIN_DIR "${PKG_DIR}/bin/linux64")
endif()

add_library(driver_phonevr SHARED src/driver.cpp)
target_include_directories(driver_phonevr PRIVATE third_party/openvr src)

if(WIN32)
  target_link_libraries(driver_phonevr PRIVATE ws2_32)
  target_compile_definitions(driver_phonevr PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX)
else()
  set_target_properties(driver_phonevr PROPERTIES PREFIX "" CXX_VISIBILITY_PRESET hidden)
  find_package(Threads REQUIRED)
  target_link_libraries(driver_phonevr PRIVATE Threads::Threads)
endif()

# Put the binary in the package folder for every configuration (Debug/Release/...).
set(_props RUNTIME_OUTPUT_DIRECTORY LIBRARY_OUTPUT_DIRECTORY)
foreach(_p ${_props})
  set_target_properties(driver_phonevr PROPERTIES ${_p} "${BIN_DIR}")
  foreach(_cfg DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set_target_properties(driver_phonevr PROPERTIES ${_p}_${_cfg} "${BIN_DIR}")
  endforeach()
endforeach()

add_custom_command(TARGET driver_phonevr POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/phonevr" "${PKG_DIR}"
  COMMENT "Copying driver manifest and resources")

# Host-side checks (not built by default):  cmake --build . --target phonevr_tests && ctest
option(PHONEVR_TESTS "Build unit tests" OFF)
if(PHONEVR_TESTS)
  enable_testing()
  add_executable(test_pose tests/test_pose.cpp)
  target_include_directories(test_pose PRIVATE src)
  add_test(NAME pose_math COMMAND test_pose)
endif()
