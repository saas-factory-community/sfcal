#!/usr/bin/env python3
"""Pone sfcal.app en la POSICION 1 del Dock (idempotente).

Via `defaults export/import` (pasa por cfprefsd: sin caches stale) + killall Dock.
"""
import pathlib
import plistlib
import subprocess

HOME = pathlib.Path.home()
SFCAL_URL = f"file://{HOME}/Applications/sfcal.app/"

def main():
    exported = subprocess.run(["defaults", "export", "com.apple.dock", "-"],
                              capture_output=True, check=True).stdout
    d = plistlib.loads(exported)
    apps = d.get("persistent-apps", [])
    before = len(apps)

    def url_of(entry):
        return str(entry.get("tile-data", {}).get("file-data", {}).get("_CFURLString", ""))

    apps = [a for a in apps if "sfcal.app" not in url_of(a)]
    entry = {
        "tile-data": {
            "file-data": {"_CFURLString": SFCAL_URL, "_CFURLStringType": 15},
            "file-label": "sfcal",
            "file-type": 41,
        },
        "tile-type": "file-tile",
    }
    apps.insert(0, entry)
    d["persistent-apps"] = apps

    tmp = HOME / ".sfcal" / "dock-new.plist"
    tmp.parent.mkdir(exist_ok=True)
    with open(tmp, "wb") as f:
        plistlib.dump(d, f)
    subprocess.run(["defaults", "import", "com.apple.dock", str(tmp)], check=True)
    subprocess.run(["killall", "Dock"], check=True)
    print(f"DOCK_OK apps {before} -> {len(apps)} (sfcal en posición 1)")

if __name__ == "__main__":
    main()
