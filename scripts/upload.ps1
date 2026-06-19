#Requires -Version 5.1
<#
.SYNOPSIS
    Upload ph-core and ph-ereferral example resources to the ph-cdr FHIR server.
.DESCRIPTION
    Windows PowerShell equivalent of scripts/upload.sh.

    Sources:
      ph-core:     package/example/*.json from fhir.ph.core package.tgz
      ph-ereferral: input/examples-json-source/*.json from GitHub

    Also:
      - Seeds hapi/ucum-fragment.json before uploads (HAPI v8 UCUM regression workaround)
      - Post-processes Provenance files to fix BCP:13 MIME type codes
      - Executes transaction/batch Bundles via POST to base URL

    Requirements: PowerShell 5.1+ (Windows 10 built-in); tar.exe (Windows 10 1803+)

.EXAMPLE
    .\scripts\upload.ps1
.EXAMPLE
    .\scripts\upload.ps1 -BaseUrl http://localhost:8080/fhir -PhCoreVersion 0.1.1 -PhEreferralVersion 0.3.1
#>
[CmdletBinding()]
param(
    [string]$BaseUrl            = 'http://localhost:8080/fhir',
    [string]$PhCoreVersion      = '0.1.1',
    [string]$PhEreferralVersion = '0.3.1',
    [string]$EreferralRepo      = 'jgsuess/ph-ereferral',
    [string]$EreferralBranch    = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Disable progress bars — dramatically speeds up Invoke-WebRequest on large files
$ProgressPreference = 'SilentlyContinue'

$Timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir      = "fhir-upload-results-$Timestamp"
$LogDir      = "$OutDir\logs"
$CorePayDir  = "$OutDir\payloads\ph-core"
$ErefPayDir  = "$OutDir\payloads\ph-ereferral"

$null = New-Item -ItemType Directory -Path $LogDir, $CorePayDir, $ErefPayDir -Force

$ReportMd    = "$OutDir\upload-report.md"
$ReportHtml  = "$OutDir\upload-report.html"
$SummaryJson = "$OutDir\summary.json"

$PhCoreTgzUrl     = "https://jgsuess.github.io/ph-core/$PhCoreVersion/package.tgz"
$EreferralRawBase = "https://raw.githubusercontent.com/$EreferralRepo/$EreferralBranch/input/examples-json-source"

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
$Results = [System.Collections.Generic.List[string]]::new()

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Log { param([string]$Msg) Write-Host $Msg -ForegroundColor Cyan }
function Write-Ok  { param([string]$Msg) Write-Host "v $Msg" -ForegroundColor Green }
function Write-Err { param([string]$Msg) Write-Host "x $Msg" -ForegroundColor Red }

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function Get-JsonField {
    param([string]$Path, [string]$Field)
    try {
        $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return "$($json.$Field)"
    } catch { return '' }
}

function Get-BriefOutcome {
    param([string]$Path)
    try {
        $d = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $rt = $d.resourceType -as [string]
        if ($rt -eq 'OperationOutcome') {
            $errors = @($d.issue | Where-Object { $_.severity -in 'error', 'fatal' })
            if ($errors.Count -gt 0) {
                $diag = "$($errors[0].diagnostics)"
                if (-not $diag) { $diag = "$($errors[0].details.text)" }
                if ($diag.Length -gt 120) { $diag = $diag.Substring(0, 120) }
                return "$($errors.Count) error(s): $diag"
            }
            return 'OK (no errors in OperationOutcome)'
        } elseif ($rt) {
            $rid = $d.id -as [string]
            if ($rid) { return "$rt/$rid" } else { return $rt }
        }
        return 'no resourceType'
    } catch { return 'non-JSON response' }
}

function Invoke-FhirRequest {
    param(
        [string]$Uri,
        [string]$Method,
        [byte[]]$Body
    )
    $headers = @{ Accept = 'application/fhir+json' }
    $statusCode = 0
    $content = '{}'
    try {
        $resp = Invoke-WebRequest -Uri $Uri -Method $Method -Body $Body `
            -ContentType 'application/fhir+json' -Headers $headers -UseBasicParsing
        $statusCode = [int]$resp.StatusCode
        $content    = $resp.Content
    } catch {
        $ex = $_.Exception
        if ($ex -is [System.Net.WebException] -and $null -ne $ex.Response) {
            $statusCode = [int]([System.Net.HttpWebResponse]$ex.Response).StatusCode
            $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
            $content = $sr.ReadToEnd()
            $sr.Close()
        } else {
            $statusCode = 0
            $msg = $ex.Message -replace '"', "'"
            $content = "{`"resourceType`":`"OperationOutcome`",`"issue`":[{`"severity`":`"fatal`",`"diagnostics`":`"$msg`"}]}"
        }
    }
    return [PSCustomObject]@{ Status = $statusCode; Content = $content }
}

function Invoke-FhirUpload {
    param([string]$Label, [string]$Source, [string]$Payload)

    $rt  = Get-JsonField $Payload 'resourceType'
    $rid = Get-JsonField $Payload 'id'

    if (-not $rt) {
        Write-Err "Skipping ${Label}: could not determine resourceType"
        $Results.Add("| $Label | $Source | -- | -- | skipped (no resourceType) |")
        $script:Skip++
        return
    }

    $endpoint = ''; $method = ''
    if ($rt -eq 'Bundle') {
        $btype = Get-JsonField $Payload 'type'
        if ($btype -eq 'transaction' -or $btype -eq 'batch') {
            $endpoint = $BaseUrl; $method = 'POST'; $rid = ''
        } elseif ($rid) {
            $endpoint = "$BaseUrl/$rt/$rid"; $method = 'PUT'
        } else {
            $endpoint = "$BaseUrl/$rt"; $method = 'POST'
        }
    } elseif ($rid) {
        $endpoint = "$BaseUrl/$rt/$rid"; $method = 'PUT'
    } else {
        $endpoint = "$BaseUrl/$rt"; $method = 'POST'
    }

    $slug    = ($Label -replace '[/\\ ]', '_')
    $outFile = "$LogDir\$Source-$slug.json"

    $bytes  = [System.IO.File]::ReadAllBytes($Payload)
    $result = Invoke-FhirRequest -Uri $endpoint -Method $method -Body $bytes
    Write-Utf8 $outFile $result.Content

    $finding    = Get-BriefOutcome $outFile
    $displayRef = if ($rid) { "$rt/$rid" } else { $rt }

    if ($result.Status -ge 200 -and $result.Status -lt 300) {
        Write-Ok "$Label ($displayRef) -> HTTP $($result.Status)"
        $Results.Add("| ``$Label`` | $Source | ``$method $displayRef`` | $($result.Status) | OK $finding |")
        $script:Pass++
    } else {
        Write-Err "$Label ($displayRef) -> HTTP $($result.Status): $finding"
        $Results.Add("| ``$Label`` | $Source | ``$method $displayRef`` | $($result.Status) | FAIL $finding |")
        $script:Fail++
    }
}

# ── 1a. Wait for server ───────────────────────────────────────────────────────

Write-Log "Checking server at $BaseUrl ..."
$serverUp = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $null = Invoke-WebRequest -Uri "$BaseUrl/metadata" -UseBasicParsing -ErrorAction Stop
        Write-Ok 'Server is up'
        $serverUp = $true
        break
    } catch {
        if ($i -eq 12) { Write-Err 'Server not ready after 60s -- aborting'; exit 1 }
        Write-Log "Waiting for server... ($i/12)"
        Start-Sleep -Seconds 5
    }
}

$capMeta    = Invoke-WebRequest -Uri "$BaseUrl/metadata" -UseBasicParsing
$metaJson   = $capMeta.Content | ConvertFrom-Json
$ServerName  = if ($metaJson.software.name)  { "$($metaJson.software.name)"  } else { '?' }
$FhirVersion = if ($metaJson.fhirVersion)    { "$($metaJson.fhirVersion)"    } else { '?' }

# ── 1b. Seed UCUM fragment ────────────────────────────────────────────────────

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$UcumFragment = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\hapi\ucum-fragment.json'))

if (Test-Path $UcumFragment) {
    Write-Log 'Seeding UCUM fragment CodeSystem ...'
    $ucumBytes  = [System.IO.File]::ReadAllBytes($UcumFragment)
    $ucumResult = Invoke-FhirRequest -Uri "$BaseUrl/CodeSystem/ucum-fragment" -Method PUT -Body $ucumBytes
    Write-Utf8 "$LogDir\seed-ucum-fragment.json" $ucumResult.Content
    if ($ucumResult.Status -ge 200 -and $ucumResult.Status -lt 300) {
        Write-Ok "UCUM fragment seeded (HTTP $($ucumResult.Status)) -- waiting for TRM indexing ..."
        Start-Sleep -Seconds 10
    } else {
        Write-Err "UCUM fragment seed failed (HTTP $($ucumResult.Status)) -- UCUM-dependent examples may fail"
    }
} else {
    Write-Err "UCUM fragment not found at $UcumFragment -- skipping (UCUM codes may fail)"
}

# ── 2. Download & extract ph-core examples ────────────────────────────────────

Write-Log "Downloading ph-core $PhCoreVersion package from $PhCoreTgzUrl ..."
$PhCoreTmp   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
$PhCoreCount = 0
New-Item -ItemType Directory -Path $PhCoreTmp -Force | Out-Null
try {
    $tgzFile = "$PhCoreTmp\package.tgz"
    Invoke-WebRequest -Uri $PhCoreTgzUrl -OutFile $tgzFile -UseBasicParsing

    $prevPwd = $PWD
    Set-Location $PhCoreTmp
    try { & tar -xzf $tgzFile 2>$null } finally { Set-Location $prevPwd }

    $exampleDir = "$PhCoreTmp\package\example"
    if (Test-Path $exampleDir) {
        Get-ChildItem $exampleDir -Filter '*.json' | Copy-Item -Destination $CorePayDir
        $PhCoreCount = (Get-ChildItem $CorePayDir -Filter '*.json').Count
        Write-Ok "Extracted $PhCoreCount ph-core examples"
    } else {
        Write-Err 'No example/ dir found in ph-core package'
    }
} catch {
    Write-Err "Failed to download/extract ph-core package: $_"
} finally {
    Remove-Item -Recurse -Force $PhCoreTmp -ErrorAction SilentlyContinue
}

# ── 2b. Post-process ph-core Provenance files ─────────────────────────────────
# ph-core Provenance resources use "targetFormat"/"sigFormat": "xml" which is not
# a valid MIME type in urn:ietf:bcp:13. Fix to "application/xml".
# See docs/known-issues.md#e-provenance-bcp13-mime-type-fix

Write-Log 'Post-processing Provenance files (BCP:13 MIME type fix) ...'
$fixedCount = 0
Get-ChildItem $CorePayDir -Filter '*.json' | ForEach-Object {
    try {
        $raw  = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        $data = $raw | ConvertFrom-Json
        if ($data.resourceType -ne 'Provenance') { return }
        $changed = $false
        foreach ($sig in $data.signature) {
            if ($sig.PSObject.Properties.Name -contains 'targetFormat' -and $sig.targetFormat -eq 'xml') {
                $sig.targetFormat = 'application/xml'; $changed = $true
            }
            if ($sig.PSObject.Properties.Name -contains 'sigFormat' -and $sig.sigFormat -eq 'xml') {
                $sig.sigFormat = 'application/xml'; $changed = $true
            }
        }
        if ($changed) {
            $patched = $data | ConvertTo-Json -Depth 20 -Compress:$false
            Write-Utf8 $_.FullName $patched
            Write-Host "  patched: $($_.Name)" -ForegroundColor DarkGray
            $fixedCount++
        }
    } catch { }
}
if ($fixedCount) {
    Write-Host "  $fixedCount Provenance file(s) patched (targetFormat/sigFormat: xml -> application/xml)" -ForegroundColor DarkGray
} else {
    Write-Host '  no Provenance files needed patching' -ForegroundColor DarkGray
}

# ── 3. Download ph-ereferral examples ─────────────────────────────────────────

Write-Log "Fetching ph-ereferral $PhEreferralVersion examples from GitHub ($EreferralRepo@$EreferralBranch) ..."
$EreferralFiles = @(
    'condition-pregnancy-ex'
    'encounter-anc-ex'
    'encounter-registration-ex'
    'medicationadministration-ifa-ex'
    'observation-blood-pressure-ex'
    'observation-chief-complaint-ex'
    'observation-heart-rate-ex'
    'observation-oxygen-saturation-ex'
    'observation-respiratory-rate-ex'
    'observation-temperature-ex'
    'observation-weight-ex'
    'organization-receiving-facility-ex'
    'organization-sending-facility-ex'
    'patient-charity-ex'
    'practitioner-abraham-ex'
    'practitioner-jane-ex'
    'practitionerrole-abraham-ex'
    'practitionerrole-jane-ex'
    'relatedperson-companion-ex'
    'servicerequest-lab-orders-ex'
    'servicerequest-ultrasound-ex'
    'task-referral-ex'
)

$ErefCount = 0
foreach ($name in $EreferralFiles) {
    $url  = "$EreferralRawBase/$name.json"
    $dest = "$ErefPayDir\$name.json"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        $ErefCount++
    } catch {
        Write-Err "Could not download $name from $url"
    }
}
Write-Ok "Downloaded $ErefCount ph-ereferral examples"

# ── 4. Upload — ordering matters ──────────────────────────────────────────────

Write-Log ''
Write-Log '========================================================='
Write-Log "Uploading ph-core examples ($PhCoreCount files)"
Write-Log '========================================================='

$PhCoreUploadOrder = @(
    'Organization', 'Location', 'HealthcareService',
    'Medication', 'Practitioner',
    'Patient',
    'Coverage',
    'RelatedPerson',
    'PractitionerRole',
    'Condition',
    'Encounter',
    'AllergyIntolerance', 'Immunization',
    'ServiceRequest',
    'Observation-observation-bp', 'Observation-observation-environmental',
    'Observation-observation-glucose', 'Observation-observation-height',
    'Observation-observation-weight', 'Observation-observation-potassium',
    'Observation-observation-sodium', 'Observation-observation-based',
    'Observation-observation-vitals', 'Observation-observation-performer',
    'Observation-observation-derived', 'Observation-observation-lab',
    'Procedure',
    'Observation-observation-part',
    'MedicationRequest',
    'MedicationAdministration', 'MedicationDispense', 'MedicationStatement',
    'Claim',
    'Task', 'Provenance',
    'Bundle'
)

$uploadedPhCore = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($rt in $PhCoreUploadOrder) {
    $rtLower = $rt.ToLower()
    Get-ChildItem $CorePayDir -Filter '*.json' |
        Where-Object { $_.BaseName -like "$rt-*" -or $_.BaseName -like "$rtLower-*" } |
        Sort-Object Name |
        ForEach-Object {
            Invoke-FhirUpload $_.BaseName 'ph-core' $_.FullName
            $null = $uploadedPhCore.Add($_.BaseName)
        }
}

# Upload remaining ph-core files not matched by ordering
Get-ChildItem $CorePayDir -Filter '*.json' | Sort-Object Name | ForEach-Object {
    if (-not $uploadedPhCore.Contains($_.BaseName)) {
        Invoke-FhirUpload $_.BaseName 'ph-core' $_.FullName
    }
}

Write-Log ''
Write-Log '========================================================='
Write-Log "Uploading ph-ereferral examples ($ErefCount files)"
Write-Log '========================================================='

$ErefUploadOrder = @(
    'organization-sending-facility-ex'
    'organization-receiving-facility-ex'
    'practitioner-abraham-ex'
    'practitioner-jane-ex'
    'patient-charity-ex'
    'relatedperson-companion-ex'
    'practitionerrole-abraham-ex'
    'practitionerrole-jane-ex'
    'encounter-registration-ex'
    'encounter-anc-ex'
    'condition-pregnancy-ex'
    'observation-chief-complaint-ex'
    'observation-blood-pressure-ex'
    'observation-heart-rate-ex'
    'observation-oxygen-saturation-ex'
    'observation-respiratory-rate-ex'
    'observation-temperature-ex'
    'observation-weight-ex'
    'medicationadministration-ifa-ex'
    'servicerequest-lab-orders-ex'
    'servicerequest-ultrasound-ex'
    'task-referral-ex'
)

foreach ($name in $ErefUploadOrder) {
    $f = "$ErefPayDir\$name.json"
    if (Test-Path $f) { Invoke-FhirUpload $name 'ph-ereferral' $f }
}

# ── 5. Summary JSON ───────────────────────────────────────────────────────────

$Total = $script:Pass + $script:Fail + $script:Skip
$summary = [ordered]@{
    baseUrl            = $BaseUrl
    server             = $ServerName
    fhirVersion        = $FhirVersion
    phCoreVersion      = $PhCoreVersion
    phEreferralVersion = $PhEreferralVersion
    total              = $Total
    passed             = $script:Pass
    failed             = $script:Fail
    skipped            = $script:Skip
}
Write-Utf8 $SummaryJson ($summary | ConvertTo-Json)

# ── 6. Markdown report ────────────────────────────────────────────────────────

$genTime    = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
$reportRows = ($Results.ToArray() -join "`n")

$mdReport = @"
# FHIR Example Upload Report

Generated: $genTime

## Summary

| Property | Value |
|---|---|
| Server | $BaseUrl ($ServerName, FHIR $FhirVersion) |
| ph-core version | $PhCoreVersion |
| ph-ereferral version | $PhEreferralVersion (from GitHub raw) |
| Total resources | $Total |
| Passed | $script:Pass |
| Failed | $script:Fail |
| Skipped | $script:Skip |

---

## Upload Results

| Resource | Source | Endpoint | HTTP | Result |
|---|---|---|---|---|
$reportRows

---

## Notes

- ph-core examples extracted from ``$PhCoreTgzUrl``
- ph-ereferral examples downloaded from ``https://github.com/$EreferralRepo`` (``$EreferralBranch``)
- Resources uploaded in dependency order (Organizations before Patients, etc.)
- Resources with an ``id`` use ``PUT /{resourceType}/{id}`` (idempotent); others use ``POST``
- Transaction/batch Bundles are executed via ``POST /`` rather than stored (see docs/known-issues.md)
- Provenance BCP:13 fix applied: ``"xml"`` -> ``"application/xml"`` in targetFormat/sigFormat

## Log Files

Raw HAPI responses are in: ``$OutDir\logs\``
"@

Write-Utf8 $ReportMd $mdReport

# ── 7. HTML report ────────────────────────────────────────────────────────────

function ConvertTo-HtmlEsc ([string]$s) {
    $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}
function ConvertTo-HtmlInline ([string]$s) {
    $s = ConvertTo-HtmlEsc $s
    $s = [regex]::Replace($s, '`([^`]+)`', '<code>$1</code>')
    $s = [regex]::Replace($s, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    return $s
}

$summaryRows = @(
    @("Server", "$BaseUrl ($ServerName, FHIR $FhirVersion)")
    @("ph-core version", $PhCoreVersion)
    @("ph-ereferral version", "$PhEreferralVersion (from GitHub raw)")
    @("Total resources", "$Total")
    @("Passed", "$($script:Pass)")
    @("Failed", "$($script:Fail)")
    @("Skipped", "$($script:Skip)")
) | ForEach-Object { "<tr><th>$(ConvertTo-HtmlEsc $_[0])</th><td>$(ConvertTo-HtmlEsc $_[1])</td></tr>" }

$resultRows = $Results | ForEach-Object {
    $cols = ($_ -replace '^\| ?' -replace ' ?\|$').Split('|') | ForEach-Object { $_.Trim() }
    $cells = $cols | ForEach-Object { "<td>$(ConvertTo-HtmlInline $_)</td>" }
    "<tr>$($cells -join '')</tr>"
}

$noteItems = @(
    "ph-core examples extracted from <code>$(ConvertTo-HtmlEsc $PhCoreTgzUrl)</code>"
    "ph-ereferral examples downloaded from <code>$(ConvertTo-HtmlEsc "https://github.com/$EreferralRepo")</code> (<code>$EreferralBranch</code>)"
    "Resources uploaded in dependency order (Organizations before Patients, etc.)"
    "Resources with an <code>id</code> use <code>PUT /{resourceType}/{id}</code> (idempotent); others use <code>POST</code>"
    "Transaction/batch Bundles executed via <code>POST /</code> rather than stored (see docs/known-issues.md)"
    "Provenance BCP:13 fix applied: <code>&quot;xml&quot;</code> &rarr; <code>&quot;application/xml&quot;</code> in targetFormat/sigFormat"
    "Raw HAPI responses in: <code>$(ConvertTo-HtmlEsc "$OutDir\logs\")</code>"
)

$css = @'
body{font-family:Arial,Helvetica,sans-serif;max-width:1100px;margin:30px auto;line-height:1.45;color:#111}
h1{font-size:28px;margin-bottom:24px}h2{font-size:22px;margin-top:30px}
hr{border:0;border-top:2px solid #ddd;margin:24px 0}
table{border-collapse:collapse;width:100%;margin:14px 0}
th,td{border:1px solid #ddd;padding:6px 10px;text-align:left;vertical-align:top}
th{background:#f7f7f7;font-weight:700}
code{background:#f4f4f4;padding:2px 4px;border-radius:3px;font-size:0.9em}
p{margin:6px 0}li{margin:4px 0}
'@

$html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>FHIR Upload Report</title><style>$css</style></head>
<body>
<h1>FHIR Example Upload Report</h1>
<p>Generated: $genTime</p>
<h2>Summary</h2>
<table><tbody>$($summaryRows -join '')</tbody></table>
<hr>
<h2>Upload Results</h2>
<table><tbody>
<tr><th>Resource</th><th>Source</th><th>Endpoint</th><th>HTTP</th><th>Result</th></tr>
$($resultRows -join "`n")
</tbody></table>
<hr>
<h2>Notes</h2>
<ul>$($noteItems | ForEach-Object { "<li>$_</li>" })</ul>
</body></html>
"@

Write-Utf8 $ReportHtml $html

# ── 8. Console summary ────────────────────────────────────────────────────────

Write-Host ''
Write-Host '====================================================' -ForegroundColor White
Write-Host 'Upload complete' -ForegroundColor White
Write-Host "  Total  : $Total"
Write-Host "  Passed : $($script:Pass)" -ForegroundColor Green
if ($script:Fail -gt 0) {
    Write-Host "  Failed : $($script:Fail)" -ForegroundColor Red
} else {
    Write-Host "  Failed : $($script:Fail)"
}
Write-Host "  Skipped: $($script:Skip)"
Write-Host ''
Write-Host 'Reports:'
Write-Host "  Markdown : $ReportMd"
Write-Host "  HTML     : $ReportHtml"
Write-Host "  JSON     : $SummaryJson"
Write-Host "  Logs     : $LogDir\"
Write-Host '====================================================' -ForegroundColor White
