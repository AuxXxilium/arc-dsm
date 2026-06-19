# -*- coding: utf-8 -*-
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

import os, re, yaml, click, requests, urllib3
from urllib.parse import unquote
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry  # type: ignore
import xml.etree.ElementTree as ET

@click.group()
def cli():
    pass

@cli.command()
@click.option("-w", "--workpath", type=str, required=True, help="Working directory (must contain configs/platforms.yml).")
@click.option("-j", "--jsonpath", type=str, required=True, help="Output YAML file path.")
def getpats(workpath, jsonpath):
    # --- Load supported platforms ---
    platforms_yml = os.path.join(workpath, "configs", "platforms.yml")
    try:
        with open(platforms_yml, "r", encoding="utf-8") as f:
            pcfg = yaml.safe_load(f) or {}
        platforms = pcfg.get("platforms", {}) if isinstance(pcfg, dict) else {}
        supported_platforms = {str(k).strip().lower() for k in platforms.keys()} if isinstance(platforms, dict) else set()
    except Exception as e:
        click.echo(f"Error loading {platforms_yml}: {e}", err=True)
        return

    if not supported_platforms:
        click.echo("No supported platforms found in platforms.yml", err=True)
        return

    # --- Session setup ---
    adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1, status_forcelist=[500, 502, 503, 504]))
    session = requests.Session()
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    session.trust_env = False
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    # --- Step 1: RSS → model->platform map + Enterprise PATs ---
    # model_platforms: lowercase_model -> list of platforms
    # enterprise_pats: list of (platform, cased_model, version_str, url) for DSM_Enterprise
    #   DSM_Enterprise uses a separate "1.x" product version but the dsm/ folder must use
    #   the underlying DSM version (ReqMajorVer.ReqMinorVer.0-build-0) from the RSS item.
    model_platforms = {}
    enterprise_pats = []
    try:
        r = session.get("https://update7.synology.com/autoupdate/genRSS.php?include_beta=1", timeout=15)
        root = ET.fromstring(r.content)
        for item in root.iter("item"):
            req_major = item.findtext("ReqMajorVer") or ""
            req_minor = item.findtext("ReqMinorVer") or ""
            for model in item.iter("model"):
                munique = model.findtext("mUnique") or ""
                mlink   = model.findtext("mLink") or ""
                parts = munique.strip().split("_")
                if len(parts) < 3 or parts[0] != "synology":
                    continue
                platform = parts[1].lower()
                if platform not in supported_platforms:
                    continue
                model_original = "_".join(parts[2:])
                model_key = model_original.lower()
                if platform not in model_platforms.get(model_key, []):
                    model_platforms.setdefault(model_key, []).append(platform)
                # DSM_Enterprise: build version string from ReqMajorVer.ReqMinorVer + build in URL
                if "/download/dsm_enterprise/" in mlink.lower() and req_major and req_minor:
                    # URL: .../DSM_Enterprise/release/1.0/101188/DSM_Enterprise_PAS7700_101188.pat
                    m = re.search(r'/release/[^/]+/(\d+)/', mlink)
                    if m:
                        build = m.group(1)
                        version_str = f"{req_major}.{req_minor}.0-{build}-0"
                        url = mlink.replace("global.synologydownload.com", "global.download.synology.com")
                        # Extract casing from PAT filename in the URL
                        fname = unquote(mlink.split("/")[-1]).replace(".pat", "")
                        fparts = fname.split("_")
                        cased = "_".join(fparts[1:-1])
                        if cased.lower().startswith("enterprise_"):
                            cased = cased[len("Enterprise_"):]
                        enterprise_pats.append((platform, cased, version_str, url))
    except Exception as e:
        click.echo(f"Error fetching RSS: {e}", err=True)
        return

    if not model_platforms:
        click.echo("No models found in RSS feed", err=True)
        return

    # --- Step 2: collect all archive pages to scrape ---
    # Each entry is (page_url, version_str) where version_str is the dsm/ folder name.
    # Covers both DSM (>= 7.2) and DSM_Enterprise.
    pages_to_scrape = []

    def collect_pages(index_url, base_url, min_version=None):
        try:
            r = session.get(index_url, timeout=15, verify=False)
            r.encoding = "utf-8"
        except Exception as e:
            click.echo(f"Error fetching index {index_url}: {e}", err=True)
            return
        pat = re.compile(r'href=["\']?/download/Os/[^/]+/(\d+)\.(\d+)(?:\.(\d+))?-(\d+)(?:-(\d+))?(?:-NanoPacked)?["\']?')
        seen = set()
        entries = []
        for m in pat.finditer(r.text):
            major, minor = int(m.group(1)), int(m.group(2))
            if min_version and (major, minor) < min_version:
                continue
            patch = m.group(3) or "0"
            build = m.group(4)
            nano  = m.group(5) or "0"
            key = (major, minor, patch, build, nano)
            if key not in seen:
                seen.add(key)
                entries.append(key)
        entries.sort(key=lambda v: (v[0], v[1], v[2], int(v[3]), int(v[4])))
        for (major, minor, patch, build, nano) in entries:
            archive_path = f"{major}.{minor}"
            if patch != "0":
                archive_path += f".{patch}"
            archive_path += f"-{build}"
            if nano != "0":
                archive_path += f"-{nano}"
            version_str = f"{major}.{minor}.{patch}-{build}-{nano}"
            pages_to_scrape.append((f"{base_url}/{archive_path}", version_str))

    collect_pages(
        "https://archive.synology.com/download/Os/DSM",
        "https://archive.synology.com/download/Os/DSM",
        min_version=(7, 2)
    )

    if not pages_to_scrape:
        click.echo("No archive pages found", err=True)
        return

    # --- Step 3: scrape each DSM page, take only release PATs, skip criticalupdate ---
    pats = {}
    for (page_url, version_str) in pages_to_scrape:
        try:
            r = session.get(page_url, timeout=15, verify=False)
            r.encoding = "utf-8"
        except Exception:
            continue

        for m in re.finditer(r'href=["\']?(https://[^"\']*\.pat|/download/[^"\']*\.pat)["\']?', r.text):
            link = m.group(1)
            if not link.startswith("http"):
                link = "https://global.synologydownload.com" + link
            link = link.split("?")[0]
            if "/download/dsm/release/" not in link.lower():
                continue
            filename = unquote(link.split("/")[-1]).replace(".pat", "")
            parts = filename.split("_")
            if len(parts) < 3:
                continue
            model_name = "_".join(parts[1:-1])
            if model_name.lower().startswith("enterprise_"):
                model_name = model_name[len("Enterprise_"):]
            model_key = model_name.lower()

            # RSS mUnique strips DS/RS/FS prefixes for many models (e.g. "3622xs+" not "ds3622xs+")
            # so look up by full key first, then try stripping the prefix from the PAT filename name
            if model_key in model_platforms:
                lookup_key = model_key
            else:
                bare = re.sub(r'^(DS|RS|FS|SA|HD|DVA|PAS)', '', model_name, flags=re.IGNORECASE).lower()
                lookup_key = bare if bare in model_platforms else None

            if not lookup_key:
                continue

            for platform in model_platforms[lookup_key]:
                pats.setdefault(platform, {}).setdefault(model_name, {})[version_str] = {
                    "url": link,
                    "hash": ""
                }

    # --- Inject DSM_Enterprise entries (version string derived from RSS ReqMajorVer.ReqMinorVer) ---
    seen_enterprise = set()
    for (platform, cased_name, version_str, url) in enterprise_pats:
        key = (platform, cased_name, version_str)
        if key in seen_enterprise:
            continue
        seen_enterprise.add(key)
        pats.setdefault(platform, {}).setdefault(cased_name, {})[version_str] = {
            "url": url,
            "hash": ""
        }

    # --- Write output YAML ---
    class QuotedStr(str):
        pass

    def quoted_presenter(dumper, data):
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style='"')

    yaml.add_representer(QuotedStr, quoted_presenter)

    def quote_values(obj, level=0):
        if isinstance(obj, dict):
            return {
                (QuotedStr(k) if level in (1, 2) else k): quote_values(v, level + 1)
                for k, v in obj.items()
            }
        if isinstance(obj, str):
            return QuotedStr(obj)
        return obj

    with open(jsonpath, "w", encoding="utf-8") as f:
        yaml.dump(quote_values(pats), f, indent=2, allow_unicode=True, sort_keys=False)

    total = sum(len(vs) for ms in pats.values() for vs in ms.values())
    click.echo(f"Written {total} entries across {len(pats)} platforms to {jsonpath}")

if __name__ == "__main__":
    cli()
