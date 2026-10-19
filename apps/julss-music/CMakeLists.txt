cmake_minimum_required(VERSION 3.20)
project(julss-music LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_FLAGS_RELEASE "-O2 -march=native")

find_package(Qt6 REQUIRED COMPONENTS Widgets Network DBus Concurrent)
find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil libswresample)
pkg_check_modules(PIPEWIRE REQUIRED IMPORTED_TARGET libpipewire-0.3)

add_executable(julss-music
  src/main.cpp
  src/ring.h
  src/eq.h src/eq.cpp
  src/engine.h src/engine.cpp
  src/meta.h src/meta.cpp
  src/lyrics.h src/lyrics.cpp
  src/lyricsview.h src/lyricsview.cpp
  src/playlist.h src/playlist.cpp
  src/eqpanel.h src/eqpanel.cpp
  src/mpris.h src/mpris.cpp
  src/theme.h src/theme.cpp
  src/widgets.h src/widgets.cpp
  src/mainwindow.h src/mainwindow.cpp
)
target_link_libraries(julss-music PRIVATE Qt6::Widgets Qt6::Network Qt6::DBus Qt6::Concurrent
  PkgConfig::FFMPEG PkgConfig::PIPEWIRE)
install(TARGETS julss-music RUNTIME DESTINATION bin)
install(FILES data/julss-music.desktop DESTINATION share/applications)
