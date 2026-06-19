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
  RESULT="$(yq eval '.'${1}' | explode(.)' "${2}" 2>/dev/null)"
  [ "${RESULT}" = "null" ] && echo "" || echo "${RESULT}"
}
readConfigEntriesArray() {
  yq eval '.'${1}' | explode(.) | to_entries | map([.key])[] | .[]' "${2}"
}
readTopLevelEntries() {
  yq eval -N 'keys | .[]' "${1}"
}
isVersionAtLeast72() {
  local V="${1}"
  local PREFIX MAJOR MINOR
  PREFIX="${V%%-*}"
  MAJOR="${PREFIX%%.*}"
  local REST="${PREFIX#*.}"
  MINOR="${REST%%.*}"

  [ -z "${MAJOR}" ] && return 1
  [ -z "${MINOR}" ] && return 1
  [[ "${MAJOR}" =~ ^[0-9]+$ ]] || return 1
  [[ "${MINOR}" =~ ^[0-9]+$ ]] || return 1

  if [ "${MAJOR}" -gt 7 ]; then
    return 0
  fi
  if [ "${MAJOR}" -eq 7 ] && [ "${MINOR}" -ge 2 ]; then
    return 0
  fi
  return 1
}
mergeMissingDataFromSource() {
  local SRC_PATH="${1}"
  local SRC_LABEL="${2}"

  [ -f "${SRC_PATH}" ] || return 0
  echo "Merging missing entries from ${SRC_LABEL}"

  for OLD_PLATFORM in $(readTopLevelEntries "${SRC_PATH}"); do
    for OLD_MODEL in $(readConfigEntriesArray "${OLD_PLATFORM}" "${SRC_PATH}"); do
      for OLD_VERSION in $(readConfigEntriesArray "${OLD_PLATFORM}.\"${OLD_MODEL}\"" "${SRC_PATH}"); do
        if ! isVersionAtLeast72 "${OLD_VERSION}"; then
          continue
        fi

        NEW_URL="$(readConfigKey "${OLD_PLATFORM}.\"${OLD_MODEL}\".\"${OLD_VERSION}\".url" "${TMP_PATH}/data.yml")"
        if [ -n "${NEW_URL}" ]; then
          continue
        fi

        OLD_URL="$(readConfigKey "${OLD_PLATFORM}.\"${OLD_MODEL}\".\"${OLD_VERSION}\".url" "${SRC_PATH}")"
        OLD_HASH="$(readConfigKey "${OLD_PLATFORM}.\"${OLD_MODEL}\".\"${OLD_VERSION}\".hash" "${SRC_PATH}")"

        [ -n "${OLD_URL}" ] && writeConfigKey "${OLD_PLATFORM}.\"${OLD_MODEL}\".\"${OLD_VERSION}\".url" "${OLD_URL}" "${TMP_PATH}/data.yml"
        [ -n "${OLD_HASH}" ] && writeConfigKey "${OLD_PLATFORM}.\"${OLD_MODEL}\".\"${OLD_VERSION}\".hash" "${OLD_HASH}" "${TMP_PATH}/data.yml"
      done
    done
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

  # Skip if already extracted
  if [ -f "${DESTINATION}/zImage" ]; then
    echo "Skipping ${MODEL} ${URL_VER} — already exists"
    return
  fi

  mkdir -p "${DESTINATION}" "${DESTINATIONFILES}" "${CACHE_PATH}/dl"
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
mkdir -p "${TMP_PATH}" "${CACHE_PATH}"

if [ ! -f "configs/platforms.yml" ]; then
  echo "Error: configs/platforms.yml not found" >&2
  exit 1
fi

# --- Clean up and prepare data files ---
rm -f "${TMP_PATH}/data.yml" "${TMP_PATH}/webdata.txt"
touch "${TMP_PATH}/data.yml"
touch "${TMP_PATH}/webdata.txt"

# --- Get PATs ---
python3 scripts/functions.py getpats -w "." -j "${TMP_PATH}/data.yml"

# --- Merge missing entries from backup ---
BACKUP_DATA_URL="${BACKUP_DATA_URL:-https://github.com/AuxXxilium/arc-dsm/raw/refs/heads/backup/data.yml}"
if [ -n "${BACKUP_DATA_URL}" ]; then
  BACKUP_URL_DATA_PATH="${TMP_PATH}/backup-url-data.yml"
  if curl --insecure -sSfL "${BACKUP_DATA_URL}" -o "${BACKUP_URL_DATA_PATH}"; then
    mergeMissingDataFromSource "${BACKUP_URL_DATA_PATH}" "${BACKUP_DATA_URL}"
  else
    echo "Note: could not download backup data.yml, skipping merge"
  fi
fi

# --- Process each platform/model/version: commit per model, push every 5 ---
UNPUSHED=0
for PLATFORM in $(readTopLevelEntries "${TMP_PATH}/data.yml"); do
  echo "Processing platform: ${PLATFORM}"
  for MODEL in $(readConfigEntriesArray "${PLATFORM}" "${TMP_PATH}/data.yml"); do
    echo "Processing model: ${MODEL}"
    for VERSION in $(readConfigEntriesArray "${PLATFORM}.\"${MODEL}\"" "${TMP_PATH}/data.yml"); do
      PAT_URL="$(readConfigKey "${PLATFORM}.\"${MODEL}\".\"${VERSION}\".url" "${TMP_PATH}/data.yml")"
      getDSM "${PLATFORM}" "${MODEL}" "${VERSION}" "${PAT_URL}"
    done
    git add "dsm/${MODEL}" "files/${MODEL}"
    git diff --cached --quiet || {
      git commit -m "${MODEL}: update $(date +%Y-%m-%d\ %H:%M:%S)"
      UNPUSHED=$((UNPUSHED + 1))
    }
    if [ "${UNPUSHED}" -ge 5 ]; then
      git push
      UNPUSHED=0
    fi
  done
done

# --- Finalize data files ---
cp -f "${TMP_PATH}/webdata.txt" "${HOME}/webdata.txt"
cp -f "${TMP_PATH}/data.yml" "${HOME}/data.yml"

rm -rf "${CACHE_PATH}" "${TMP_PATH}"

git add webdata.txt data.yml
git diff --cached --quiet || git commit -m "data: update $(date +%Y-%m-%d\ %H:%M:%S)"
[ "${UNPUSHED}" -gt 0 ] && git push || true
