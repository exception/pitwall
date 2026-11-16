get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../" ABSOLUTE)

macro(check_required_components _NAME)
  foreach(comp ${${_NAME}_FIND_COMPONENTS})
    if(NOT ${_NAME}_${comp}_FOUND)
      if(${_NAME}_FIND_REQUIRED_${comp})
        set(${_NAME}_FOUND FALSE)
      endif()
    endif()
  endforeach()
endmacro()

include(CMakeFindDependencyMacro)

set(_ghostty_vt_libdir "${PACKAGE_PREFIX_DIR}/lib")

# The directory that holds the shared library, and on Windows its import
# library. In a normal install this is the same as the libdir. Some
# packaging systems, such as nixpkgs, install the shared library under a
# different prefix than the headers and static library. They can rewrite
# this one line to point at it.
set(_ghostty_vt_shared_libdir "${_ghostty_vt_libdir}")

# Shared library target
if(NOT TARGET ghostty-vt::ghostty-vt)
    add_library(ghostty-vt::ghostty-vt SHARED IMPORTED)

    if(WIN32)
        set(_ghostty_vt_shared_location "${PACKAGE_PREFIX_DIR}/bin/libghostty-vt.1.0.2.dylib")
    else()
        set(_ghostty_vt_shared_location "${_ghostty_vt_shared_libdir}/libghostty-vt.1.0.2.dylib")
    endif()

    set_target_properties(ghostty-vt::ghostty-vt PROPERTIES
        IMPORTED_LOCATION "${_ghostty_vt_shared_location}"
        INTERFACE_INCLUDE_DIRECTORIES "${PACKAGE_PREFIX_DIR}/include"
    )
    unset(_ghostty_vt_shared_location)

    if(APPLE)
        # The install name, for example @rpath/libghostty-vt.0.dylib. Its
        # leading at-sign is joined on separately. Written as one string,
        # configure_file() would pair that at-sign with the first one of
        # the soname placeholder and read the text between them as a
        # variable name.
        string(CONCAT _ghostty_vt_install_name "@" "rpath/libghostty-vt.1.dylib")
        set_target_properties(ghostty-vt::ghostty-vt PROPERTIES
            IMPORTED_SONAME "${_ghostty_vt_install_name}"
            INTERFACE_LINK_DIRECTORIES "${_ghostty_vt_shared_libdir}"
        )
        # Ensure consumers can find the @rpath dylib at runtime
        set_property(TARGET ghostty-vt::ghostty-vt APPEND PROPERTY
            INTERFACE_LINK_OPTIONS "LINKER:-rpath,${_ghostty_vt_shared_libdir}"
        )
    elseif(WIN32)
        set_target_properties(ghostty-vt::ghostty-vt PROPERTIES
            IMPORTED_IMPLIB "${_ghostty_vt_shared_libdir}/"
        )
    else()
        set_target_properties(ghostty-vt::ghostty-vt PROPERTIES
            IMPORTED_SONAME "libghostty-vt.1.dylib"
        )
    endif()
endif()

# Static library target
#
# Consumers must link transitive dependencies themselves. By default (with
# SIMD enabled): libc, libc++ (or libstdc++ on Linux), highway, and
# simdutf. Building with -Dsimd=false removes the C++ / highway / simdutf
# dependencies.
#
# GHOSTTY_STATIC tells the headers that the library is linked statically.
# Without it, on Windows every declaration is __declspec(dllimport) and
# the link fails with undefined __imp_ghostty_* symbols. Elsewhere it only
# drops a visibility attribute.
if(NOT TARGET ghostty-vt::ghostty-vt-static)
    add_library(ghostty-vt::ghostty-vt-static STATIC IMPORTED)

    set_target_properties(ghostty-vt::ghostty-vt-static PROPERTIES
        IMPORTED_LOCATION "${_ghostty_vt_libdir}/libghostty-vt.a"
        INTERFACE_INCLUDE_DIRECTORIES "${PACKAGE_PREFIX_DIR}/include"
        INTERFACE_COMPILE_DEFINITIONS "GHOSTTY_STATIC"
    )
    if(WIN32)
        set_target_properties(ghostty-vt::ghostty-vt-static PROPERTIES
            INTERFACE_LINK_LIBRARIES "ntdll;kernel32"
        )
    endif()
endif()

unset(_ghostty_vt_install_name)
unset(_ghostty_vt_shared_libdir)
unset(_ghostty_vt_libdir)

check_required_components(ghostty-vt)
