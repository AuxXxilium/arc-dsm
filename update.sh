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
        SYNOINFO="${DESTINATION}/synoinfo.yml"

        PAT_MODEL="$(echo "${MODEL}" | sed -e 's/\./%2E/g' -e 's/+/%2B/g')"
        PAT_MAJOR="$(echo "${VERSION}" | cut -b 1)"
        PAT_MINOR="$(echo "${VERSION}"  | cut -b 3)"
        
        echo "${MODEL} ${VERSION}"

        curl -skL "https://www.synology.com/api/support/findDownloadInfo?lang=en-us&product=${PAT_MODEL}&major=${PAT_MAJOR}&minor=${PAT_MINOR}" >"${SYNOINFO}"
        PAT_URL=$(cat "${SYNOINFO}" | jq -r '.info.system.detail[0].items[0].files[0].url')
        HASH=$(cat "${SYNOINFO}" | jq -r '.info.system.detail[0].items[0].files[0].checksum')
        echo "${PAT_URL} ${HASH}"
        PAT_URL=${PAT_URL%%\?*}
        
        OLDURL="$(cat "${DESTINATION}/pat_url")"
        OLDHASH="$(cat "${DESTINATION}/pat_hash")"

        if [ "${HASH}" != "${OLDHASH}" ] || [ "${PAT_URL}" != "${OLDURL}" ]; then

            echo "${HASH}" >"${DESTINATION}/pat_hash"
            echo "${PAT_URL}" >"${DESTINATION}/pat_url"

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

            echo -n "Checking hash of zImage: "
            HASH=$(sha256sum ${UNTAR_PAT_PATH}/zImage | awk '{print$1}')
            echo "OK"
            echo "${HASH}" >"${DESTINATION}/zImage_hash"

            echo -n "Checking hash of ramdisk: "
            HASH=$(sha256sum ${UNTAR_PAT_PATH}/rd.gz | awk '{print$1}')
            echo "OK"
            echo "${HASH}" >"${DESTINATION}/ramdisk_hash"

            echo -n "Copying files: "
            cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${DESTINATION}"
            cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${DESTINATION}"
            cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${DESTINATION}"
            cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${DESTINATION}"
            cp "${UNTAR_PAT_PATH}/zImage"          "${DESTINATION}"
            cp "${UNTAR_PAT_PATH}/rd.gz"           "${DESTINATION}"
            cd "${DESTINATION}"
            tar -cf "${DESTINATIONFILES}/dsm.tar" .
            rm -f "${PAT_PATH}"
            rm -rf "${UNTAR_PAT_PATH}"
            echo "DSM extract complete: ${MODEL}_${BUILD}"
        else
            echo "DSM extract Error: ${MODEL}_${BUILD}"
        fi
        cd ${HOME}
    done <"${VERSIONSFILE}"
    rm -f "${VERSIONSFILE}"
}

HOME=$(pwd)
CONFIGS="./configs"
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

rm -rf "${CACHE_PATH}/dl"