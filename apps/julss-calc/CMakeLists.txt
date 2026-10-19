cmake_minimum_required(VERSION 3.20)
project(julss-calc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_FLAGS_RELEASE "-O2 -march=native")

find_package(Qt6 REQUIRED COMPONENTS Widgets)

add_executable(julss-calc
  src/main.cpp
  src/types.h
  src/program.cpp
  src/cas.h src/cas.cpp
  src/mathrender.h src/mathrender.cpp
  src/plot2d.h src/plot2d.cpp
  src/plot3d.h src/plot3d.cpp
  src/theme.h src/theme.cpp
  src/widgets.h src/widgets.cpp
  src/pages.h src/scipage.cpp src/eqpage.cpp src/calcpage.cpp src/graphpage.cpp
  src/mainwindow.h src/mainwindow.cpp
  src/demo.h src/demo.cpp
)
# Giac's headers are noisy; keep our own warnings visible but silence theirs.
target_include_directories(julss-calc SYSTEM PRIVATE /usr/include/giac)
target_link_libraries(julss-calc PRIVATE Qt6::Widgets giac gmp)
install(TARGETS julss-calc RUNTIME DESTINATION bin)

# Console harness for the CAS layer (not installed).
add_executable(castest EXCLUDE_FROM_ALL tests/castest.cpp src/cas.h src/cas.cpp src/program.cpp src/types.h)
target_include_directories(castest SYSTEM PRIVATE /usr/include/giac)
target_link_libraries(castest PRIVATE Qt6::Core giac gmp)
