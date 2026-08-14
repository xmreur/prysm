# Install bundled lyrebird PT binary into the desktop app bundle when present.
# Populated at build time via tool/fetch_lyrebird.sh (not at app runtime).

set(PRYSM_LYREBIRD_ASSET_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../assets/native/pt")

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(PRYSM_LYREBIRD_SRC "${PRYSM_LYREBIRD_ASSET_ROOT}/linux/arm64/lyrebird")
  else()
    set(PRYSM_LYREBIRD_SRC "${PRYSM_LYREBIRD_ASSET_ROOT}/linux/amd64/lyrebird")
  endif()
  if(EXISTS "${PRYSM_LYREBIRD_SRC}")
    install(
      PROGRAMS "${PRYSM_LYREBIRD_SRC}"
      DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
      RENAME "lyrebird"
      COMPONENT Runtime
    )
  endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
  set(PRYSM_LYREBIRD_SRC "${PRYSM_LYREBIRD_ASSET_ROOT}/windows/lyrebird.exe")
  if(EXISTS "${PRYSM_LYREBIRD_SRC}")
    install(
      PROGRAMS "${PRYSM_LYREBIRD_SRC}"
      DESTINATION "${CMAKE_INSTALL_PREFIX}"
      COMPONENT Runtime
    )
  endif()
endif()
