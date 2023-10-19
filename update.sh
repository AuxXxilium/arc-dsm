#!/usr/bin/bash

function readConfigEntriesArray() {
  yq eval '.'${1}' | explode(.) | to_entries | map([.key])[] | .[]' "${2}"
}

function getDSM() {
    VERSIONS="$(readConfigEntriesArray "productvers" "${CONFIGS}/${MODEL}.yml" | sort -r)"
    echo "${VERSIONS}" >"${VERSIONSFILE}"
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
        # Grep PAT_URL
        PAT_URL="$(curl -skL "https://www.synology.com/api/support/findDownloadInfo?lang=en-us&product=${MODEL/+/%2B}&major=${VERSION%%.*}&minor=${VERSION##*.}" | jq -r '.info.system.detail[0].items[0].files[0].url')"
        PAT_HASH="$(curl -skL "https://www.synology.com/api/support/findDownloadInfo?lang=en-us&product=${MODEL/+/%2B}&major=${VERSION%%.*}&minor=${VERSION##*.}" | jq -r '.info.system.detail[0].items[0].files[0].checksum')"
        PAT_URL="${PAT_URL%%\?*}"
        echo "${PAT_URL}"
        echo "${PAT_HASH}"
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
    done <"${VERSIONSFILE}"
    rm -f "${VERSIONSFILE}"
}

# Init DSM Files
HOME=$(pwd)
CONFIGS="./configs"
rm -f "${CONFIGS}"
mkdir -p "${CONFIGS}"
git clone https://github.com/AuxXxilium/arc-configs -b dev "${CONFIGS}"
while read MODEL; do
    MODEL="$(basename ${MODEL})"
    MODEL="${MODEL::-4}"
    CACHE_PATH="${HOME}/cache"
    RAMDISK_PATH="${CACHE_PATH}/ramdisk"
    EXTRACTOR_PATH="${CACHE_PATH}/extractor"
    EXTRACTOR_BIN="syno_extract_system_patch"
    DSMPATH="${HOME}/dsm"
    FILESPATH="${HOME}/files"
    VERSIONSFILE="${CACHE_PATCH}/versions.yml"
    getDSM
done < <(find "${CONFIGS}" -maxdepth 1 -name \*.yml | sort)
# Cleanup DSM Files
rm -rf "${CACHE_PATH}/dl"
rm -rf "${CONFIGS}"