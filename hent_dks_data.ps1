# hent_dks_data.ps1
# Hentar program- og bussdata fraa DKS-portalen (get_calendar_events) og skriv
# JSON-filer til DKS-apps-repoet: dks_program_data_grunnskule.json,
# dks_program_data_vgs.json og dks_turne_data.json. Erstattar den tidlegare
# GitHub Actions-workflowen (.github/workflows/update-dks-data.yml), som fekk
# HTTP 403 fraa sky-/datasenter-IP-ar (Azure) i fleire veker utan aa feile
# synleg. Koeyrer fraa kommune-PC-en (vanleg kontor-IP, ikkje datasenter),
# der portalen svarar 200 - stadfesta med PowerShell 12.08.2026.
#
# PowerShell 5.1-kompatibel (ingen ternary-operator, ingen null-coalescing).

$ErrorActionPreference = 'Stop'
$env:GIT_TERMINAL_PROMPT = 0   # git push skal feile raskt i staden for aa henge paa eit skjult auth-prompt

$API_URL         = "https://portal.denkulturelleskolesekken.no/api/wordpress/productions/get_calendar_events"
$REPO_DIR        = $PSScriptRoot
$MIN_ARRANGEMENT = 100
$LIMIT           = 2000

Start-Transcript -Path "$REPO_DIR\hent_dks_data_logg.txt" -Force

# Hentar eitt scope frå get_calendar_events. $yearLevels er $null for asker-scope
# (ingen filter - kommunen sine eigne produksjonar er alt grunnskulenivaa), eller
# ei liste med [min,max]-par for akershus-scope (VGS-filter, sjaa dks_program.html).
function HentScope($wordpressHomeUrl, $yearLevels) {
    $body = @{
        view                        = "calendar"
        sort                        = "date"
        academicYearId              = ""
        openAllEvents               = $false
        datePeriods                 = @()
        includeEvents               = $true
        hideUnspecifiedLocationName = $true
        includeSchoolDetails        = $true
        wordpressHomeUrl            = $wordpressHomeUrl
        skip                        = 0
        limit                       = $LIMIT
    }
    if ($yearLevels) { $body.yearLevels = $yearLevels }
    $bodyJson = $body | ConvertTo-Json -Depth 5

    # Invoke-RestMethod kastar automatisk ein terminating error baade ved
    # ugyldig JSON i svaret og ved ikkje-2xx HTTP-status - fanga av try/catch
    # nedst i skriptet. Ingen stille feiling her.
    return Invoke-RestMethod -Uri $API_URL -Method POST -Body $bodyJson -ContentType "application/json"
}

# Validerer eit henta scope-svar og skriv det til fil. Kastar (og skriv difor
# IKKJE fila) viss data ser tomt/kutta ut - held då på den gamle fila. Dette er
# nettopp den valideringa som mangla i den gamle workflowen, som rapporterte
# suksess i sju veker medan portalen svarte 403.
function ValiderOgSkriv($resp, $path, $scopeNamn) {
    if ($null -eq $resp -or $null -eq $resp.events) {
        throw "$scopeNamn : svaret manglar events-feltet (ugyldig struktur/JSON)"
    }

    $antal = @($resp.events).Count
    Write-Host "$scopeNamn : $antal arrangement"

    if ($antal -lt $MIN_ARRANGEMENT) {
        throw "$scopeNamn : berre $antal arrangement (under grensa $MIN_ARRANGEMENT) - avviser, truleg tomt/feila svar. Held paa gamal fil."
    }
    if ($antal -eq $LIMIT) {
        Write-Host "AATVARING: $scopeNamn gav akkurat $LIMIT arrangement - datasettet er truleg kutta av limit-parameteren. Paginering (skip/limit-loop) trengst truleg no."
    }

    # Tidsstempel for NAAR dataa faktisk vart henta - IKKJE det same som fila sin
    # modifikasjonstidspunkt (dks_program.html synte tidlegare filalder, som
    # gjorde at sju veker gamle data saag ferske ut naar berre fila vart lest paa
    # nytt utan aa faktisk oppdaterast).
    $resp | Add-Member -NotePropertyName "hentTidspunkt" -NotePropertyValue ([DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")) -Force

    $json = $resp | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
    Write-Host "  -> $path"
}

try {
    Write-Host "Hentar grunnskuledata (asker-scope)..."
    $askerResp = HentScope "https://www.denkulturelleskolesekken.no/asker" $null
    ValiderOgSkriv $askerResp "$REPO_DIR\dks_program_data_grunnskule.json" "Grunnskule (asker)"

    Write-Host ""
    Write-Host "Hentar VGS-data (akershus-scope, trinn 11-13)..."
    $vgsResp = HentScope "https://www.denkulturelleskolesekken.no/akershus" (, @(11, 13))
    ValiderOgSkriv $vgsResp "$REPO_DIR\dks_program_data_vgs.json" "VGS (akershus)"

    Write-Host ""
    Write-Host "Skriv turnedata (transport_enkeltsok-8-2.html)..."
    # dks_turne_data.json brukar SAME datagrunnlag som grunnskule-fila (asker-scope).
    # get_calendar_events har ikkje noko "tour"-felt (stadfesta 12.08.2026 - full
    # rå JSON-dump av eit arrangement synte at det einaste identitetsfeltet er
    # production.id/production.name). Transportappen grupperer sjølv paa
    # production.id klientside i staden for aa slaa opp mot findByTourId.
    # Cross-county-produksjonar som besøkjer Asker-skular (t.d. eigd av Akershus
    # fylkeskommune) er medvite utelatne her - avklart med Eirik 12.08.2026:
    # "Asker-arrangement er nok, ikkje behov for vilkårlege turné-ID-ar".
    ValiderOgSkriv $askerResp "$REPO_DIR\dks_turne_data.json" "Turnedata (asker)"

    Write-Host ""
    Write-Host "Pushar til GitHub..."
    Set-Location $REPO_DIR
    git add dks_program_data_grunnskule.json dks_program_data_vgs.json dks_turne_data.json
    if ($LASTEXITCODE -ne 0) { throw "git add feila" }

    $dato = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm")
    git diff --staged --quiet
    if ($LASTEXITCODE -ne 0) {
        git commit -m "Oppdater DKS-programdata $dato"
        if ($LASTEXITCODE -ne 0) { throw "git commit feila" }

        # Remote kan ha fått nye commits sidan sist (t.d. frå Mac-en) - pull
        # --rebase FØR push, elles vert push avvist med "rejected (fetch
        # first)" (stadfesta 14.08.2026). Konflikt vert fanga eksplisitt og
        # rebasen vert avbrote, slik at repoet ikkje vert ståande halvvegs i
        # ein rebase på ein ubemanna kommune-PC.
        #
        # MERK om $ErrorActionPreference='Stop' (sett øvst i fila) + "2>&1":
        # git skriv det meste av statusteksten sin (t.d. "From github.com...")
        # til stderr, ikkje fordi det er ein feil. Med EAP=Stop kan PowerShell
        # tolke slike stderr-linjer frå eit nativt program som ein terminerande
        # feil FØR $LASTEXITCODE i det heile vert sjekka. Difor: skru EAP til
        # 'Continue' berre rundt desse to kalla, les $LASTEXITCODE med det
        # same, og set EAP tilbake til 'Stop' igjen etterpå.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $pullOutput = git pull --rebase origin main 2>&1
        $pullExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP

        if ($pullExit -ne 0) {
            $pullText = ($pullOutput | Out-String)
            if ($pullText -match 'CONFLICT' -or $pullText -match 'could not apply') {
                git rebase --abort 2>&1 | Out-Null
                throw "git pull --rebase gav konflikt - avbrote (rebase --abort). Data ER henta og commita lokalt, men IKKJE pusha. Løys konflikten manuelt og push derifrå. Detaljar: $pullText"
            }
            if ($pullText -match 'Authentication failed' -or $pullText -match 'Permission denied' -or $pullText -match 'could not read Username' -or $pullText -match 'fatal: unable to access' -or $pullText -match 'fatal: could not read') {
                throw "git pull --rebase feila - autentiseringsproblem (sjekk credential-cache/PAT). Detaljar: $pullText"
            }
            throw "git pull --rebase feila av ukjend grunn. Detaljar: $pullText"
        }

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $pushOutput = git push 2>&1
        $pushExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP

        if ($pushExit -ne 0) {
            $pushText = ($pushOutput | Out-String)
            if ($pushText -match '\[rejected\]' -or $pushText -match 'fetch first' -or $pushText -match 'non-fast-forward') {
                throw "git push vart avvist sjølv etter pull --rebase - truleg eit nytt race mot ein annan push same augneblink. Prøv å køyre skriptet på nytt. Detaljar: $pushText"
            }
            if ($pushText -match 'Authentication failed' -or $pushText -match 'Permission denied' -or $pushText -match 'could not read Username' -or $pushText -match 'fatal: unable to access' -or $pushText -match 'fatal: could not read') {
                throw "git push feila - autentiseringsproblem (sjekk credential-cache/PAT). Detaljar: $pushText"
            }
            throw "git push feila av ukjend grunn. Detaljar: $pushText"
        }
        Write-Host "Push ferdig."
    } else {
        Write-Host "Ingen endringar sidan sist."
    }

    Write-Host ""
    Write-Host "Ferdig!"
    exit 0
}
catch {
    Write-Host "FEIL: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
finally {
    Stop-Transcript
}
