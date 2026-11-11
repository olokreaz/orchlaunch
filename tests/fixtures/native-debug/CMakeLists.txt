cmake_minimum_required(VERSION 3.20)
project(orchlaunch_native_debug_fixture LANGUAGES CXX)

add_executable(native_debug_fixture main.cpp)
target_compile_features(native_debug_fixture PRIVATE cxx_std_20)
target_compile_options(native_debug_fixture PRIVATE -O0 -g)
