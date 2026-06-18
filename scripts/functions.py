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
    # Build model->platform(s) map from arc-configs data.yml (platform -> model -> ...)
    # A model can appear under multiple platforms (e.g. DS1825+ under r1000nk and v1000nk).
    model_platforms = {}
    data_yml = os.path.join(workpath, "configs", "data.yml")
    try:
        with open(data_yml, "r", encoding="utf-8") as f:
            cfg = yaml.safe_load(f) or {}
        for platform, models in cfg.items():
            if not isinstance(models, dict):
                continue
            for model in models:
                model_platforms.setdefault(model, [])
                if platform not in model_platforms[model]:
                    model_platforms[model].append(platform)
    except Exception as e:
        click.echo(f"Error loading {data_yml}: {e}", err=True)
        return

    adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1, status_forcelist=[500, 502, 503, 504]))
    session = requests.Session()
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    session.trust_env = False
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    # Fetch list of all DSM versions from the archive index
    try:
        r = session.get("https://archive.synology.com/download/Os/DSM", timeout=15, verify=False)
        r.encoding = "utf-8"
        versions = []
        for m in re.finditer(r'href=["\']?/download/Os/DSM/(\d+)\.(\d+)-(\d+)["\']?', r.text):
            major, minor, build = int(m.group(1)), int(m.group(2)), m.group(3)
            if (major, minor) >= (7, 2):
                versions.append((major, minor, build))
    except Exception as e:
        click.echo(f"Error fetching archive index: {e}", err=True)
        return

    # Build model->url map per version from each archive page, emit TSV lines
    with open(outfile, "w", encoding="utf-8") as out:
        for major, minor, build in versions:
            url = f"https://archive.synology.com/download/Os/DSM/{major}.{minor}-{build}"
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
                archive_url_map[model_name] = link

            if not archive_url_map:
                continue

            # Derive version string from the URL path (patch component may be present)
            # e.g. /release/7.2.2/72806-8/... -> patch=2, build=72806, nano=8
            #      /release/7.4/90075/...      -> patch=0, build=90075, nano=0
            sample_url = next(iter(archive_url_map.values()))
            patch, nano = "0", "0"
            path_match = re.search(r'/release/\d+\.\d+(?:\.(\d+))?/(\d+)(?:-(\d+))?/', sample_url)
            if path_match:
                patch = path_match.group(1) or "0"
                nano  = path_match.group(3) or "0"
            version_str = f"{major}.{minor}.{patch}-{build}-{nano}"

            for model_name, platforms in model_platforms.items():
                pat_url = archive_url_map.get(model_name)
                if not pat_url:
                    continue
                for platform in platforms:
                    out.write(f"{platform}\t{model_name}\t{version_str}\t{pat_url}\n")

if __name__ == "__main__":
    cli()