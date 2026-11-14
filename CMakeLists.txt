cmake_minimum_required(VERSION 3.20)
project(disc_burner VERSION 1.6.0 LANGUAGES CXX)

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

    add_executable(HappyHardcoreRadio
        MACOSX_BUNDLE
        radio.mm
    )
    target_link_libraries(HappyHardcoreRadio PRIVATE
        "-framework Cocoa"
        "-framework AVFoundation"
        "-framework UniformTypeIdentifiers"
    )
    set_target_properties(HappyHardcoreRadio PROPERTIES
        OUTPUT_NAME "Happy Hardcore Radio"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.thomaswales26.happy-hardcore-radio"
        MACOSX_BUNDLE_BUNDLE_NAME "Happy Hardcore Radio"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
        MACOSX_BUNDLE_LONG_VERSION_STRING "${PROJECT_VERSION}"
        MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    )
    find_program(FFMPEG_EXECUTABLE NAMES ffmpeg HINTS /opt/homebrew/bin /usr/local/bin)
    if(FFMPEG_EXECUTABLE)
        find_package(Python3 REQUIRED COMPONENTS Interpreter)
        add_custom_command(TARGET HappyHardcoreRadio POST_BUILD
            COMMAND "${Python3_EXECUTABLE}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/scripts/bundle-ffmpeg.py"
                    "${FFMPEG_EXECUTABLE}"
                    "$<TARGET_BUNDLE_DIR:HappyHardcoreRadio>/Contents/Resources/ffmpeg"
                    "$<TARGET_BUNDLE_DIR:HappyHardcoreRadio>/Contents/Resources/ffmpeg-libs"
            VERBATIM
        )
        message(STATUS "Bundling FFmpeg from ${FFMPEG_EXECUTABLE}")
    else()
        message(STATUS "FFmpeg not found; recording requires FFmpeg on PATH")
    endif()
endif()
