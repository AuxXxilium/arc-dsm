#!/bin/bash

#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
# 
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -e

# --- Config ---
HOME=$(pwd)
TMP_PATH="${HOME}/data"
CACHE_PATH="${HOME}/cache"
CONFIGS="configs"
DSMPATH="${HOME}/dsm"
FILESPATH="${HOME}/files"
EXTRACTOR_PATH="${HOME}/extractor"
EXTRACTOR_BIN="syno_extract_system_patch"

# --- Helper Functions ---
writeConfigKey() {
  if [ "${2}" = "{}" ]; then
    yq eval ".${1} = {}" --inplace "${3}" 2>/dev/null
  else
    yq eval ".${1} = \"${2}\"" --inplace "${3}" 2>/dev/null
  fi
}
readConfigKey() {
  local RESULT
  RESULT=$(yq eval '.'${1}' | explode(.)' "${2}" 2>/dev/null)
  [ "${RESULT}" = "null" ] && echo "" || echo "${RESULT}"
}
readConfigEntriesArray() {
  yq eval '.'${1}' | explode(.) | to_entries | map([.key])[] | .[]' "${2}"
}

getDSM() {
  PLATFORM="${1}"
  MODEL="${2}"
  URL_VER="${3}"
  PAT_URL="${4}"
  PAT_URL=$(echo "${PAT_URL}" | sed 's/global.synologydownload.com/global.download.synology.com/')
  PRODUCTVER="${URL_VER:0:3}"
  PAT_FILE="${MODEL}_${URL_VER}.pat"
  PAT_PATH="${CACHE_PATH}/dl/${PAT_FILE}"
  UNTAR_PAT_PATH="${CACHE_PATH}/${MODEL}/${URL_VER}"
  DESTINATION="${DSMPATH}/${MODEL}/${URL_VER}"
  DESTINATIONFILES="${FILESPATH}/${MODEL}/${PRODUCTVER}"

  mkdir -p "${DESTINATION}" "${DESTINATIONFILES}" "${CACHE_PATH}/dl"
  echo "${MODEL} ${PRODUCTVER} (${URL_VER})"
  echo "${PAT_URL}"

  rm -f "${PAT_PATH}"
  echo "Downloading ${PAT_FILE}"
  STATUS=$(curl -k -w "%{http_code}" -L "${PAT_URL}" -o "${PAT_PATH}" --progress-bar)
  if [ $? -ne 0 ] || [ "${STATUS}" -ne 200 ]; then
      rm -f "${PAT_PATH}"
      echo "Error downloading"
      return
  fi

  PAT_HASH=$(md5sum "${PAT_PATH}" | awk '{print $1}')
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
      LD_LIBRARY_PATH="${EXTRACTOR_PATH}" "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" "${PAT_PATH}" "${UNTAR_PAT_PATH}"
  else
      echo "Extracting..."
      tar -xf "${PAT_PATH}" -C "${UNTAR_PAT_PATH}" || { echo "Error extracting"; return; }
  fi

  HASH=$(sha256sum "${UNTAR_PAT_PATH}/zImage" | awk '{print$1}')
  echo "Checking hash of zImage: OK - ${HASH}"
  echo "${HASH}" >"${DESTINATION}/zImage_hash"

  HASH=$(sha256sum "${UNTAR_PAT_PATH}/rd.gz" | awk '{print$1}')
  echo "Checking hash of ramdisk: OK - ${HASH}"
  echo "${HASH}" >"${DESTINATION}/ramdisk_hash"

  cp -f "${UNTAR_PAT_PATH}/grub_cksum.syno" "${DESTINATION}"
  cp -f "${UNTAR_PAT_PATH}/GRUB_VER"        "${DESTINATION}"
  cp -f "${UNTAR_PAT_PATH}/zImage"          "${DESTINATION}"
  cp -f "${UNTAR_PAT_PATH}/rd.gz"           "${DESTINATION}"
  cp -f "${UNTAR_PAT_PATH}/VERSION"         "${DESTINATION}"
  cd "${DESTINATION}"
  tar -cf "${DESTINATIONFILES}/${PAT_HASH}.tar" .
  rm -f "${PAT_PATH}"
  rm -rf "${UNTAR_PAT_PATH}"

  echo "DSM Extraction complete: ${MODEL}_${URL_VER}"

  writeConfigKey "${PLATFORM}.\"${MODEL}\".\"${URL_VER}\".url" "${PAT_URL}" "${TMP_PATH}/data.yml"
  writeConfigKey "${PLATFORM}.\"${MODEL}\".\"${URL_VER}\".hash" "${PAT_HASH}" "${TMP_PATH}/data.yml"
  {
    echo ""
    echo "${MODEL} ${PRODUCTVER} (${URL_VER})"
    echo "Url: ${PAT_URL}"
    echo "Hash: ${PAT_HASH}"
  } >>"${TMP_PATH}/webdata.txt"
  cd "${HOME}"
}

# --- Main ---
rm -rf "${TMP_PATH}" "${CACHE_PATH}"
mkdir -p "${TMP_PATH}" "${CACHE_PATH}" "${CONFIGS}"

# --- Get configs ---
if [ ! -f "${CONFIGS}/platforms.yml" ]; then
  TAG="$(curl --insecure -m 5 -s https://api.github.com/repos/AuxXxilium/arc-configs/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}')"
  curl --insecure -s -L "https://github.com/AuxXxilium/arc-configs/releases/download/${TAG}/configs-${TAG}.zip" -o "configs.zip"
  unzip -oq "configs.zip" -d "${CONFIGS}" >/dev/null 2>&1
  rm -f "configs.zip"
fi

# --- Clean up and prepare data files ---
rm -f "${TMP_PATH}/data.yml" "${TMP_PATH}/webdata.txt"
touch "${TMP_PATH}/data.yml"
touch "${TMP_PATH}/webdata.txt"

# --- Get PATs ---
python3 scripts/functions.py getpats -w "." -j "${TMP_PATH}/data.yml"

# --- Process each platform, model, and version ---
for PLATFORM in $(readConfigEntriesArray "" "${TMP_PATH}/data.yml"); do
  echo "Processing platform: ${PLATFORM}"
  for MODEL in $(readConfigEntriesArray "${PLATFORM}" "${TMP_PATH}/data.yml"); do
    echo "Processing model: ${MODEL}"
    for VERSION in $(readConfigEntriesArray "${PLATFORM}.\"${MODEL}\"" "${TMP_PATH}/data.yml"); do
      echo "Processing version: ${VERSION}"
      PAT_HASH=""
      URL_VER="${VERSION}"
      PAT_URL=$(readConfigKey "${PLATFORM}.\"${MODEL}\".\"${VERSION}\".url" "${TMP_PATH}/data.yml")
      getDSM "${PLATFORM}" "${MODEL}" "${URL_VER}" "${PAT_URL}"
      git config --global user.email "info@auxxxilium.tech"
      git config --global user.name "AuxXxilium"
      git fetch
      git add "${HOME}/dsm/${MODEL}"
      git add "${HOME}/files/${MODEL}"
      git commit -m "${MODEL}: update $(date +%Y-%m-%d" "%H:%M:%S)"
      git push
    done
  done
done

# --- Finalize ---
cp -f "${TMP_PATH}/webdata.txt" "${HOME}/webdata.txt"
cp -f "${TMP_PATH}/data.yml" "${HOME}/data.yml"

rm -rf "${CACHE_PATH}" "${TMP_PATH}" "${CONFIGS}"

git config --global user.email "info@auxxxilium.tech"
git config --global user.name "AuxXxilium"
git fetch
git add "${HOME}/webdata.txt"
git add "${HOME}/data.yml"
git commit -m "data: update $(date +%Y-%m-%d" "%H:%M:%S)" || true
git push || true