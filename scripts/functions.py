# -*- coding: utf-8 -*-
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

import os, re, sys, glob, json, yaml, click, shutil, tarfile, kmodule, requests, urllib3
from urllib.parse import unquote
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

    def __version_at_least(major, minor, req_major=7, req_minor=2):
        try:
            return (int(major), int(minor)) >= (int(req_major), int(req_minor))
        except Exception:
            return False

    def __buildver_at_least(build_ver, req_major=7, req_minor=2):
        try:
            parts = str(build_ver or "").split(".")
            major = int(parts[0]) if len(parts) > 0 else 0
            minor = int(parts[1]) if len(parts) > 1 else 0
            return (major, minor) >= (int(req_major), int(req_minor))
        except Exception:
            return False

    def __is_dsm_family_link(link):
        link_l = str(link or "").lower()
        return "/download/dsm/release/" in link_l or "/download/dsm_enterprise/release/" in link_l

    def __load_known_arches(base_path):
        """
        Load known architecture keys from arc-configs platforms.yml when available.
        """
        known = set()
        candidates = [
            os.path.join(base_path, "configs", "platforms.yml"),
            os.path.join(base_path, "platforms.yml"),
        ]
        for path in candidates:
            try:
                if not os.path.exists(path):
                    continue
                with open(path, "r", encoding="utf-8") as f:
                    data = yaml.safe_load(f) or {}
                platforms = data.get("platforms", {}) if isinstance(data, dict) else {}
                if isinstance(platforms, dict):
                    for k in platforms.keys():
                        known.add(str(k).strip().lower())
                if known:
                    break
            except Exception:
                continue
        return known

    def __extract_arch(m_unique, known_arches):
        """
        Extract arch from mUnique robustly.
        Preferred: any token that matches known platforms keys.
        Fallback: legacy synology_<arch>_* format.
        """
        s = str(m_unique or "").strip().lower()
        if not s:
            return ""
        tokens = [t for t in re.split(r"[_\-\s]+", s) if t]
        if known_arches:
            for t in tokens:
                if t in known_arches:
                    return t
        if len(tokens) >= 2:
            return tokens[1]
        return ""

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

    known_arches = __load_known_arches(workpath)

    # Parse XML and build model->platform mapping
    pats = {}
    for item in root.findall(".//item"):
        major_ver = (item.findtext("MajorVer") or "0").strip()
        minor_ver = (item.findtext("MinorVer") or "0").strip()
        build_num = (item.findtext("BuildNum") or "0").strip()
        build_phase = (item.findtext("BuildPhase") or "0").strip()

        # Extract the patch version from the mLink URL
        m_link = item.findtext("model/mLink") or ""
        if not __is_dsm_family_link(m_link):
            continue
        patch_ver_match = re.search(r"/(\d+\.\d+\.\d+)/", m_link)
        patch_ver = patch_ver_match.group(1).split(".")[-1] if patch_ver_match else "0"

        # Keep only DSM 7.2 and above
        if not __version_at_least(major_ver, minor_ver, 7, 2):
            continue

        version = __fullversion(major_ver, minor_ver, patch_ver, build_num, build_phase)

        for model in item.findall("model"):
            m_unique = model.findtext("mUnique") or ""
            m_link = model.findtext("mLink") or ""
            if not __is_dsm_family_link(m_link):
                continue
            m_checksum = model.findtext("mCheckSum") or "0" * 32

            # Extract architecture and model name
            arch = __extract_arch(m_unique, known_arches)
            if not arch:
                continue

            # PAT names are usually DSM_<MODEL>_<BUILD>.pat, but Enterprise uses
            # DSM_Enterprise_<MODEL>_<BUILD>.pat. Join middle tokens and strip the
            # Enterprise prefix so both formats map to the real model.
            pat_name = unquote(m_link.split("/")[-1]).replace(".pat", "")
            parts = pat_name.split("_")
            if len(parts) < 3:
                continue
            model_name = "_".join(parts[1:-1])
            if model_name.startswith("Enterprise_"):
                model_name = model_name[len("Enterprise_"):]

            # Always skip architectures Arc doesn't know about.
            # In supported-models-only mode also restrict to listed model names.
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

    def fetch_product_patches(session, product, arch, version_prefix="7", min_major=7, min_minor=2):
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
                if not __buildver_at_least(build_ver, min_major, min_minor):
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
            if not __buildver_at_least(f"{verstr}.0", min_major, min_minor):
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
                    if not __buildver_at_least(build_ver, min_major, min_minor):
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
                    if not __buildver_at_least(build_ver, min_major, min_minor):
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
                api_patches = fetch_product_patches(session, model_name, arch, version_prefix="7", min_major=7, min_minor=2)
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

    # -- Synology archive scraper: pick up versions not yet in the RSS feed --
    # Static model->arch fallback covering all models shipped through DSM 7.x.
    # Derived from the Synology RSS mUnique field and maintained alongside platforms.yml.
    # Where a model maps to multiple platforms (e.g. v1000 and v1000nk), both are listed
    # as separate entries — the archive scraper injects into whichever arch is in known_arches.
    _ARCHIVE_MODEL_ARCH_MULTI = [
        # apollolake
        ("DS116", "apollolake"), ("DS118", "apollolake"), ("DS119j", "apollolake"),
        ("DS120j", "apollolake"), ("DS1019+", "apollolake"), ("DS218+", "apollolake"),
        ("DS418play", "apollolake"), ("DS620slim", "apollolake"),
        ("DS718+", "apollolake"), ("DS918+", "apollolake"),
        # broadwell
        ("DS216", "broadwell"), ("DS216+", "broadwell"), ("DS216+II", "broadwell"),
        ("DS216j", "broadwell"), ("DS216play", "broadwell"),
        ("DS218", "broadwell"), ("DS218j", "broadwell"), ("DS218play", "broadwell"),
        ("DS220j", "broadwell"),
        ("DS416", "broadwell"), ("DS416j", "broadwell"), ("DS416play", "broadwell"),
        ("DS416slim", "broadwell"), ("DS418", "broadwell"), ("DS418j", "broadwell"),
        ("DS419slim", "broadwell"), ("DS420j", "broadwell"),
        ("DS716+", "broadwell"), ("DS716+II", "broadwell"),
        ("DS3617xs", "broadwell"), ("DS3617xsII", "broadwell"),
        ("RS18016xs+", "broadwell"), ("RS217", "broadwell"), ("RS816", "broadwell"),
        ("RS818+", "broadwell"), ("RS818RP+", "broadwell"), ("RS819", "broadwell"),
        ("RS1219+", "broadwell"), ("RS2416+", "broadwell"), ("RS2416RP+", "broadwell"),
        ("RS3617RPxs", "broadwell"), ("RS3617xs", "broadwell"), ("RS3617xs+", "broadwell"),
        # broadwellnk
        ("DS1621xs+", "broadwellnk"), ("DS3018xs", "broadwellnk"),
        ("DS3622xs+", "broadwellnk"), ("FS1018", "broadwellnk"),
        ("FS3400", "broadwellnk"), ("FS3600", "broadwellnk"),
        ("RS1619xs+", "broadwellnk"), ("RS1626xs+", "broadwellnk"),
        ("RS3618xs", "broadwellnk"), ("RS3621RPxs", "broadwellnk"),
        ("RS3621xs+", "broadwellnk"), ("RS4017xs+", "broadwellnk"),
        ("RS4021xs+", "broadwellnk"), ("SA3400", "broadwellnk"), ("SA3600", "broadwellnk"),
        # broadwellnkv2
        ("DS3626xs", "broadwellnkv2"), ("RS3626xs", "broadwellnkv2"),
        ("RS4826xs+", "broadwellnkv2"), ("RS6426xs+", "broadwellnkv2"),
        ("SA3410", "broadwellnkv2"), ("SA3610", "broadwellnkv2"),
        # broadwellntbap
        ("FS200T", "broadwellntbap"), ("FS2017", "broadwellntbap"),
        ("FS3017", "broadwellntbap"), ("FS6400", "broadwellntbap"),
        ("FS6420", "broadwellntbap"), ("HD6500", "broadwellntbap"),
        ("SA3200D", "broadwellntbap"), ("SA3400D", "broadwellntbap"),
        # denverton
        ("DS1618+", "denverton"), ("DS1819+", "denverton"),
        ("DS2419+", "denverton"), ("DS2419+II", "denverton"),
        ("DVA3219", "denverton"), ("DVA3221", "denverton"),
        ("RS18017xs+", "denverton"), ("RS2418+", "denverton"), ("RS2418RP+", "denverton"),
        ("RS2818RP+", "denverton"), ("RS820+", "denverton"), ("RS820RP+", "denverton"),
        # geminilake
        ("DS124", "geminilake"), ("DS220+", "geminilake"), ("DS224+", "geminilake"),
        ("DS420+", "geminilake"), ("DS423", "geminilake"), ("DS423+", "geminilake"),
        ("DS1520+", "geminilake"), ("DS720+", "geminilake"), ("DS920+", "geminilake"),
        ("DVA1622", "geminilake"),
        # geminilakenk
        ("DS223", "geminilakenk"), ("DS223j", "geminilakenk"),
        ("DS225+", "geminilakenk"), ("DS425+", "geminilakenk"),
        ("DS725+", "geminilakenk"), ("DS925+", "geminilakenk"),
        ("RS826+", "geminilakenk"), ("RS826RP+", "geminilakenk"),
        # purley
        ("FS3410", "purley"),
        # r1000
        ("DS422+", "r1000"), ("DS522+", "r1000"), ("DS723+", "r1000"),
        ("DS923+", "r1000"), ("DS1522+", "r1000"), ("RS422+", "r1000"),
        # r1000nk
        ("DS1525+", "r1000nk"), ("DS1825+", "r1000nk"),
        ("RS2423+", "r1000nk"), ("RS2423RP+", "r1000nk"), ("RS2423RP+II", "r1000nk"),
        ("RS2825RP+", "r1000nk"),
        # v1000
        ("DS1621+", "v1000"), ("DS1821+", "v1000"), ("DS1823xs+", "v1000"),
        ("DS2422+", "v1000"), ("FS2500", "v1000"),
        ("RS1221+", "v1000"), ("RS1221RP+", "v1000"),
        ("RS2421+", "v1000"), ("RS2421RP+", "v1000"), ("RS2821RP+", "v1000"),
        ("RS822+", "v1000"), ("RS822RP+", "v1000"),
        # v1000nk
        ("DS1525+", "v1000nk"), ("DS1825+", "v1000nk"),
        ("RS2423RP+II", "v1000nk"), ("RS2825RP+", "v1000nk"),
        # epyc7002
        ("SA6400", "epyc7002"), ("VirtualDSM", "epyc7002"),
        # epyc7003ntb
        ("FS3420", "epyc7003ntb"),
    ]
    # Build a flat dict: last-write wins, but we iterate in order so more-specific
    # (nk) entries placed after the base platform will not override since we use
    # the multi-list directly when injecting archive entries.
    _ARCHIVE_MODEL_ARCH = {}
    for _m, _a in _ARCHIVE_MODEL_ARCH_MULTI:
        if _m not in _ARCHIVE_MODEL_ARCH:
            _ARCHIVE_MODEL_ARCH[_m] = _a

    def _fetch_archive_versions(sess):
        """Return list of (major, minor, patch, build) tuples from the Synology archive index."""
        try:
            r = sess.get("https://archive.synology.com/download/Os/DSM", timeout=15, verify=False)
            r.encoding = "utf-8"
            versions = []
            for m in re.finditer(r'href=["\']?/download/Os/DSM/(\d+)\.(\d+)-(\d+)["\']?', r.text):
                major, minor, build = int(m.group(1)), int(m.group(2)), m.group(3)
                versions.append((major, minor, build))
            return versions
        except Exception:
            return []

    def _fetch_archive_pats_for_version(sess, major, minor, build):
        """
        Fetch .pat file URLs from the archive page for a given DSM release.
        Returns list of (model_name, url) pairs.
        """
        url = f"https://archive.synology.com/download/Os/DSM/{major}.{minor}-{build}"
        try:
            r = sess.get(url, timeout=15, verify=False)
            r.encoding = "utf-8"
        except Exception:
            return []

        results = []
        base = "https://global.synologydownload.com"
        for m in re.finditer(r'href=["\']?(https://[^"\']*|/download/[^"\']*\.pat)["\']?', r.text):
            link = m.group(1)
            if not link.startswith("http"):
                link = base + link
            link = link.split("?")[0]
            if not link.lower().endswith(".pat"):
                continue
            filename = unquote(link.split("/")[-1]).replace(".pat", "")
            parts = filename.split("_")
            if len(parts) < 3:
                continue
            model_name = "_".join(parts[1:-1])
            if model_name.startswith("Enterprise_"):
                model_name = model_name[len("Enterprise_"):]
            results.append((model_name, link))
        return results

    try:
        # Build a merged model->arch multi-list (RSS-derived entries added on top)
        merged_model_arch_multi = list(_ARCHIVE_MODEL_ARCH_MULTI)
        for a in list(pats.keys()):
            for m in list(pats[a].keys()):
                if not any(x == (m, a) for x in merged_model_arch_multi):
                    merged_model_arch_multi.append((m, a))

        archive_versions = _fetch_archive_versions(session)
        for (major, minor, build) in archive_versions:
            if not __version_at_least(major, minor, 7, 2):
                continue
            # patch is "0" — archive pages list full PATs, not patch-only updates
            version_str = __fullversion(major, minor, "0", build, "0")
            # Skip if this version is already fully covered (present for any known model)
            already_have = any(
                version_str in pats.get(a, {}).get(m, {})
                for m, a in merged_model_arch_multi
                if a in pats and m in pats.get(a, {})
            )
            if already_have:
                continue

            pat_entries = _fetch_archive_pats_for_version(session, major, minor, build)
            # Build a lookup from the archive results for quick access
            archive_url_map = {model: url for model, url in pat_entries}
            for model_name, arch in merged_model_arch_multi:
                if arch not in known_arches:
                    continue
                pat_url = archive_url_map.get(model_name)
                if not pat_url:
                    continue
                if arch not in pats:
                    pats[arch] = {}
                if model_name not in pats[arch]:
                    pats[arch][model_name] = {}
                if version_str not in pats[arch][model_name]:
                    pats[arch][model_name][version_str] = {
                        "url": pat_url,
                        "hash": "0" * 32
                    }
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