#!/bin/bash

#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -e

# --- Config ---
HOME="$(pwd)"
TMP_PATH="${HOME}/data"
CACHE_PATH="${HOME}/cache"
DSMPATH="${HOME}/dsm"
FILESPATH="${HOME}/files"
MODULESPATH="${HOME}/modules"
MODULESFILESPATH="${HOME}/modules_files"
EXTRACTOR_PATH="${HOME}/extractor"
EXTRACTOR_BIN="syno_extract_system_patch"

# --- Helper Functions ---
packModulesForModel() {
  local MODEL="${1}"
  local MODULES_MODEL_PATH="${MODULESPATH}/${MODEL}"
  local MODULES_FILES_PATH="${MODULESFILESPATH}/${MODEL}"

  [ -d "${MODULES_MODEL_PATH}" ] || return 0
  mkdir -p "${MODULES_FILES_PATH}"
  rm -f "${MODULES_FILES_PATH}"/*.tar

  for PRODUCTVER_DIR in "${MODULES_MODEL_PATH}"/*; do
    [ -d "${PRODUCTVER_DIR}" ] || continue
    PAT_HASH_FILE="${PRODUCTVER_DIR}/.module_pat_hash"
    if [ -f "${PAT_HASH_FILE}" ]; then
      PAT_HASH="$(cat "${PAT_HASH_FILE}")"
      tar -C "${PRODUCTVER_DIR}" -cf "${MODULES_FILES_PATH}/${PAT_HASH}.tar" . || echo "Warning: tar failed for ${PRODUCTVER_DIR}"
    else
      PRODUCTVER="$(basename "${PRODUCTVER_DIR}")"
      tar -C "${PRODUCTVER_DIR}" -cf "${MODULES_FILES_PATH}/${PRODUCTVER}.tar" . || echo "Warning: tar failed for ${PRODUCTVER_DIR}"
    fi
  done
}

getDSM() {
  PLATFORM="${1}"
  MODEL="${2}"
  URL_VER="${3}"
  PAT_URL="${4}"
  PAT_URL="$(echo "${PAT_URL}" | sed 's/global.synologydownload.com/global.download.synology.com/')"
  PRODUCTVER="${URL_VER%%-*}"
  PAT_FILE="${MODEL}_${URL_VER}.pat"
  PAT_PATH="${CACHE_PATH}/dl/${PAT_FILE}"
  UNTAR_PAT_PATH="${CACHE_PATH}/${MODEL}/${URL_VER}"
  DESTINATION="${DSMPATH}/${MODEL}/${URL_VER}"
  DESTINATIONFILES="${FILESPATH}/${MODEL}/${PRODUCTVER}"
  DESTINATIONMODULES="${MODULESPATH}/${MODEL}/${PRODUCTVER}"

  # Skip if already extracted
  if [ -f "${DESTINATION}/zImage" ]; then
    echo "Skipping ${MODEL} ${URL_VER} — already exists"
    return
  fi

  mkdir -p "${DESTINATION}" "${DESTINATIONFILES}" "${CACHE_PATH}/dl"
  mkdir -p "${DESTINATIONMODULES}"
  echo "${MODEL} ${PRODUCTVER} (${URL_VER})"
  echo "${PAT_URL}"

  if [ -f "${PAT_PATH}" ]; then
    echo "Using cached ${PAT_FILE}"
  else
    echo "Downloading ${PAT_FILE}"
    STATUS=$(curl -k -w "%{http_code}" -L "${PAT_URL}" -o "${PAT_PATH}" --progress-bar)
    if [ $? -ne 0 ] || [ "${STATUS}" -ne 200 ]; then
        rm -f "${PAT_PATH}"
        echo "Error downloading"
        return
    fi
  fi

  PAT_HASH="$(md5sum "${PAT_PATH}" | awk '{print $1}')"
  echo "${PAT_HASH}" >"${DESTINATION}/pat_hash"
  echo "${PAT_URL}" >"${DESTINATION}/pat_url"

  rm -rf "${UNTAR_PAT_PATH}"
  mkdir -p "${UNTAR_PAT_PATH}"
  echo -n "Disassembling ${PAT_FILE}: "
  header=$(od -bcN2 "${PAT_PATH}" | head -1 | awk '{print $3}')
  case ${header} in
      105) echo "Uncompressed tar"; isencrypted="no" ;;
      213) echo "Compressed tar"; isencrypted="no" ;;
      255) echo "Encrypted"; isencrypted="yes" ;;
      *)   echo "Unknown/corrupted"; return ;;
  esac

  if [ "${isencrypted}" = "yes" ]; then
    echo "Extracting..."
    if ! LD_LIBRARY_PATH="${EXTRACTOR_PATH}" "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" "${PAT_PATH}" "${UNTAR_PAT_PATH}"; then
      echo "Error extracting (encrypted)"
      rm -f "${PAT_PATH}"; rm -rf "${UNTAR_PAT_PATH}"
      return
    fi
  else
    echo "Extracting..."
    if ! tar -xf "${PAT_PATH}" -C "${UNTAR_PAT_PATH}"; then
      echo "Error extracting"
      rm -f "${PAT_PATH}"; rm -rf "${UNTAR_PAT_PATH}"
      return
    fi
  fi

  # zImage is required; abort if missing
  if [ ! -f "${UNTAR_PAT_PATH}/zImage" ]; then
    echo "Error: zImage not found in PAT, skipping"
    rm -f "${PAT_PATH}"; rm -rf "${UNTAR_PAT_PATH}"
    return
  fi

  HASH="$(sha256sum "${UNTAR_PAT_PATH}/zImage" | awk '{print$1}')"
  echo "Checking hash of zImage: OK - ${HASH}"
  echo "${HASH}" >"${DESTINATION}/zImage_hash"

  # rd.gz and grub_cksum.syno are optional (some PAT formats omit them)
  if [ -f "${UNTAR_PAT_PATH}/rd.gz" ]; then
    HASH="$(sha256sum "${UNTAR_PAT_PATH}/rd.gz" | awk '{print$1}')"
    echo "Checking hash of ramdisk: OK - ${HASH}"
    echo "${HASH}" >"${DESTINATION}/ramdisk_hash"
    cp -f "${UNTAR_PAT_PATH}/rd.gz" "${DESTINATION}"
  else
    echo "Note: rd.gz not present in PAT"
  fi

  [ -f "${UNTAR_PAT_PATH}/grub_cksum.syno" ] && cp -f "${UNTAR_PAT_PATH}/grub_cksum.syno" "${DESTINATION}"
  [ -f "${UNTAR_PAT_PATH}/GRUB_VER"        ] && cp -f "${UNTAR_PAT_PATH}/GRUB_VER"        "${DESTINATION}"
  cp -f "${UNTAR_PAT_PATH}/zImage"          "${DESTINATION}"
  [ -f "${UNTAR_PAT_PATH}/VERSION"          ] && cp -f "${UNTAR_PAT_PATH}/VERSION"         "${DESTINATION}"

  MODULES_COPIED=0
  if [ -f "${UNTAR_PAT_PATH}/rd.gz" ]; then
    rdpath="${UNTAR_PAT_PATH}/rd"
    mkdir -p "${rdpath}"
    (cd "${rdpath}"; xz -dc < "${UNTAR_PAT_PATH}/rd.gz" | cpio -idm) >/dev/null 2>&1 || true
    if [ -d "${rdpath}/usr/lib/modules" ]; then
      echo "Copying rd modules"
      cp -a "${rdpath}/usr/lib/modules/." "${DESTINATIONMODULES}/"
      MODULES_COPIED=1
    fi
  fi
  if [ -f "${UNTAR_PAT_PATH}/hda1.tgz" ]; then
    hda1path="${UNTAR_PAT_PATH}/hda1"
    mkdir -p "${hda1path}"
    (cd "${hda1path}"; xz -dc < "${UNTAR_PAT_PATH}/hda1.tgz" | cpio -idm) >/dev/null 2>&1 || true
    if [ -d "${hda1path}/usr/lib/modules" ]; then
      echo "Copying hda1 modules"
      cp -a "${hda1path}/usr/lib/modules/." "${DESTINATIONMODULES}/"
      MODULES_COPIED=1
    fi
  fi
  if [ "${MODULES_COPIED}" -eq 1 ]; then
    echo "${PAT_HASH}" >"${DESTINATIONMODULES}/.module_pat_hash"
  else
    echo "Note: no module trees found in PAT"
  fi

  cd "${DESTINATION}"
  tar -cf "${DESTINATIONFILES}/${PAT_HASH}.tar" .
  rm -f "${PAT_PATH}"
  rm -rf "${UNTAR_PAT_PATH}"

  echo "DSM Extraction complete: ${MODEL}_${URL_VER}"
  cd "${HOME}"
}

# --- Main ---
rm -rf "${TMP_PATH}" "${CACHE_PATH}"
mkdir -p "${TMP_PATH}" "${CACHE_PATH}" "configs"

# --- Get configs (platforms.yml required to filter unsupported architectures) ---
if [ ! -f "configs/platforms.yml" ]; then
  TAG="$(curl --insecure -m 10 -s https://api.github.com/repos/AuxXxilium/arc-configs/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}')"
  curl --insecure -s -L "https://github.com/AuxXxilium/arc-configs/releases/download/${TAG}/configs-${TAG}.zip" -o "configs.zip"
  unzip -oq "configs.zip" -d "configs" 2>/dev/null
  rm -f "configs.zip"
fi

# --- Git identity ---
git config --global user.email "info@auxxxilium.tech"
git config --global user.name "AuxXxilium"

# --- Fetch PAT list from Synology archive ---
PAT_LIST="${TMP_PATH}/patlist.tsv"
python3 scripts/functions.py getpats -w "." -o "${PAT_LIST}"

# --- Process entries: PLATFORM MODEL VERSION URL ---
LAST_MODEL=""
while IFS=$'\t' read -r PLATFORM MODEL VERSION PAT_URL; do
  if [ "${MODEL}" != "${LAST_MODEL}" ] && [ -n "${LAST_MODEL}" ]; then
    packModulesForModel "${LAST_MODEL}"
    git add "${HOME}/dsm/${LAST_MODEL}"
    git add "${HOME}/files/${LAST_MODEL}"
    git add "${HOME}/modules/${LAST_MODEL}"
    git add "${HOME}/modules_files/${LAST_MODEL}"
    git commit -m "${LAST_MODEL}: update $(date +%Y-%m-%d\ %H:%M:%S)" || true
    git push || true
  fi
  getDSM "${PLATFORM}" "${MODEL}" "${VERSION}" "${PAT_URL}"
  LAST_MODEL="${MODEL}"
done < <(sort -t$'\t' -k2,2 -k3,3 "${PAT_LIST}")

# Commit the final model
if [ -n "${LAST_MODEL}" ]; then
  packModulesForModel "${LAST_MODEL}"
  git add "${HOME}/dsm/${LAST_MODEL}"
  git add "${HOME}/files/${LAST_MODEL}"
  git add "${HOME}/modules/${LAST_MODEL}"
  git add "${HOME}/modules_files/${LAST_MODEL}"
  git commit -m "${LAST_MODEL}: update $(date +%Y-%m-%d\ %H:%M:%S)" || true
  git push || true
fi

rm -rf "${CACHE_PATH}" "${TMP_PATH}" "configs"
