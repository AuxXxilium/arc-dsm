# -*- coding: utf-8 -*-
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

import os, re, sys, glob, json, yaml, click, shutil, tarfile, kmodule, requests, urllib3
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry  # type: ignore
import xml.etree.ElementTree as ET

@click.group()
def cli():
    """
    The CLI is a commands to Arc.
    """
    pass

@cli.command()
@click.option("-w", "--workpath", type=str, required=True, help="The workpath of Arc.")
@click.option("-j", "--jsonpath", type=str, required=True, help="The output path of yaml file.")
def getpats(workpath, jsonpath):
    def __fullversion(major, minor, patch, build, phase):
        return f"{major}.{minor}.{patch}-{build}-{phase}"

    # Load platforms.yml and build model->platform mapping
    platforms_yml = os.path.join(workpath, "configs", "platforms.yml")
    with open(platforms_yml, "r") as f:
        platforms_data = yaml.safe_load(f)
        platforms = platforms_data.get("platforms", {})

    # Fetch and parse the XML feed
    url = "http://update7.synology.com/autoupdate/genRSS.php?include_beta=1"
    try:
        # Use an adapter for both http and https, disable environment proxies (can hang if proxy broken),
        # and disable SSL verification/warnings for Synology endpoints which sometimes present cert issues.
        adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1, status_forcelist=[500, 502, 503, 504]))
        session = requests.Session()
        session.mount("http://", adapter)
        session.mount("https://", adapter)
        session.trust_env = False
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

        req = session.get(url, timeout=10, verify=False)
        req.encoding = "utf-8"
        root = ET.fromstring(req.text)
    except requests.exceptions.SSLError as e:
        click.echo(f"SSL Error: {e}")
        return
    except Exception as e:
        click.echo(f"Error fetching or parsing XML: {e}")
        return

    # Parse XML and build model->platform mapping
    pats = {}
    for item in root.findall(".//item"):
        major_ver = item.find("MajorVer").text
        minor_ver = item.find("MinorVer").text
        build_num = item.find("BuildNum").text
        build_phase = item.find("BuildPhase").text

        # Extract the patch version from the mLink URL
        m_link = item.find("model/mLink").text
        patch_ver_match = re.search(r"/(\d+\.\d+\.\d+)/", m_link)
        patch_ver = patch_ver_match.group(1).split(".")[-1] if patch_ver_match else "0"

        # Skip versions below 7
        if int(major_ver) < 7:
            continue

        version = __fullversion(major_ver, minor_ver, patch_ver, build_num, build_phase)

        for model in item.findall("model"):
            m_unique = model.find("mUnique").text
            m_link = model.find("mLink").text
            m_checksum = model.find("mCheckSum").text or "0" * 32

            # Extract architecture and model name
            if "_" not in m_unique:
                continue
            arch = m_unique.split("_")[1]
            model_name = m_link.split("/")[-1].split("_")[1].replace("%2B", "+")

            if arch not in platforms:
                continue

            # Initialize data structure
            if arch not in pats:
                pats[arch] = {}
            if model_name not in pats[arch]:
                pats[arch][model_name] = {}

            # Add version details
            pats[arch][model_name][version] = {
                "url": m_link,
                "hash": m_checksum
            }

    # -- begin: add Synology API helper functions (findDownloadInfo / findUpgradeSteps)
    urlInfo = "https://www.synology.com/api/support/findDownloadInfo?lang=en-us"
    urlSteps = "https://www.synology.com/api/support/findUpgradeSteps?"

    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    def _build_info_url(product, ver=None):
        prod = product.replace('+', '%2B')
        if not ver:
            return f"{urlInfo}&product={prod}"
        parts = ver.split('.')
        major = f"&major={parts[0]}" if len(parts) > 0 and parts[0] != "" else ""
        minor = f"&minor={parts[1]}" if len(parts) > 1 else ""
        return f"{urlInfo}&product={prod}{major}{minor}"

    def _add_patch_entry(patches, arch, model, build_ver, build_num, nano, url, checksum):
        # build_ver like "7.2.1" -> major, minor, patch
        try:
            a, b, c = (build_ver.split('.') + ['0', '0', '0'])[:3]
        except Exception:
            a, b, c = '7', '0', '0'
        phase = str(nano or "0")
        if arch not in patches:
            patches[arch] = {}
        if model not in patches[arch]:
            patches[arch][model] = {}
        V = __fullversion(a, b, c, str(build_num or ""), phase)
        if V not in patches[arch][model]:
            patches[arch][model][V] = {
                "url": (url or "").split('?')[0],
                "hash": checksum or ("0" * 32)
            }

    def fetch_product_patches(session, product, arch, version_prefix="7"):
        """
        Query Synology API endpoints for a given product/model and return a dict
        of patches keyed by version string compatible with __fullversion.

        NOTE: filter out non-DSM products (e.g. app versions like "1.3.1") by
        requiring build_ver to start with version_prefix (default "7").
        """
        result = {}
        try:
            info_url = _build_info_url(product, version_prefix)
            req = session.get(info_url, timeout=10, verify=False)
            req.encoding = "utf-8"
            info = json.loads(req.text)
        except Exception:
            return result

        # primary items from findDownloadInfo
        try:
            items = info.get('info', {}).get('system', {}).get('detail', [])[0].get('items', [])
            for it in items:
                build_ver = it.get('build_ver', '') or ''
                # skip non-DSM builds (e.g. app versions like "1.3.1")
                if not build_ver.startswith(str(version_prefix)):
                    continue
                files = it.get('files') or []
                if not files:
                    continue
                file0 = files[0]
                _add_patch_entry(result, arch, product,
                                 build_ver, it.get('build_num', ''), it.get('nano', ''),
                                 file0.get('url', ''), file0.get('checksum', ''))
        except Exception:
            pass

        # determine from_ver for upgrade steps
        from_ver = None
        try:
            pubVers = info.get('info', {}).get('pubVers', [])
            if pubVers:
                # choose minimum build number available
                builds = [p.get('build') for p in pubVers if p.get('build')]
                if builds:
                    from_ver = min(builds)
        except Exception:
            from_ver = None

        # iterate productVers -> versions -> request upgrade steps
        for pv in info.get('info', {}).get('productVers', []):
            verstr = pv.get('version', '')
            if not verstr.startswith(str(version_prefix)):
                continue

            # sometimes need to fetch per-major/minor product info
            try:
                ver_parts = verstr.split('.')
                majorTmp = f"&major={ver_parts[0]}" if len(ver_parts) > 0 else ""
                minorTmp = f"&minor={ver_parts[1]}" if len(ver_parts) > 1 else ""
                reqTmp = session.get(f"{urlInfo}&product={product.replace('+', '%2B')}{majorTmp}{minorTmp}", timeout=10, verify=False)
                reqTmp.encoding = "utf-8"
                dataTmp = json.loads(reqTmp.text)
                itemsTmp = dataTmp.get('info', {}).get('system', {}).get('detail', [])[0].get('items', [])
                for it in itemsTmp:
                    build_ver = it.get('build_ver', '') or ''
                    # skip non-DSM builds
                    if not build_ver.startswith(str(version_prefix)):
                        continue
                    files = it.get('files') or []
                    if not files:
                        continue
                    file0 = files[0]
                    _add_patch_entry(result, arch, product,
                                     build_ver, it.get('build_num', ''), it.get('nano', ''),
                                     file0.get('url', ''), file0.get('checksum', ''))
            except Exception:
                pass

            # upgrade steps between from_ver and each target build
            for verobj in pv.get('versions', []):
                to_ver = verobj.get('build')
                if not from_ver or not to_ver:
                    continue
                try:
                    reqSteps = session.get(f"{urlSteps}&product={product.replace('+', '%2B')}&from_ver={from_ver}&to_ver={to_ver}", timeout=10, verify=False)
                    if reqSteps.status_code != 200:
                        continue
                    reqSteps.encoding = "utf-8"
                    dataSteps = json.loads(reqSteps.text)
                except Exception:
                    continue

                for S in dataSteps.get('upgrade_steps', []):
                    if not S.get('full_patch'):
                        continue
                    build_ver = S.get('build_ver', '') or ''
                    # ensure upgrade step is a DSM build matching prefix
                    if not build_ver.startswith(str(version_prefix)):
                        continue
                    files = S.get('files') or []
                    if not files:
                        continue
                    file0 = files[0]
                    # optional HEAD check for availability
                    try:
                        head = session.head((file0.get('url') or "").split('?')[0], timeout=10, verify=False)
                        if head.status_code == 403:
                            continue
                    except Exception:
                        pass
                    _add_patch_entry(result, arch, product,
                                     build_ver, S.get('build_num', ''), S.get('nano', ''),
                                     file0.get('url', ''), S.get('checksum', ''))

        return result

    # Merge API-derived patches into pats built from RSS
    try:
        # build a simple model->arch map from pats
        model_arch = {}
        for a in list(pats.keys()):
            for m in list(pats[a].keys()):
                model_arch[m] = a

        for model_name, arch in model_arch.items():
            try:
                api_patches = fetch_product_patches(session, model_name, arch, version_prefix="7")
                for V, info in api_patches.get(arch, {}).get(model_name, {}).items():
                    if arch not in pats:
                        pats[arch] = {}
                    if model_name not in pats[arch]:
                        pats[arch][model_name] = {}
                    if V not in pats[arch][model_name]:
                        pats[arch][model_name][V] = info
            except Exception:
                # non-fatal, continue with other models
                continue
    except Exception:
        pass
    # -- end: Synology API helpers and merge

    # Write as YAML in the requested format
    class QuotedStr(str): pass

    def quoted_presenter(dumper, data):
        return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='"')

    yaml.add_representer(QuotedStr, quoted_presenter)

    def quote_models_versions(obj, level=0):
        if isinstance(obj, dict):
            if level == 1 or level == 2:  # model or version level
                return {QuotedStr(str(k)): quote_models_versions(v, level + 1) for k, v in obj.items()}
            elif level == 3:  # url/hash dict
                return {k: QuotedStr(str(v)) if k in ("url", "hash") else v for k, v in obj.items()}
            else:
                return {k: quote_models_versions(v, level + 1) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [quote_models_versions(i, level) for i in obj]
        else:
            return obj

    if jsonpath:
        with open(jsonpath, "w", encoding="utf-8") as f:
            yaml.dump(quote_models_versions(pats), f, indent=2, allow_unicode=True, sort_keys=False)

if __name__ == "__main__":
    cli()