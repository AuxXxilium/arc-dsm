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

    # --- Step 1: RSS → model->platform map ---
    model_platforms = {}
    try:
        r = session.get("https://update7.synology.com/autoupdate/genRSS.php?include_beta=1", timeout=15)
        root = ET.fromstring(r.content)
        for munique in root.iter("mUnique"):
            parts = munique.text.strip().split("_")
            if len(parts) < 3 or parts[0] != "synology":
                continue
            platform = parts[1].lower()
            if platform not in supported_platforms:
                continue
            model = "_".join(parts[2:]).lower()
            if platform not in model_platforms.get(model, []):
                model_platforms.setdefault(model, []).append(platform)
    except Exception as e:
        click.echo(f"Error fetching RSS: {e}", err=True)
        return

    if not model_platforms:
        click.echo("No models found in RSS feed", err=True)
        return

    # --- Step 2: archive.synology.com → all DSM versions >= 7.2 (highest nano per base version) ---
    best_nano = {}
    try:
        r = session.get("https://archive.synology.com/download/Os/DSM", timeout=15, verify=False)
        r.encoding = "utf-8"
        pat = re.compile(r'href=["\']?/download/Os/DSM/(\d+)\.(\d+)(?:\.(\d+))?-(\d+)(?:-(\d+))?(?:-NanoPacked)?["\']?')
        for m in pat.finditer(r.text):
            major, minor = int(m.group(1)), int(m.group(2))
            if (major, minor) < (7, 2):
                continue
            patch = m.group(3) or "0"
            build = m.group(4)
            nano  = int(m.group(5) or "0")
            key = (major, minor, patch, build)
            if key not in best_nano or nano > best_nano[key]:
                best_nano[key] = nano
    except Exception as e:
        click.echo(f"Error fetching archive index: {e}", err=True)
        return

    # --- Step 3: for each version, fetch PAT URLs and cross-join with model->platform ---
    pats = {}
    for (major, minor, patch, build), nano in sorted(best_nano.items(), key=lambda item: (item[0][0], item[0][1], item[0][2], int(item[0][3]))):
        archive_path = f"{major}.{minor}"
        if patch != "0":
            archive_path += f".{patch}"
        archive_path += f"-{build}"
        if nano != 0:
            archive_path += f"-{nano}"

        try:
            r = session.get(f"https://archive.synology.com/download/Os/DSM/{archive_path}", timeout=15, verify=False)
            r.encoding = "utf-8"
        except Exception:
            continue

        # Only full release PATs, not criticalupdate/security patches
        url_map = {}
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
            model_name = "_".join(parts[1:-1]).lower()
            if model_name.startswith("enterprise_"):
                model_name = model_name[len("enterprise_"):]
            url_map[model_name] = link

        if not url_map:
            continue

        version_str = f"{major}.{minor}.{patch}-{build}-{nano}"

        for model_name, model_plats in model_platforms.items():
            pat_url = url_map.get(model_name)
            if not pat_url:
                continue
            for platform in model_plats:
                pats.setdefault(platform, {}).setdefault(model_name, {})[version_str] = {
                    "url": pat_url,
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
