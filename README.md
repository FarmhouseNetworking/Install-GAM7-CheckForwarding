# Install-GAM7-CheckForwarding

Installs [GAM7](https://github.com/GAM-team/GAM) on a Windows admin workstation, authorizes it
for a Google Workspace tenant, and reports a mailbox's Gmail forwarding setup - automatic
forwarding, verified forwarding addresses, filters with forward actions, and delegates.

Built for incident response: when a mailbox may be leaking mail (a BEC investigation, a user who
turned on forwarding, a compliance question), this answers "where does this mailbox's mail go?"
in one run and saves the answer to a timestamped text file for the ticket.

## Why not just use the Admin console?

The Admin console has no per-user page that shows a forwarding address. The audit log
(*Reporting > Audit and investigation > User log events*, event "Out of domain email forwarding
enabled") only records forwarding to **external** addresses, and it never shows **filters**
that forward mail. GAM reads the mailbox's actual settings.

## What it does

1. **Installs or updates GAM7.** Downloads the latest Windows `.zip` (x86_64 or ARM64) from the
   GAM-team GitHub releases, extracts it to `C:\GAM7`, and adds that folder to the *user* `Path`.
   No admin rights needed.
2. **Keeps one config folder per tenant.** Credentials for each domain go to
   `C:\GAMConfig\<domain>`, and `GAMCFGDIR` is set for the session only, so different clients'
   credentials never mix.
3. **Authorizes interactively** (first run per tenant only): `gam create project`,
   `gam oauth create`, then domain-wide delegation with `update serviceaccount`. It re-checks the
   delegation up to 5 times, because Google can take a few minutes to apply it.
4. **Saves the tenant's customer ID** to that tenant's `gam.cfg`.
5. **Writes the forwarding report** for each `-TargetUser` to
   `C:\GAMWork\<user>_forwarding_<timestamp>.txt`.

Re-running for a tenant that's already authorized skips straight to step 5.

## Usage

Run in an interactive PowerShell window. Steps 3 and 4 open a browser and need a **super admin
of the client tenant** to sign in, so this **can't** run unattended through an RMM as SYSTEM.

```powershell
.\Install-GAM7-CheckForwarding.ps1 -AdminEmail admin@contoso.com -Domain contoso.com -TargetUser frontdesk@contoso.com

# several mailboxes at once
.\Install-GAM7-CheckForwarding.ps1 -AdminEmail admin@contoso.com -Domain contoso.com -TargetUser alice@contoso.com,bob@contoso.com

# force a GAM update
.\Install-GAM7-CheckForwarding.ps1 -AdminEmail admin@contoso.com -Domain contoso.com -TargetUser alice@contoso.com -Update
```

| Parameter | Default | Purpose |
|---|---|---|
| `-AdminEmail` | *(required)* | Super admin in the client tenant |
| `-Domain` | *(required)* | Primary domain of the tenant; also names the config folder |
| `-TargetUser` | *(required)* | Mailbox or mailboxes to report on |
| `-InstallDir` | `C:\GAM7` | Where GAM is installed |
| `-ConfigRoot` | `C:\GAMConfig` | Parent folder for the per-tenant config folders |
| `-WorkDir` | `C:\GAMWork` | GAM working folder; reports are saved here |
| `-Update` | off | Re-download GAM even if it's already installed |

**Use a normal PowerShell or Windows Terminal window, not PowerShell ISE.** ISE can't pass
keyboard input to `gam.exe`, so setup hangs at the first GAM prompt. The script refuses to start
in ISE.

**Trust the GAM setup app first.** During `gam create project`, GAM asks you to mark its
"GAM Project Creation" client ID as **Trusted** in the tenant (*Admin console > Security >
Access and data control > API controls > Manage third-party app access > Configure new app*),
then press Enter. GAM prints the exact client ID and link. Once setup is finished, you can remove
that trust again.

**"Unable to load PEM file" or an empty service account key.** Newer Google Cloud
organizations block service account key upload by default (`iam.disableServiceAccountKeyUpload`).
When that happens, `gam create project` finishes but `oauth2service.json` has no `private_key`.
The script detects this and stops with the fix:
1. Grant yourself **Organization Policy Administrator** at the organization level.
2. On the GAM project, set both `iam.disableServiceAccountKeyUpload` and
   `iam.managed.disableServiceAccountKeyUpload` to **Enforcement Off**, then wait a few minutes.
3. Run `gam upload sakey` with `GAMCFGDIR` pointing at the tenant folder.
4. Re-run the script. Afterwards, turn the policies back on and remove the role.
   The uploaded key keeps working.

When choosing scopes during authorization, **don't select all of them**: the sign-in URL gets
too long and fails. For the service account, include the Gmail settings scopes; the forwarding,
filter and delegate commands need them.

## Using GAM afterwards

```powershell
$env:GAMCFGDIR = 'C:\GAMConfig\contoso.com'; gam user alice@contoso.com show forward
```

## Security

The per-tenant config folder holds credentials with **domain-wide delegation**. Anyone who has
those files can read every mailbox in that tenant. Keep `C:\GAMConfig` on an encrypted,
admin-only machine, and when you're done with a tenant, remove the
client ID under *Security > API controls > Domain-wide delegation* in its Admin console.

## Requirements

- Windows 10/11, Windows PowerShell 5.1 or PowerShell 7
- Internet access to `api.github.com` / `github.com` and Google APIs
- A super admin account in the target Google Workspace tenant