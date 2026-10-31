# phrase-stream: phrase-by-phrase live transcription on top of transcribe.cpp's
# public C API. TRANSCRIBE_SRC points at a transcribe.cpp source tree (build.sh
# prepares a pinned, patched snapshot of it).
cmake_minimum_required(VERSION 3.21)
project(phrase_stream C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT TRANSCRIBE_SRC)
    message(FATAL_ERROR "set -DTRANSCRIBE_SRC=<transcribe.cpp source tree>")
endif()
set(TRANSCRIBE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(TRANSCRIBE_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(TRANSCRIBE_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
add_subdirectory(${TRANSCRIBE_SRC} transcribe EXCLUDE_FROM_ALL)

# transcribe's public include path is spelled relative to the top-level source
# dir, which is this project when transcribe.cpp is built as a subdirectory.
target_include_directories(transcribe PUBLIC ${TRANSCRIBE_SRC}/include)

find_package(Threads REQUIRED)
add_executable(phrase-stream phrase-stream.cpp)
target_link_libraries(phrase-stream PRIVATE transcribe Threads::Threads)
set_target_properties(phrase-stream PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
