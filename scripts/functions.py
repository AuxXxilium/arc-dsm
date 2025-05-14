# -*- coding: utf-8 -*-
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

import os, click

WORK_PATH = os.path.abspath(os.path.dirname(__file__))


@click.group()
def cli():
    """
    The CLI is a commands to Arc.
    """
    pass


def mutually_exclusive_options(ctx, param, value):
    other_option = "file" if param.name == "data" else "data"
    if value is not None and ctx.params.get(other_option) is not None:
        raise click.UsageError(f"Illegal usage: `{param.name}` is mutually exclusive with `{other_option}`.")
    return value


def validate_required_param(ctx, param, value):
    if not value and "file" not in ctx.params and "data" not in ctx.params:
        raise click.MissingParameter(param_decls=[param.name])
    return value

def __fullversion(ver):
    out = ver
    arr = ver.split('-')
    if len(arr) > 0:
        a = arr[0].split('.')[0] if len(arr[0].split('.')) > 0 else '0'
        b = arr[0].split('.')[1] if len(arr[0].split('.')) > 1 else '0'
        c = arr[0].split('.')[2] if len(arr[0].split('.')) > 2 else '0'
        d = arr[1] if len(arr) > 1 else '00000'
        e = arr[2] if len(arr) > 2 else '0'
        out = '{}.{}.{}-{}-{}'.format(a,b,c,d,e)
    return out

@cli.command()
@click.option("-p", "--platforms", type=str, help="The platforms of Syno.")
def getmodels(platforms=None):
    """
    Get Syno Models.
    """
    import re, json, requests, urllib3
    from requests.adapters import HTTPAdapter
    from requests.packages.urllib3.util.retry import Retry  # type: ignore

    adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1, status_forcelist=[500, 502, 503, 504]))
    session = requests.Session()
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    PS = platforms.lower().replace(",", " ").split() if platforms else []

    models = []
    try:
        url = "http://update7.synology.com/autoupdate/genRSS.php?include_beta=1"
        #url = "https://update7.synology.com/autoupdate/genRSS.php?include_beta=1"

        req = session.get(url, timeout=10, verify=False)
        req.encoding = "utf-8"
        p = re.compile(r"<mUnique>(.*?)</mUnique>.*?<mLink>(.*?)</mLink>", re.MULTILINE | re.DOTALL)

        data = p.findall(req.text)
        for item in data:
            if not "DSM" in item[1]:
                continue
            arch = item[0].split("_")[1]
            name = item[1].split("/")[-1].split("_")[1].replace("%2B", "+")
            if PS and arch.lower() not in PS:
                continue
            if not any(m["name"] == name for m in models):
                models.append({"name": name, "arch": arch})

        models.sort(key=lambda k: (k["arch"], k["name"]))

    except Exception as e:
        # click.echo(f"Error: {e}")
        pass

    print(json.dumps(models, indent=4))

if __name__ == "__main__":
    cli()