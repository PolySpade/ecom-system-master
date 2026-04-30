cmake_minimum_required(VERSION 3.22)
project(EcomVideoTracker VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Widgets Sql Concurrent)
find_package(OpenCV REQUIRED COMPONENTS core imgproc videoio)

set(SOURCES
    src/main.cpp
    src/core/SettingsManager.cpp
    src/core/Database.cpp
    src/core/BarcodeHandler.cpp
    src/core/CameraHandler.cpp
    src/core/CameraUtils.cpp
    src/core/VideoCompressor.cpp
    src/ui/MainWindow.cpp
    src/ui/SearchDialog.cpp
    src/ui/SettingsDialog.cpp
    src/ui/SavingProgressDialog.cpp
)

set(HEADERS
    src/core/SettingsManager.h
    src/core/Database.h
    src/core/BarcodeHandler.h
    src/core/CameraHandler.h
    src/core/CameraUtils.h
    src/core/VideoCompressor.h
    src/ui/MainWindow.h
    src/ui/SearchDialog.h
    src/ui/SettingsDialog.h
    src/ui/SavingProgressDialog.h
)

set(RESOURCES
    src/resources/resources.qrc
)

add_executable(${PROJECT_NAME} ${SOURCES} ${HEADERS} ${RESOURCES})

target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/core
    ${CMAKE_CURRENT_SOURCE_DIR}/src/ui
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    Qt6::Core
    Qt6::Widgets
    Qt6::Sql
    Qt6::Concurrent
    ${OpenCV_LIBS}
)

# Windows-specific settings
if(WIN32)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        WIN32_EXECUTABLE TRUE
    )
    target_link_libraries(${PROJECT_NAME} PRIVATE ole32 oleaut32)
endif()
