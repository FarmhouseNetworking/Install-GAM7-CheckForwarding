<#
.SYNOPSIS
    Installs/updates GAM7 from the GAM-team GitHub releases, authorizes it for one Google Workspace
    tenant, then reports a user's Gmail forwarding settings and filters.

.DESCRIPTION
    Run INTERACTIVELY on an admin workstation (not through an RMM as SYSTEM):
    "gam create project", "gam oauth create" and "update serviceaccount" open a browser and need a
    super admin of the client tenant to sign in.

    Multi-tenant by design: each domain gets its own config folder (<ConfigRoot>\<Domain>), so
    credentials for different clients never mix. Re-running for an already-authorized domain skips
    straight to the report.

    To use GAM later for that tenant in any PowerShell window:
        $env:GAMCFGDIR = 'C:\GAMConfig\<domain>'; gam info domain

    SECURITY: the config folder holds credentials that can read every mailbox in the tenant
    (domain-wide delegation). Keep it on an encrypted, admin-only machine.

.EXAMPLE
    .\Install-GAM7-CheckForwarding.ps1 -AdminEmail admin@contoso.com -Domain contoso.com -TargetUser frontdesk@contoso.com

.EXAMPLE
    # several mailboxes at once
    .\Install-GAM7-CheckForwarding.ps1 -AdminEmail admin@contoso.com -Domain contoso.com -TargetUser alice@contoso.com,bob@contoso.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AdminEmail,   # super admin in the client tenant
    [Parameter(Mandatory)] [string]$Domain,       # primary domain of the client tenant
    [Parameter(Mandatory)] [string[]]$TargetUser, # mailbox(es) to check
    [string]$InstallDir = 'C:\GAM7',
    [string]$ConfigRoot = 'C:\GAMConfig',
    [string]$WorkDir    = 'C:\GAMWork',
    [switch]$Update                                 # force re-download even if gam.exe exists
)

# 'Continue' on purpose: GAM writes progress to stderr, and in Windows PowerShell 5.1 a 2>&1 redirect
# under 'Stop' turns that into a terminating error. Cmdlets that must succeed use -ErrorAction Stop.
$ErrorActionPreference = 'Continue'
$PSDefaultParameterValues['Invoke-RestMethod:ErrorAction'] = 'Stop'
$PSDefaultParameterValues['Invoke-WebRequest:ErrorAction'] = 'Stop'
$PSDefaultParameterValues['Expand-Archive:ErrorAction']    = 'Stop'
$PSDefaultParameterValues['Copy-Item:ErrorAction']         = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Step([string]$m) { Write-Host "`n=== $m" -ForegroundColor Cyan }

# GAM asks questions on stdin (scope menus, "press enter once trust is complete"). PowerShell ISE has
# no real console, so gam.exe waits forever for input that never arrives. Refuse to start there.
if ($Host.Name -eq 'Windows PowerShell ISE Host') {
    throw 'Run this in a normal PowerShell or Windows Terminal window, not PowerShell ISE - ISE cannot send keyboard input to gam.exe and the setup will hang.'
}

# ---------------------------------------------------------------- 1. Install / update from GitHub
$gamExe = Join-Path $InstallDir 'gam.exe'
if ($Update -or -not (Test-Path $gamExe)) {
    Step 'Downloading latest GAM7 release from GitHub'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x86_64' }
    $rel  = Invoke-RestMethod -Uri 'https://api.github.com/repos/GAM-team/GAM/releases/latest' -Headers @{ 'User-Agent' = 'GAM7-Installer-Script' }
    $asset = $rel.assets | Where-Object { $_.name -match "windows-$arch\.zip$" } | Select-Object -First 1
    if (-not $asset) { throw "No windows-$arch .zip asset found in GAM release $($rel.tag_name)" }
    Write-Host "Release $($rel.tag_name): $($asset.name)"

    $tmp = Join-Path $env:TEMP ("gam7_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath "$tmp\x" -Force

    $found = Get-ChildItem "$tmp\x" -Recurse -Filter gam.exe | Select-Object -First 1
    if (-not $found) { throw 'gam.exe not found inside the downloaded archive' }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $found.DirectoryName '*') -Destination $InstallDir -Recurse -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    # add to the USER Path (no admin rights needed); takes effect in new windows
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    if (($userPath -split ';') -notcontains $InstallDir) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$InstallDir"), 'User')
        Write-Host "Added $InstallDir to your user Path (open a new window to use 'gam' directly)"
    }
} else {
    Write-Host "GAM already installed at $InstallDir (use -Update to refresh)"
}
& $gamExe version | Select-Object -First 1

# ---------------------------------------------------------------- 2. Per-tenant config folder
$ConfigDir = Join-Path $ConfigRoot $Domain
foreach ($d in $ConfigDir, $WorkDir) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
$env:GAMCFGDIR = $ConfigDir     # this session only; keeps each client's credentials separate
Write-Host "GAMCFGDIR = $ConfigDir"

if (-not (Test-Path (Join-Path $ConfigDir 'gam.cfg'))) {
    Step 'Initializing GAM config'
    & $gamExe config drive_dir $WorkDir save verify
}

# ---------------------------------------------------------------- 3. Authorization (interactive)
$haveProject = (Test-Path (Join-Path $ConfigDir 'client_secrets.json')) -and (Test-Path (Join-Path $ConfigDir 'oauth2service.json'))
$haveOauth   = Test-Path (Join-Path $ConfigDir 'oauth2.txt')

if (-not $haveProject) {
    Step "Creating Google Cloud project - sign in as $AdminEmail when the browser opens"
    Write-Host 'When prompted, create a "Desktop App" OAuth client and paste its Client ID and Secret.' -ForegroundColor Yellow
    & $gamExe create project
    if (-not (Test-Path (Join-Path $ConfigDir 'client_secrets.json'))) { throw 'Project creation did not complete (client_secrets.json missing). Re-run the script.' }
}

if (-not $haveOauth) {
    Step "Authorizing admin access - sign in as $AdminEmail"
    Write-Host 'Pick the scopes you need (do NOT select all - the URL gets too long), then enter c.' -ForegroundColor Yellow
    & $gamExe oauth create
    if (-not (Test-Path (Join-Path $ConfigDir 'oauth2.txt'))) { throw 'Admin OAuth did not complete (oauth2.txt missing). Re-run the script.' }
}

# Google's default org policy (iam.disableServiceAccountKeyUpload) often blocks the key GAM uploads
# during "create project", leaving oauth2service.json with an empty private_key. Detect that and explain.
$saFile = Join-Path $ConfigDir 'oauth2service.json'
$saKey  = $null
try { $saKey = (Get-Content $saFile -Raw -ErrorAction Stop | ConvertFrom-Json).private_key } catch { }
if (-not $saKey) {
    $proj = $null
    try { $proj = (Get-Content $saFile -Raw -ErrorAction Stop | ConvertFrom-Json).project_id } catch { }
    Write-Host "`nThe service account has NO KEY ($saFile has an empty private_key)." -ForegroundColor Red
    Write-Host 'This is almost always the Google Cloud org policy that blocks service account key upload. To fix:' -ForegroundColor Yellow
    Write-Host "  1. console.cloud.google.com > select the ORGANIZATION > IAM & Admin > IAM > Grant access:"
    Write-Host "     give $AdminEmail the 'Organization Policy Administrator' role."
    Write-Host "  2. Select project '$proj' > IAM & Admin > Organization Policies. For BOTH"
    Write-Host "     iam.disableServiceAccountKeyUpload and iam.managed.disableServiceAccountKeyUpload:"
    Write-Host "     Manage policy > Override parent's policy > Enforcement Off > Set policy. Wait 2-3 minutes."
    Write-Host "  3. In this window:  `$env:GAMCFGDIR = '$ConfigDir'; & '$gamExe' upload sakey"
    Write-Host "  4. Re-run this script. Afterwards, turn both policies back ON and remove the role."
    throw 'Service account key missing - see the steps above.'
}

Step 'Checking service account (domain-wide delegation)'
$authorized = $false
for ($i = 1; $i -le 5 -and -not $authorized; $i++) {
    $out = & $gamExe user $AdminEmail check serviceaccount 2>&1 | Out-String
    Write-Host $out
    if ($out -match 'fully authorized|All scopes PASSED') { $authorized = $true; break }

    if ($i -eq 1) {
        Write-Host 'Not authorized yet - selecting scopes (include the Gmail settings scopes), then enter c.' -ForegroundColor Yellow
        & $gamExe user $AdminEmail update serviceaccount
        Write-Host "`nOpen the link above (or Admin console > Security > API controls > Domain-wide delegation)," -ForegroundColor Yellow
        Write-Host 'tick "Overwrite existing client ID" and click AUTHORIZE.' -ForegroundColor Yellow
    }
    $ans = Read-Host "Press Enter to re-check (attempt $($i+1) of 5), or S to stop"
    if ($ans -match '^[sS]') { break }
}
if (-not $authorized) { throw 'Service account is not authorized. Fix delegation in the Admin console and re-run.' }

# ---------------------------------------------------------------- 4. Save tenant details
Step 'Recording customer ID and domain'
$info = & $gamExe info domain 2>&1 | Out-String
$cust = [regex]::Match($info, 'Customer ID:\s*(C\w+)').Groups[1].Value
if ($cust) {
    & $gamExe config customer_id $cust domain $Domain timezone local save | Out-Null
    Write-Host "Customer ID $cust saved for $Domain"
} else {
    Write-Warning 'Could not read the Customer ID from "gam info domain" - set it later with: gam config customer_id <ID> domain <domain> save'
}

# ---------------------------------------------------------------- 5. Forwarding report
foreach ($u in $TargetUser) {
    Step "Forwarding report: $u"
    $report = Join-Path $WorkDir ("{0}_forwarding_{1}.txt" -f ($u -replace '[@.]','_'), (Get-Date -Format 'yyyyMMdd-HHmmss'))
    & {
        "Forwarding report for $u - generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') by $env:USERNAME"
        "`n--- Automatic forwarding (show forward)"
        & $gamExe user $u show forward 2>&1
        "`n--- Verified forwarding addresses (show forwardingaddresses)"
        & $gamExe user $u show forwardingaddresses 2>&1
        "`n--- Filters (show filters) - look for any 'forward' action"
        & $gamExe user $u show filters 2>&1
        "`n--- Delegates (show delegates) - someone else reading the mailbox"
        & $gamExe user $u show delegates 2>&1
    } | Tee-Object -FilePath $report
    Write-Host "`nSaved: $report" -ForegroundColor Green
}

Write-Host "`nTo use GAM for this tenant later:  `$env:GAMCFGDIR = '$ConfigDir'; gam <command>" -ForegroundColor Cyan