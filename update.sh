#!/usr/bin/bash
HOME=$(pwd)
MODELSFILE="models.yml"

while IFS= read -r line; do
    VERSION=`echo "${line}" | cut -f 1 -d ' '`
    BUILD=`echo "${line}" | cut -f 2 -d ' '`
    MODEL=`echo "${line}" | cut -f 3 -d ' '`
    PAT_BUILD=`echo "${line}" | cut -f 4 -d ' '`
    CACHE_PATH="${HOME}/cache"
    RAMDISK_PATH="${CACHE_PATH}/ramdisk"
    PAT_FILE="${MODEL}_${BUILD}.pat"
    PAT_PATH="${CACHE_PATH}/dl/${PAT_FILE}"
    EXTRACTOR_PATH="${CACHE_PATH}/extractor"
    EXTRACTOR_BIN="syno_extract_system_patch"
    UNTAR_PAT_PATH="${CACHE_PATH}/${MODEL}/${BUILD}"
    DSMPATH="${HOME}/dsm"
    DESTINATION="${DSMPATH}/${MODEL}/${BUILD}"
    FILESPATH="${HOME}/files"
    DESTINATIONFILES="${FILESPATH}/${MODEL}/${BUILD}"

    PAT_MODEL=`echo "${MODEL}" | sed 's/ /%20/'`
    echo "${PAT_MODEL} ${VERSION} ${BUILD}"
    
    PAT_LINK="${VERSION}/${BUILD}/DSM_${MODEL}_${PAT_BUILD}.pat"
    PAT_URL="https://global.synologydownload.com/download/DSM/release/${PAT_LINK}"
    echo "${PAT_URL}"

    speed_a=`ping -c 1 -W 5 global.synologydownload.com | awk '/time=/ {print $7}' | cut -d '=' -f 2`
    speed_b=`ping -c 1 -W 5 global.download.synology.com | awk '/time=/ {print $7}' | cut -d '=' -f 2`
    fastest="`echo -e "global.synologydownload.com ${speed_a:-999}\nglobal.download.synology.com ${speed_b:-999}" | sort -k2rn | head -1 | awk '{print $1}'`"
    
    mirror="`echo ${PAT_URL} | sed 's|^http[s]*://\([^/]*\).*|\1|'`"
    echo "`printf "Based on the current network situation, switch to %s mirror for download." "${fastest}"`"
    PAT_URL="`echo ${PAT_URL} | sed "s/${mirror}/${fastest}/"`"
    
    rm -rf "${CACHE_PATH}/dl"
    mkdir -p "${CACHE_PATH}/dl"

    echo "Downloading ${PAT_FILE}"
    # Discover remote file size
    STATUS=`curl -k -w "%{http_code}" -L "${PAT_URL}" -o "${PAT_PATH}" --progress-bar`
    if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
        rm "${PAT_PATH}"
        echo "Error downloading"
    fi
    if [ -f "${PAT_PATH}" ]; then
        rm -rf "${UNTAR_PAT_PATH}"
        mkdir -p "${UNTAR_PAT_PATH}"
        echo -n "Disassembling ${PAT_FILE}: "

        header=`od -bcN2 ${PAT_PATH} | head -1 | awk '{print $3}'`
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

        mkdir -p "${DESTINATION}"
        mkdir -p "${DESTINATIONFILES}"

        echo -n "Checking hash of zImage: "
        HASH="`sha256sum ${UNTAR_PAT_PATH}/zImage | awk '{print$1}'`"
        echo "OK"
        echo "${HASH}" > "${DESTINATION}/zImage_hash"

        echo -n "Checking hash of ramdisk: "
        HASH="`sha256sum ${UNTAR_PAT_PATH}/rd.gz | awk '{print$1}'`"
        echo "OK"
        echo "${HASH}" > "${DESTINATION}/ramdisk_hash"

        echo -n "Copying files: "
        cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${DESTINATION}"
        cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${DESTINATION}"
        cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${DESTINATION}"
        cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${DESTINATION}"
        cp "${UNTAR_PAT_PATH}/zImage"          "${DESTINATION}"
        cp "${UNTAR_PAT_PATH}/rd.gz"           "${DESTINATION}"
        cd "${DESTINATION}"
        tar -cf "${DESTINATIONFILES}/dsm.tar" .
        cd 
        rm -rf "${UNTAR_PAT_PATH}"
        echo "DSM extract complete: ${MODEL}_${BUILD}"
    else
        echo "DSM extract Error: ${MODEL}_${BUILD}"
    fi
    cd ${HOME}
done < ${MODELSFILE}