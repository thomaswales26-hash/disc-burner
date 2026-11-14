cmake_minimum_required(VERSION 3.20)
project(disc_burner VERSION 1.5.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(disc-burner main.cpp)

if(APPLE)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 20)
    set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
    set(CMAKE_OBJCXX_EXTENSIONS OFF)

    add_executable(DiscBurner
        MACOSX_BUNDLE
        gui.mm
    )
    target_link_libraries(DiscBurner PRIVATE "-framework Cocoa")
    set_target_properties(DiscBurner PROPERTIES
        OUTPUT_NAME "Disc Burner"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.thomaswales26.disc-burner"
        MACOSX_BUNDLE_BUNDLE_NAME "Disc Burner"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
        MACOSX_BUNDLE_LONG_VERSION_STRING "${PROJECT_VERSION}"
        MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    )
endif()
