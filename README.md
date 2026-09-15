# vSphere Application Profile Collector

## Purpose

`collect_app_profile.py` is the main application profile collector.
`collect_app_profile.ps1` is its PowerCLI companion and mirrors the Python
collector's parameters, completeness policy, and schema. It is read-only and
writes one structured JSON profile for subsequent analysis.

## Requirements

- PowerShell 5.1 or PowerShell 7 with VMware PowerCLI.
- Network access to the vCenter HTTPS/API endpoint (port 443 by default).
- A vCenter account that can view the selected VMs, their configuration, and historical performance statistics. A read-only account scoped to the required inventory is recommended.
- Exact VM display names as shown in vCenter.

Install VMware PowerCLI:

```powershell
Install-Module VMware.PowerCLI -Scope CurrentUser
```

Confirm the script is ready:

```powershell
Get-Help ./collect_app_profile.ps1 -Full
```

## Input Parameters

| Parameter | Default Value | Description |
|---|---|---|
| `-Host` | Required | vCenter Server hostname or IP address. |
| `-Port` | `443` | vCenter HTTPS port. |
| `-User` | Required | vCenter login name. |
| `-Password` | Prompt or `VSPHERE_PASSWORD` | vCenter password. Omit to use the environment variable or a secure interactive prompt. |
| `-NoSslVerify` | Disabled | Disables TLS certificate verification; use only when necessary. |
| `-VMs` | None | Comma-separated VM display names. Required unless `-VmFile` is used. |
| `-VmFile` | None | Text file containing one VM display name per line. Required unless `-VMs` is used. |
| `-Interval` | `336` hours | Amount of historical performance data to collect. |
| `-AppName` | Empty | Optional application label stored in the output metadata. |
| `-JsonOut` | Required | Path of the JSON output file. |

## Collect a Profile

### Specify VMs on the command line

The following example collects the default 336 hours (14 days) of history. The password is requested securely at the terminal:

```powershell
./collect_app_profile.ps1 -Host vcenter.source.example.com -User readonly@vsphere.local -VMs "web01,web02,app01,db01" -AppName "Customer Portal" -JsonOut customer_portal_profile.json
```

### Read VM names from a file

Create `vms.txt` with one VM display name per line. Blank lines and lines beginning with `#` are ignored:

```text
# Customer Portal VMs
web01
web02
app01
db01
```

Run:

```powershell
./collect_app_profile.ps1 -Host vcenter.source.example.com -User readonly@vsphere.local -VmFile vms.txt -Interval 720 -AppName "Customer Portal" -JsonOut customer_portal_profile.json
```

`-Interval 720` requests 30 days of history. Use 336 hours when no different collection window has been agreed.

### Self-signed vCenter certificate

Prefer a trusted vCenter certificate. If certificate validation fails and the site administrator has verified the endpoint, add:

```powershell
./collect_app_profile.ps1 -Host vcenter.source.example.com -User readonly@vsphere.local -VMs "web01,web02,app01,db01" -JsonOut customer_portal_profile.json -NoSslVerify
```

`-NoSslVerify` disables TLS certificate verification and should be used only when necessary.

## Password Handling

If `-Password` is omitted, the script prompts without displaying the password. This is the recommended method.

For unattended execution, set `VSPHERE_PASSWORD` for the command and remove it afterward according to local security policy. Avoid `-Password` because command-line arguments may be recorded in shell history or process listings.

## Validate and Return the Result

A successful run ends with `COLLECTION COMPLETE` and prints the output path,
number of profiled VMs, and profile-quality warning when applicable. Output is
written even when some or all requested VMs are unavailable so a downstream
assessment can still report the available evidence and its limitations.

Before returning the file:

1. Check `PROFILE INCOMPLETE` / `PROFILE UNUSABLE` and `VMs missing`. Correct
	names and rerun when practical; otherwise retain the profile and expect LOW
	confidence in the assessment.
2. Confirm that the JSON file exists and is not empty.
3. Return the JSON file through the approved secure transfer channel.

Example PowerShell checks:

```powershell
Get-Item customer_portal_profile.json
Get-Content customer_portal_profile.json -Raw | ConvertFrom-Json | Out-Null
Write-Host "JSON is valid"
```

The JSON contains VM names, host and cluster placement, guest details, IP/MAC information, storage details, and performance measurements. Treat it as sensitive infrastructure data. The vCenter password is not written to the JSON.

The output matches schema 1.1 from `collect_app_profile.py`: `profile_quality`
records requested, collected, missing, and powered-off VMs, while each
timestamped profile records `vm_participation`. Complete-case timestamps drive
normal statistics. If none remain, partial sums are retained only as a labelled
LOW-confidence fallback. Observed zero and missing data remain distinct.

## Common Problems

- **Connection or certificate error:** verify the vCenter hostname, port, network access, and certificate trust.
- **Authentication or permission error:** verify the account and its read access to the required VM inventory and performance data.
- **`NOT FOUND` VM:** verify the VM display name in vCenter; names are matched exactly, ignoring letter case.
- **No or few performance samples:** confirm that vCenter historical statistics are enabled and retained for the requested interval.
- **Output file error:** write to an existing directory where the current user has permission.
