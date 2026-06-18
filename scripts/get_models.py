import sys, yaml, requests, xml.etree.ElementTree as ET

with open("configs/platforms.yml") as f:
    pcfg = yaml.safe_load(f) or {}
supported = {str(k).strip().lower() for k in (pcfg.get("platforms") or {}).keys()}

r = requests.get("https://update7.synology.com/autoupdate/genRSS.php?include_beta=1", timeout=15)
root = ET.fromstring(r.content)

models = set()
for munique in root.iter("mUnique"):
    parts = munique.text.strip().split("_")
    if len(parts) < 3 or parts[0] != "synology":
        continue
    if parts[1].lower() not in supported:
        continue
    models.add("_".join(parts[2:]))

print("\n".join(sorted(models)))
