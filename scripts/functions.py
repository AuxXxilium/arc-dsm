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
@click.option("-o", "--outfile", type=str, required=True, help="Output file: one line per entry: PLATFORM\\tMODEL\\tVERSION\\tURL")
def getpats(workpath, outfile):
    # Load supported platforms from platforms.yml
    supported_platforms = set()
    platforms_yml = os.path.join(workpath, "configs", "platforms.yml")
    try:
        with open(platforms_yml, "r", encoding="utf-8") as f:
            pcfg = yaml.safe_load(f) or {}
        platforms = pcfg.get("platforms", {}) if isinstance(pcfg, dict) else {}
        if isinstance(platforms, dict):
            supported_platforms = {str(k).strip().lower() for k in platforms.keys()}
    except Exception as e:
        click.echo(f"Error loading {platforms_yml}: {e}", err=True)
        return

    adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1, status_forcelist=[500, 502, 503, 504]))
    session = requests.Session()
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    session.trust_env = False
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    # Build model->platform(s) map from genRSS mUnique fields (synology_<platform>_<model>)
    model_platforms = {}
    try:
        r = session.get("https://update7.synology.com/autoupdate/genRSS.php?include_beta=1", timeout=15)
        root = ET.fromstring(r.content)
        for munique in root.iter("mUnique"):
            parts = munique.text.strip().split("_")
            if len(parts) < 3 or parts[0] != "synology":
                continue
            platform = parts[1].lower()
            model = "_".join(parts[2:]).lower()
            if platform not in supported_platforms:
                continue
            model_platforms.setdefault(model, [])
            if platform not in model_platforms[model]:
                model_platforms[model].append(platform)
    except Exception as e:
        click.echo(f"Error fetching genRSS: {e}", err=True)
        return

    # Fetch list of all DSM versions from the archive index
    # Path format: /download/Os/DSM/<major>.<minor>[.patch]-<build>[-nano]
    # e.g. /download/Os/DSM/7.2.2-72806-8  -> major=7 minor=2 patch=2 build=72806 nano=8
    #      /download/Os/DSM/7.3-81180       -> major=7 minor=3 patch=0 build=81180 nano=0
    #      /download/Os/DSM/7.4-90075       -> major=7 minor=4 patch=0 build=90075 nano=0
    try:
        r = session.get("https://archive.synology.com/download/Os/DSM", timeout=15, verify=False)
        r.encoding = "utf-8"
        versions = []
        pat = re.compile(r'href=["\']?/download/Os/DSM/(\d+)\.(\d+)(?:\.(\d+))?-(\d+)(?:-(\d+))?(?:-NanoPacked)?["\']?')
        for m in pat.finditer(r.text):
            major, minor = int(m.group(1)), int(m.group(2))
            if (major, minor) < (7, 2):
                continue
            patch = m.group(3) or "0"
            build = m.group(4)
            nano  = m.group(5) or "0"
            versions.append((major, minor, patch, build, nano))
    except Exception as e:
        click.echo(f"Error fetching archive index: {e}", err=True)
        return

    # Build model->url map per version from each archive page, emit TSV lines
    with open(outfile, "w", encoding="utf-8") as out:
        for major, minor, patch, build, nano in versions:
            archive_path = f"{major}.{minor}"
            if patch != "0":
                archive_path += f".{patch}"
            archive_path += f"-{build}"
            if nano != "0":
                archive_path += f"-{nano}"
            url = f"https://archive.synology.com/download/Os/DSM/{archive_path}"
            try:
                r = session.get(url, timeout=15, verify=False)
                r.encoding = "utf-8"
            except Exception:
                continue

            # Parse PAT links — only full releases under /download/DSM/release/
            archive_url_map = {}
            base = "https://global.synologydownload.com"
            for m in re.finditer(r'href=["\']?(https://[^"\']*|/download/[^"\']*\.pat)["\']?', r.text):
                link = m.group(1)
                if not link.startswith("http"):
                    link = base + link
                link = link.split("?")[0]
                if not link.lower().endswith(".pat"):
                    continue
                if "/download/dsm/release/" not in link.lower():
                    continue
                filename = unquote(link.split("/")[-1]).replace(".pat", "")
                parts = filename.split("_")
                if len(parts) < 3:
                    continue
                model_name = "_".join(parts[1:-1])
                if model_name.startswith("Enterprise_"):
                    model_name = model_name[len("Enterprise_"):]
                archive_url_map[model_name.lower()] = link

            if not archive_url_map:
                continue

            version_str = f"{major}.{minor}.{patch}-{build}-{nano}"

            for model_name, platforms in model_platforms.items():
                pat_url = archive_url_map.get(model_name)
                if not pat_url:
                    continue
                for platform in platforms:
                    out.write(f"{platform}\t{model_name}\t{version_str}\t{pat_url}\n")

if __name__ == "__main__":
    cli()