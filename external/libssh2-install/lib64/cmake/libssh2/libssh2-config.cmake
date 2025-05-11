# Copyright (C) The libssh2 project and its contributors.
# SPDX-License-Identifier: BSD-3-Clause

option(LIBSSH2_USE_PKGCONFIG "Enable pkg-config to detect libssh2 dependencies. Default: ON" "ON")

include(CMakeFindDependencyMacro)
set(CMAKE_MODULE_PATH ${CMAKE_CURRENT_LIST_DIR} ${CMAKE_MODULE_PATH})

set(_libs "")
if("OpenSSL" STREQUAL "OpenSSL")
  find_dependency(OpenSSL)
elseif("OpenSSL" STREQUAL "wolfSSL")
  find_dependency(WolfSSL)
  list(APPEND _libs libssh2::wolfssl)
elseif("OpenSSL" STREQUAL "Libgcrypt")
  find_dependency(Libgcrypt)
  list(APPEND _libs libssh2::libgcrypt)
elseif("OpenSSL" STREQUAL "mbedTLS")
  find_dependency(MbedTLS)
  list(APPEND _libs libssh2::mbedcrypto)
endif()

if(FALSE)
  find_dependency(ZLIB)
endif()

include("${CMAKE_CURRENT_LIST_DIR}/libssh2-targets.cmake")

if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.11 AND CMAKE_VERSION VERSION_LESS 3.18)
  set_target_properties(libssh2::libssh2_shared PROPERTIES IMPORTED_GLOBAL TRUE)
endif()

# Alias for either shared or static library
if(NOT TARGET libssh2::libssh2)
  add_library(libssh2::libssh2 ALIAS libssh2::libssh2_shared)
endif()

# Compatibility alias
if(NOT TARGET Libssh2::libssh2)
  add_library(Libssh2::libssh2 ALIAS libssh2::libssh2_shared)
endif()

if(TARGET libssh2::libssh2_static)
  # CMake before CMP0099 (CMake 3.17 2020-03-20) did not propagate libdirs to
  # targets. It expected libs to have an absolute filename. As a workaround,
  # manually apply dependency libdirs, for CMake consumers without this policy.
  if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.17)
    cmake_policy(GET CMP0099 _has_CMP0099)  # https://cmake.org/cmake/help/latest/policy/CMP0099.html
  endif()
  if(NOT _has_CMP0099 AND CMAKE_VERSION VERSION_GREATER_EQUAL 3.13 AND _libs)
    set(_libdirs "")
    foreach(_lib IN LISTS _libs)
      get_target_property(_libdir "${_lib}" INTERFACE_LINK_DIRECTORIES)
      if(_libdir)
        list(APPEND _libdirs "${_libdir}")
      endif()
    endforeach()
    if(_libdirs)
      target_link_directories(libssh2::libssh2_static INTERFACE ${_libdirs})
    endif()
  endif()
endif()
