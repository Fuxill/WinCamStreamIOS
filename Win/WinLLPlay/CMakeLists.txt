cmake_minimum_required(VERSION 3.21)
project(WinLLPlay LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- Chemins adaptés à TON repo ---
set(FFMPEG_DIR "${CMAKE_SOURCE_DIR}/FFMPEG" CACHE PATH "FFmpeg root")
set(SDL2_DIR   "${CMAKE_SOURCE_DIR}/SDL2"   CACHE PATH "SDL2 root")

# Includes
include_directories("${FFMPEG_DIR}/include")
include_directories("${SDL2_DIR}/include")

# Libs
link_directories("${FFMPEG_DIR}/lib")
# SDL2 peut être dans lib/x64 (ton cas) ou lib/
if (EXISTS "${SDL2_DIR}/lib/x64")
  link_directories("${SDL2_DIR}/lib/x64")
else()
  link_directories("${SDL2_DIR}/lib")
endif()

add_executable(WinLLPlay
  src/main.cpp
)

# On n'utilise pas SDL2main : on définit SDL_MAIN_HANDLED dans main.cpp
target_link_libraries(WinLLPlay
  avformat
  avcodec
  avutil
  swscale
  SDL2
)

if (MSVC)
  target_compile_definitions(WinLLPlay PRIVATE _CRT_SECURE_NO_WARNINGS)
  target_compile_options(WinLLPlay PRIVATE /MP)
endif()
