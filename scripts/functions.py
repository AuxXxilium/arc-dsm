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
    def __fullversion(ver):
        arr = ver.split('-')
        a, b, c = (arr[0].split('.') + ['0', '0', '0'])[:3]
        d = arr[1] if len(arr) > 1 else '00000'
        e = arr[2] if len(arr) > 2 else '0'
        return f'{a}.{b}.{c}-{d}-{e}'

    # Load platforms.yml and build model->platform mapping
    platforms_yml = os.path.join(workpath, "configs", "platforms.yml")
    with open(platforms_yml, "r") as f:
        platforms_data = yaml.safe_load(f)
        platforms = platforms_data.get("platforms", {})

    model_to_platform = {}
    for platform, pdata in platforms.items():
        # Try to get models from productvers, but fallback to hardcoded mapping if needed
        # Here, we assume you want to map models by platform name
        # You may want to load a models list per platform if available
        pass  # We'll fill this below after fetching models

    # Fetch models as before
    adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1, status_forcelist=[500, 502, 503, 504]))
    session = requests.Session()
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    
    try:
        url = "http://update7.synology.com/autoupdate/genRSS.php?include_beta=1"
        req = session.get(url, timeout=10, verify=False)
        req.encoding = "utf-8"
        p = re.compile(r"<mUnique>(.*?)</mUnique>.*?<mLink>(.*?)</mLink>", re.MULTILINE | re.DOTALL)
        data = p.findall(req.text)
    except Exception as e:
        click.echo(f"Error: {e}")
        return

    # Build model->platform mapping from RSS
    model_arch = {}
    for item in data:
        if not "DSM" in item[1]:
            continue
        arch = item[0].split("_")[1]
        name = item[1].split("/")[-1].split("_")[1].replace("%2B", "+")
        if arch not in platforms:
            continue
        model_arch[name] = arch

    # Now, fetch pats as before
    pats = {}
    for M, arch in model_arch.items():
        if arch not in pats:
            pats[arch] = {}
        if M not in pats[arch]:
            pats[arch][M] = {}
        version = '7'
        urlInfo = "https://www.synology.com/api/support/findDownloadInfo?lang=en-us"
        urlSteps = "https://www.synology.com/api/support/findUpgradeSteps?"

        major = f"&major={version.split('.')[0]}" if len(version.split('.')) > 0 else ""
        minor = f"&minor={version.split('.')[1]}" if len(version.split('.')) > 1 else ""
        try:
            req = session.get(f"{urlInfo}&product={M.replace('+', '%2B')}{major}{minor}", timeout=10, verify=False)
            req.encoding = "utf-8"
            data = json.loads(req.text)
        except Exception as e:
            click.echo(f"Error: {e}")
            continue

        build_ver = data['info']['system']['detail'][0]['items'][0]['build_ver']
        build_num = data['info']['system']['detail'][0]['items'][0]['build_num']
        buildnano = data['info']['system']['detail'][0]['items'][0]['nano']
        V = __fullversion(f"{build_ver}-{build_num}-{buildnano}")
        if V not in pats[arch][M]:
            pats[arch][M][V] = {
                'url': data['info']['system']['detail'][0]['items'][0]['files'][0]['url'].split('?')[0],
                'hash': data['info']['system']['detail'][0]['items'][0]['files'][0].get('checksum', '0' * 32)
            }

        from_ver = min(I['build'] for I in data['info']['pubVers'])

        for I in data['info']['productVers']:
            if not I['version'].startswith(version):
                continue
            if not major or not minor:
                majorTmp = f"&major={I['version'].split('.')[0]}" if len(I['version'].split('.')) > 0 else ""
                minorTmp = f"&minor={I['version'].split('.')[1]}" if len(I['version'].split('.')) > 1 else ""
                try:
                    reqTmp = session.get(f"{urlInfo}&product={M.replace('+', '%2B')}{majorTmp}{minorTmp}", timeout=10, verify=False)
                    reqTmp.encoding = "utf-8"
                    dataTmp = json.loads(reqTmp.text)
                except Exception as e:
                    click.echo(f"Error: {e}")
                    continue

                build_ver = dataTmp['info']['system']['detail'][0]['items'][0]['build_ver']
                build_num = dataTmp['info']['system']['detail'][0]['items'][0]['build_num']
                buildnano = dataTmp['info']['system']['detail'][0]['items'][0]['nano']
                V = __fullversion(f"{build_ver}-{build_num}-{buildnano}")
                if V not in pats[arch][M]:
                    pats[arch][M][V] = {
                        'url': dataTmp['info']['system']['detail'][0]['items'][0]['files'][0]['url'].split('?')[0],
                        'hash': dataTmp['info']['system']['detail'][0]['items'][0]['files'][0].get('checksum', '0' * 32)
                    }

            for J in I['versions']:
                to_ver = J['build']
                try:
                    reqSteps = session.get(f"{urlSteps}&product={M.replace('+', '%2B')}&from_ver={from_ver}&to_ver={to_ver}", timeout=10, verify=False)
                    if reqSteps.status_code != 200:
                        continue
                    reqSteps.encoding = "utf-8"
                    dataSteps = json.loads(reqSteps.text)
                except Exception as e:
                    click.echo(f"Error: {e}")
                    continue

                for S in dataSteps['upgrade_steps']:
                    if not S.get('full_patch') or not S['build_ver'].startswith(version):
                        continue
                    V = __fullversion(f"{S['build_ver']}-{S['build_num']}-{S['nano']}")
                    if V not in pats[arch][M]:
                        reqPat = session.head(S['files'][0]['url'].split('?')[0].replace("global.synologydownload.com", "global.download.synology.com"), timeout=10, verify=False)
                        if reqPat.status_code == 403:
                            continue
                        pats[arch][M][V] = {
                            'url': S['files'][0]['url'].split('?')[0],
                            'hash': S['files'][0].get('checksum', '0' * 32)
                        }

    # Write as YAML in the requested format, with only models and versions quoted (not platforms)
    class QuotedStr(str): pass

    def quoted_presenter(dumper, data):
        return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='"')

    yaml.add_representer(QuotedStr, quoted_presenter)

    # Quote model/version keys and url/hash values
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