#!/usr/bin/env python3
"""Autoriza una cuenta de Google para sfcal.

Uso:
    python3 scripts/setup_oauth.py <client_id> <client_secret> <etiqueta>

Ejemplo:
    python3 scripts/setup_oauth.py 1234-abc.apps.googleusercontent.com GOCSPX-xyz personal

- <etiqueta> nombra la cuenta ("personal", "trabajo", ...). Cada etiqueta = una
  cuenta en el sidebar de sfcal. La etiqueta "personal" se lista primero.
- Se abre tu navegador para autorizar; el token queda en ~/.sfcal/token-<etiqueta>.json
  (chmod 600, JAMAS lo subas a git).

Requiere: pip3 install google-auth-oauthlib
"""
import json
import os
import pathlib
import sys

try:
    from google_auth_oauthlib.flow import InstalledAppFlow
except ImportError:
    sys.exit("Falta la libreria. Corre:  pip3 install google-auth-oauthlib")

SCOPES = ["https://www.googleapis.com/auth/calendar"]


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    client_id, client_secret, label = sys.argv[1], sys.argv[2], sys.argv[3]
    flow = InstalledAppFlow.from_client_config(
        {
            "installed": {
                "client_id": client_id,
                "client_secret": client_secret,
                "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                "token_uri": "https://oauth2.googleapis.com/token",
                "redirect_uris": ["http://localhost"],
            }
        },
        SCOPES,
    )
    creds = flow.run_local_server(port=0, prompt="consent", access_type="offline")
    dest_dir = pathlib.Path.home() / ".sfcal"
    dest_dir.mkdir(mode=0o700, exist_ok=True)
    dest = dest_dir / f"token-{label}.json"
    dest.write_text(creds.to_json())
    os.chmod(dest, 0o600)
    print(f"✓ Token guardado en {dest}")
    print("  Abre sfcal (o reiníciala) y la cuenta aparece en el sidebar.")


if __name__ == "__main__":
    main()
