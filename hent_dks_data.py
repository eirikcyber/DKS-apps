#!/usr/bin/env python3
"""
hent_dks_data.py — Python-port av hent_dks_data.ps1 (01.09.2026).

Hentar program- og bussdata frå DKS-portalen (get_calendar_events, offentleg
endepunkt — ingen KTSESSION nødvendig) og skriv JSON-filer til DKS-apps-repoet:
dks_program_data_grunnskule.json, dks_program_data_vgs.json og
dks_turne_data.json.

Kvifor eit Python-alternativ i tillegg til .ps1-en: endepunktet er berre
blokkert (403) frå sky-/datasenter-IP-ar (GitHub Actions Azure-runnarar) —
IKKJE frå vanlege heime-/kontor-maskiner. Stadfesta direkte 01.09.2026 (HTTP
200, 728 arrangement, frå denne Mac-en). Ein Mac har ikkje PowerShell, difor
denne porten — held fram og pushar sjølv, akkurat som .ps1-en gjer frå
kommune-PC-en. Begge kan køyrast trygt om kvarandre (begge gjer
pull --rebase FØR push).

Berre stdlib. Bruk: python3 hent_dks_data.py
"""

import os
import sys
import json
import subprocess
import urllib.request
import urllib.error
from datetime import datetime, timezone

API_URL = "https://portal.denkulturelleskolesekken.no/api/wordpress/productions/get_calendar_events"
REPO_DIR = os.path.dirname(os.path.abspath(__file__))
MIN_ARRANGEMENT = 100
LIMIT = 2000


def hent_scope(wordpress_home_url, year_levels=None):
    body = {
        "view": "calendar",
        "sort": "date",
        "academicYearId": "",
        "openAllEvents": False,
        "datePeriods": [],
        "includeEvents": True,
        "hideUnspecifiedLocationName": True,
        "includeSchoolDetails": True,
        "wordpressHomeUrl": wordpress_home_url,
        "skip": 0,
        "limit": LIMIT,
    }
    if year_levels:
        body["yearLevels"] = year_levels
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        API_URL, data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def valider_og_skriv(resp, path, scope_namn):
    """Kastar (og skriv difor IKKJE fila) viss data ser tomt/kutta ut — held
    då på den gamle fila. Same validering som .ps1-en, jf. den gamle
    GitHub Actions-workflowen som rapporterte suksess i sju veker medan
    portalen svarte 403 (sjå CLAUDE.md)."""
    if resp is None or "events" not in resp:
        raise RuntimeError(f"{scope_namn}: svaret manglar events-feltet (ugyldig struktur/JSON)")

    antal = len(resp["events"])
    print(f"{scope_namn}: {antal} arrangement")

    if antal < MIN_ARRANGEMENT:
        raise RuntimeError(f"{scope_namn}: berre {antal} arrangement (under grensa {MIN_ARRANGEMENT}) "
                            f"— avviser, truleg tomt/feila svar. Held på gamal fil.")
    if antal == LIMIT:
        print(f"ÅTVARING: {scope_namn} gav akkurat {LIMIT} arrangement — datasettet er truleg kutta "
              f"av limit-parameteren. Paginering (skip/limit-loop) trengst truleg no.")

    resp["hentTidspunkt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(resp, f, ensure_ascii=False)
    print(f"  -> {path}")


def git(*args, check=True):
    result = subprocess.run(["git"] + list(args), cwd=REPO_DIR, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} feila:\n{result.stdout}\n{result.stderr}")
    return result


def main():
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"  # git push skal feile raskt, ikkje henge på eit skjult auth-prompt

    print("Hentar grunnskuledata (asker-scope)...")
    asker_resp = hent_scope("https://www.denkulturelleskolesekken.no/asker")
    grunnskule_path = os.path.join(REPO_DIR, "dks_program_data_grunnskule.json")
    valider_og_skriv(asker_resp, grunnskule_path, "Grunnskule (asker)")

    print()
    print("Hentar VGS-data (akershus-scope, trinn 11-13)...")
    vgs_resp = hent_scope("https://www.denkulturelleskolesekken.no/akershus", [[11, 13]])
    vgs_path = os.path.join(REPO_DIR, "dks_program_data_vgs.json")
    valider_og_skriv(vgs_resp, vgs_path, "VGS (akershus)")

    print()
    print("Skriv turnédata (transport_enkeltsok-8-2.html)...")
    # dks_turne_data.json brukar SAME datagrunnlag som grunnskule-fila (asker-
    # scope) — get_calendar_events har ikkje noko "tour"-felt, appen grupperer
    # sjølv på production.id klientside. Hent scope-et FERSKT på nytt (ikkje
    # gjenbruk asker_resp) — same prinsipp som .ps1-en: kvar fil skal ha sitt
    # eige hentTidspunkt, og valider_og_skriv() muterer objektet ho får inn.
    turne_resp = hent_scope("https://www.denkulturelleskolesekken.no/asker")
    turne_path = os.path.join(REPO_DIR, "dks_turne_data.json")
    valider_og_skriv(turne_resp, turne_path, "Turnédata (asker)")

    print()
    print("Pushar til GitHub...")
    git("add", "dks_program_data_grunnskule.json", "dks_program_data_vgs.json", "dks_turne_data.json")

    diff = subprocess.run(["git", "diff", "--staged", "--quiet"], cwd=REPO_DIR)
    if diff.returncode == 0:
        print("Ingen endringar sidan sist.")
        print()
        print("Ferdig!")
        return

    dato = datetime.now().strftime("%Y-%m-%d %H:%M")
    git("commit", "-m", f"Oppdater DKS-programdata {dato}")

    # Remote kan ha fått nye commits sidan sist (t.d. frå kommune-PC-en) —
    # pull --rebase FØR push, elles vert push avvist. Konflikt vert fanga
    # eksplisitt og rebasen avbroten, same prinsipp som .ps1-en.
    pull = subprocess.run(["git", "pull", "--rebase", "origin", "main"],
                           cwd=REPO_DIR, capture_output=True, text=True, env=env)
    if pull.returncode != 0:
        pull_text = pull.stdout + pull.stderr
        if "CONFLICT" in pull_text or "could not apply" in pull_text:
            subprocess.run(["git", "rebase", "--abort"], cwd=REPO_DIR, capture_output=True)
            raise RuntimeError(f"git pull --rebase gav konflikt — avbrote (rebase --abort). Data ER henta "
                                f"og commita lokalt, men IKKJE pusha. Løys konflikten manuelt og push derifrå. "
                                f"Detaljar: {pull_text}")
        raise RuntimeError(f"git pull --rebase feila: {pull_text}")

    push = subprocess.run(["git", "push"], cwd=REPO_DIR, capture_output=True, text=True, env=env)
    if push.returncode != 0:
        push_text = push.stdout + push.stderr
        raise RuntimeError(f"git push feila: {push_text}")

    print("Push ferdig.")
    print()
    print("Ferdig!")


if __name__ == "__main__":
    try:
        main()
    except Exception as ex:
        print(f"FEIL: {ex}")
        sys.exit(1)
