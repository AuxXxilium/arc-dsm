#!/usr/bin/bash

function readConfigEntriesArray() {
  yq eval '.'${1}' | explode(.) | to_entries | map([.key])[] | .[]' "${2}"
}

function extract_pat_info_from_rss() {
    local xml_file="$1"
    local productver="$2"
    local model="$3"
    awk -v pv="$productver" -v mdl="$model" '
    /<mLink>/ {
        match($0, /<mLink>([^<]*)<\/mLink>/, arr)
        pat_url = arr[1]
        # Check for model (case-insensitive) and version in the URL
        model_pat = tolower(mdl)
        url_pat = tolower(pat_url)
        if (index(url_pat, model_pat) > 0) {
            if (match(pat_url, /\/release\/([0-9]+\.[0-9]+(\.[0-9]+)?)\//, verarr)) {
                urlver = verarr[1]
                split(urlver, v, ".")
                urlver_prefix = v[1] "." v[2]
                if (urlver_prefix == pv) {
                    getline
                    match($0, /<mCheckSum>([^<]*)<\/mCheckSum>/, arr)
                    pat_hash = arr[1]
                    if (pat_url != "" && pat_hash != "") {
                        print pat_url "|" pat_hash "|" urlver
                    }
                }
            }
        }
    }
    ' "$xml_file"
}

function getDSM() {
    MODEL="${1}"
    MODELURL=$(echo "${MODEL}" | sed 's/d$/D/; s/rp$/RP/; s/rp+/RP+/; s/+/%2B/')
    PLATFORM="${2}"
    PRODUCTVERS="$(readConfigEntriesArray "platforms.${PLATFORM}.productvers" "${P_FILE}" | sort -r)"
    echo "${PRODUCTVERS}" >"${TMP_PATH}/productvers"
    while read -r line; do
        PRODUCTVER="${line}"
        extract_pat_info_from_rss "$GENRSS_XML" "$PRODUCTVER" "$MODELURL" | while IFS="|" read -r PAT_URL PAT_HASH URLVER; do
            PAT_FILE="${MODEL}_${URLVER}.pat"
            PAT_PATH="${CACHE_PATH}/dl/${PAT_FILE}"
            UNTAR_PAT_PATH="${CACHE_PATH}/${MODEL}/${URLVER}"
            DESTINATION="${DSMPATH}/${MODEL}/${URLVER}"
            DESTINATIONFILES="${FILESPATH}/${MODEL}/${PRODUCTVER}"
            # Make Destinations
            mkdir -p "${DESTINATION}"
            mkdir -p "${DESTINATIONFILES}"
            echo "${MODEL} ${PRODUCTVER} (${URLVER})"
            echo "${PAT_URL}"
            echo "${PAT_HASH}"
            if ! grep -q "${PAT_HASH}" "${TMP_PATH}/data.yml"; then
                echo "    \"${URLVER}\":" >>"${TMP_PATH}/data.yml"
                echo "      url: \"${PAT_URL}\"" >>"${TMP_PATH}/data.yml"
                echo "      hash: \"${PAT_HASH}\"" >>"${TMP_PATH}/data.yml"
                echo "" >>"${TMP_PATH}/webdata.txt"
                echo "${MODEL} ${PRODUCTVER} (${URLVER})" >>"${TMP_PATH}/webdata.txt"
                echo "Url: ${PAT_URL}" >>"${TMP_PATH}/webdata.txt"
                echo "Hash: ${PAT_HASH}" >>"${TMP_PATH}/webdata.txt"
            else
                echo "PAT: ${PAT_HASH} already exists in data.yml. Skipping export."
            fi
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
                    cp "${UNTAR_PAT_PATH}/VERSION"         "${DESTINATION}"
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
        done
    done < <(cat "${TMP_PATH}/productvers")
    rm -f "${TMP_PATH}/productvers"
}

# Init DSM Files
HOME=$(pwd)
CONFIGS="./configs"
TMP_PATH="${HOME}/data"
CACHE_PATH="${HOME}/cache"
RAMDISK_PATH="${CACHE_PATH}/ramdisk"
EXTRACTOR_PATH="${HOME}/extractor"
EXTRACTOR_BIN="syno_extract_system_patch"
DSMPATH="${HOME}/dsm"
FILESPATH="${HOME}/files"
rm -rf "${TMP_PATH}"
rm -rf "${CONFIGS}"
mkdir -p "${TMP_PATH}"
mkdir -p "${CACHE_PATH}"
mkdir -p "${CONFIGS}"
touch "${TMP_PATH}/data.yml"
touch "${TMP_PATH}/webdata.txt"
TAG="$(curl --insecure -m 5 -s https://api.github.com/repos/AuxXxilium/arc-configs/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}')"
curl --insecure -s -w "%{http_code}" -L "https://github.com/AuxXxilium/arc-configs/releases/download/${TAG}/configs-${TAG}.zip" -o "./configs.zip"
unzip -oq "./configs.zip" -d "${CONFIGS}" >/dev/null 2>&1
rm -f "configs.zip"
P_FILE="${CONFIGS}/platforms.yml"
PS="$(readConfigEntriesArray "platforms" "${P_FILE}" | sort)"
MJ="$(python scripts/functions.py getmodels -p "${PS[*]}")"
echo -n "" >"${TMP_PATH}/modellist"
echo "${MJ}" | jq -c '.[]' | while IFS= read -r item; do
    name=$(echo "$item" | jq -r '.name')
    arch=$(echo "$item" | jq -r '.arch')
    echo "${name} ${arch}" >>"${TMP_PATH}/modellist"
done
GENRSS_URL="https://update7.synology.com/autoupdate/genRSS.php?include_beta=1"
GENRSS_XML="${CACHE_PATH}/genRSS.xml"
curl -skL "$GENRSS_URL" -o "$GENRSS_XML"
PREA=""
while read -r M A; do
    MODEL=$(echo ${M} | sed 's/d$/D/; s/rp$/RP/; s/rp+/RP+/')
    if [ "${PREA}" != "${A}" ] && [ "${A}" != "" ] && [ "${A}" != "null" ]; then
        echo "${A}:" >>"${TMP_PATH}/data.yml"
        PREA="${A}"
    fi
    if [ "${MODEL}" != "" ] && [ "${MODEL}" != "null" ]; then
        echo "  \"${MODEL}\":" >>"${TMP_PATH}/data.yml"
        getDSM "${MODEL}" "${A}"
    fi
    git config --global user.email "info@auxxxilium.tech"
    git config --global user.name "AuxXxilium"
    git fetch
    git add "${HOME}/dsm/${MODEL}"
    git add "${HOME}/files/${MODEL}"
    git commit -m "${MODEL}: update $(date +%Y-%m-%d" "%H:%M:%S)"
    git push
done < <(cat "${TMP_PATH}/modellist")
cp -f "${TMP_PATH}/webdata.txt" "${HOME}/webdata.txt"
cp -f "${TMP_PATH}/data.yml" "${HOME}/data.yml"
# Cleanup DSM Files
rm -rf "${CACHE_PATH}"
rm -rf "${TMP_PATH}"
rm -rf "${CONFIGS}"