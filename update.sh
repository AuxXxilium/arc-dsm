#!/usr/bin/bash

function readConfigEntriesArray() {
  yq eval '.'${1}' | explode(.) | to_entries | map([.key])[] | .[]' "${2}"
}

function getDSM() {
    MODEL="${1}"
    PLATFORM="${2}"
    VERSIONS="$(readConfigEntriesArray "platforms.${PLATFORM}.productvers" "${P_FILE}" | sort -r)"
    echo "${VERSIONS}" >"${TMP_PATH}/versions"
    while IFS= read -r line; do
        VERSION="${line}"
        PAT_FILE="${MODEL}_${VERSION}.pat"
        PAT_PATH="${CACHE_PATH}/dl/${PAT_FILE}"
        UNTAR_PAT_PATH="${CACHE_PATH}/${MODEL}/${VERSION}"
        DESTINATION="${DSMPATH}/${MODEL}/${VERSION}"
        DESTINATIONFILES="${FILESPATH}/${MODEL}/${VERSION}"
        # Make Destinations
        mkdir -p "${DESTINATION}"
        mkdir -p "${DESTINATIONFILES}"
        echo "${MODEL} ${VERSION}"
        echo "" >>"${TMP_PATH}/dsmdata.yml"
        echo "${MODEL} ${VERSION}" >>"${TMP_PATH}/dsmdata.yml"
        # Grep PAT_URL
        PAT_URL="$(curl -skL "https://www.synology.com/api/support/findDownloadInfo?lang=en-us&product=${MODEL/+/%2B}&major=${VERSION%%.*}&minor=${VERSION##*.}" | jq -r '.info.system.detail[0].items[0].files[0].url')"
        PAT_HASH="$(curl -skL "https://www.synology.com/api/support/findDownloadInfo?lang=en-us&product=${MODEL/+/%2B}&major=${VERSION%%.*}&minor=${VERSION##*.}" | jq -r '.info.system.detail[0].items[0].files[0].checksum')"
        PAT_URL="${PAT_URL%%\?*}"
        echo "${PAT_URL}"
        echo "URL: ${PAT_URL}" >>"${TMP_PATH}/dsmdata.yml"
        echo "${PAT_HASH}"
        echo "HASH: ${PAT_HASH}" >>"${TMP_PATH}/dsmdata.yml"
        if [ -f "${DESTINATION}/pat_url" ] && [ -f "${DESTINATION}/pat_hash" ]; then
            OLDURL="$(cat "${DESTINATION}/pat_url")"
            OLDHASH="$(cat "${DESTINATION}/pat_hash")"
        else
            OLDURL="0"
            OLDHASH="0"
        fi
        # Check for Update
        if [ "${PAT_HASH}" != "${OLDHASH}" ] || [ "${PAT_URL}" != "${OLDURL}" ]; then
            mkdir -p "${CACHE_PATH}/dl"
            echo "Downloading ${PAT_FILE}"
            # Discover remote file size
            STATUS=$(curl -k -w "%{http_code}" -L "${PAT_URL}" -o "${PAT_PATH}" --progress-bar)
            if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
                rm "${PAT_PATH}"
                echo "Error downloading"
            fi
            if [ -f "${PAT_PATH}" ]; then
                # Export Values
                echo "${PAT_HASH}" >"${DESTINATION}/pat_hash"
                echo "${PAT_URL}" >"${DESTINATION}/pat_url"
                # Extract Files
                rm -rf "${UNTAR_PAT_PATH}"
                mkdir -p "${UNTAR_PAT_PATH}"
                echo -n "Disassembling ${PAT_FILE}: "
                header=$(od -bcN2 ${PAT_PATH} | head -1 | awk '{print $3}')
                case ${header} in
                    105)
                    echo "Uncompressed tar"
                    isencrypted="no"
                    ;;
                    213)
                    echo "Compressed tar"
                    isencrypted="no"
                    ;;
                    255)
                    echo "Encrypted"
                    isencrypted="yes"
                    ;;
                    *)
                    echo -e "Could not determine if pat file is encrypted or not, maybe corrupted, try again!"
                    ;;
                esac
                if [ "${isencrypted}" = "yes" ]; then
                    # Check existance of extractor
                    if [ -f "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" ]; then
                        echo "Extractor cached."
                    fi
                    # Uses the extractor to untar pat file
                    echo "Extracting..."
                    LD_LIBRARY_PATH="${EXTRACTOR_PATH}" "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" "${PAT_PATH}" "${UNTAR_PAT_PATH}"
                else
                    echo "Extracting..."
                    tar -xf "${PAT_PATH}" -C "${UNTAR_PAT_PATH}"
                    if [ $? -ne 0 ]; then
                        echo "Error extracting"
                    fi
                fi
                # Export Hash
                echo -n "Checking hash of zImage: "
                HASH=$(sha256sum ${UNTAR_PAT_PATH}/zImage | awk '{print$1}')
                echo "OK"
                echo "${HASH}" >"${DESTINATION}/zImage_hash"
                echo -n "Checking hash of ramdisk: "
                HASH=$(sha256sum ${UNTAR_PAT_PATH}/rd.gz | awk '{print$1}')
                echo "OK"
                echo "${HASH}" >"${DESTINATION}/ramdisk_hash"
                # Copy Files to Destination
                echo -n "Copying files: "
                cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${DESTINATION}"
                cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${DESTINATION}"
                cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${DESTINATION}"
                cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${DESTINATION}"
                cp "${UNTAR_PAT_PATH}/zImage"          "${DESTINATION}"
                cp "${UNTAR_PAT_PATH}/rd.gz"           "${DESTINATION}"
                cd "${DESTINATION}"
                tar -cf "${DESTINATIONFILES}/${PAT_HASH}.tar" .
                rm -f "${PAT_PATH}"
                rm -rf "${UNTAR_PAT_PATH}"
            fi
            echo "DSM Extraction complete: ${MODEL}_${VERSION}"
        else
            echo "No DSM Update found: ${MODEL}_${VERSION}"
        fi
        cd ${HOME}
    done <<<$(cat "${TMP_PATH}/versions")
    rm -f "${TMP_PATH}/versions"
}

# Init DSM Files
HOME=$(pwd)
CONFIGS="./configs"
TMP_PATH="${HOME}/tmp"
mkdir -p "${TMP_PATH}"
rm -f "${CONFIGS}"
mkdir -p "${CONFIGS}"
touch "${TMP_PATH}/dsmdata.yml"
TAG="$(curl --insecure -m 5 -s https://api.github.com/repos/AuxXxilium/arc-configs/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}')"
curl --insecure -s -w "%{http_code}" -L "https://github.com/AuxXxilium/arc-configs/releases/download/${TAG}/configs.zip" -o "./configs.zip"
unzip -oq "./configs.zip" -d "${CONFIGS}" >/dev/null 2>&1
P_FILE="${CONFIGS}/platforms.yml"
PS="$(readConfigEntriesArray "platforms" "${P_FILE}" | sort)"
MJ="$(python include/functions.py getmodels -p "${PS[*]}")"
if [[ -z "${MJ}" || "${MJ}" = "[]" ]]; then
    dialog --backtitle "$(backtitle)" --title "Model" --title "Model" \
        --msgbox "Failed to get models, please try again!" 0 0
    return 1
fi
echo -n "" >"${TMP_PATH}/modellist"
echo "${MJ}" | jq -c '.[]' | while read -r item; do
    name=$(echo "$item" | jq -r '.name')
    arch=$(echo "$item" | jq -r '.arch')
    echo "${name} ${arch}" >>"${TMP_PATH}/modellist"
done
while read -r M A; do
    CACHE_PATH="${HOME}/cache"
    RAMDISK_PATH="${CACHE_PATH}/ramdisk"
    EXTRACTOR_PATH="${CACHE_PATH}/extractor"
    EXTRACTOR_BIN="syno_extract_system_patch"
    DSMPATH="${HOME}/dsm"
    FILESPATH="${HOME}/files"
    MODEL=$(echo ${M} | sed 's/d$/D/; s/rp$/RP/; s/rp+/RP+/')
    getDSM "${MODEL}" "${A}"
done <<<$(cat "${TMP_PATH}/modellist")
cp -f "${TMP_PATH}/dsmdata.yml" "${HOME}/dsmdata.yml"
# Cleanup DSM Files
rm -rf "${CACHE_PATH}/dl"
rm -rf "${CONFIGS}"
rm -rf "${TMP_PATH}"
