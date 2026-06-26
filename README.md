# Sync-CalendarSubscriptions

A PowerShell bundle that uses [GAM7](https://github.com/GAM-team/GAM) to automatically subscribe Google Group members to one or more Google Calendars. Group membership is resolved recursively, so users in nested child groups are included. Each group can be mapped to its own set of calendars.

---

## Requirements

- PowerShell 5.x
- [GAM7](https://github.com/GAM-team/GAM/wiki/How-to-Install-GAM7) installed and configured with appropriate Google Workspace admin credentials
- Windows (uses Windows Event Log for logging)

---

## Structure
```
Deploy-CalendarSubscriptions/
├── Modules/
│   └── CalendarEngine.psm1     # Core logic
├── State/                      # Data
│   └── state-<GroupEmail>.json
├── Config.psd1                 # Maps groups and calendars
├── Manage-Subscriptions.ps1    # TUI for managing data
└── Run-Deployment.ps1          # GAM wrapper, runs headless
```
## Setup

### 1. Configure GAM7

Ensure GAM7 is installed and authorized for your Google Workspace domain before using this script. GAM7 must be accessible on the `PATH` of whichever account runs the script (including the service account used by Task Scheduler, if applicable).

See the [GAM7 installation guide](https://github.com/GAM-team/GAM/wiki/How-to-Install-GAM7) for details.

### 2. Add Calendars and Groups

Run the TUI in PowerShell
```powershell
.\Manage-Subscriptions.ps1
```

Use the menu to add one or more Google Groups and Calendars, or to manage the State. The config is saved as `config.psd1` in the same directory as the script.

```
@{
    "Groups":  @(
                   {
                       "Email":  "group1@domain.tld",
                       "Label":  "Group 1",
                       "CalendarIds": [
                                          "c_789lmnop...@group.calendar.google.com"
                       ]
                   },
                   {
                       "Email":  "group2@domain.tld",
                       "Label":  "Group 2",
                       "CalendarIds":  [
                                           "c_123xyz...@group.calendar.google.com",
                                           "c_456jkl...@resource.calendar.google.com"
                                       ]
                   }
               )
    "Calendars":  @(
                      {
                          "Id":  "c_123xyz...@group.calendar.google.com",
                          "Label":  "Events"
                      },
                      {
                          "Id":  "c_456jkl...@resource.calendar.google.com",
                          "Label":  "Conference Room"
                      },
                      {
                          "Id":  "c_789lmnop...@group.calendar.google.com",
                          "Label":  "Party Planning Committee"
                      }
                  )
}
```

Each group maps to its own list of calendars via `CalendarIds`. A calendar can be linked to multiple groups. The top-level `Calendars` array is the shared pool that groups reference from by ID.

---

## Usage

### Run manual "deployment"

```powershell
.\Run-Deployment.ps1
```

### Manage Calendars & Groups

```powershell
.\Manage-Subscriptions.ps1
```
---

## How It Works

For each Group defined in `Config.psd1`, the script:

1. Resolves which calendars are linked to that group via `CalendarIds`
2. Calls GAM7 to fetch all user members of the group, recursively resolving any nested child groups (`recursive types user`)
3. Validates that at least one user was returned
4. Compares the list of users and calendars against that group's state file (stored in `.\state` by default), filtering out users below the SyncDays threshold
5. For each linked calendar, calls GAM7 to add the calendar to each user's account with `selected true` (visible by default)

## State
The deployment process will save a list (a state file) of users and calendar relationships for each group, along with a timestamp. When it pulls down the latest group members into a temp CSV, it will compare that membership against the state file. Deployment will run for any new members of the group. Other members will be skipped. If needed, the state file can be deleted and rebuilt on the next deployment run. If GAM hits a snag, the state file will save where it had left off, and will catch up the deployment on the next scheduled run.

> **FYI**
> 1. If a user is a member of multiple nested child groups within the same parent, they may appear more than once in the member list. This does not cause problems but will be reflected in the logged user count.
> 2. Groups with no linked calendars are skipped, logging a warning.

---

## Logging

All activity is written to the **Windows Event Log** under `Application` with the source `Deploy-GroupCalendars` (or whatever `-AppTitle` is set to).

| Event                            | Level       |
| -------------------------------- | ----------- |
| Deploy started for a group       | Information |
| User count found                 | Information |
| Calendar being processed         | Information |
| Deploy complete for a group      | Information |
| No members found / group missing | Error       |
| Any unhandled exception          | Error       |

To view logs:

```
Event Viewer → Windows Logs → Application → Source: Deploy-GroupCalendars
```

> **First run:** Creating a new Event Log source requires administrator privileges. If the script is not run as an administrator on first use, it will fall back to `Write-Output` for that session. Run once as administrator (or pre-register the source) to initialize it permanently.

### Pre-register the Event Log source (run once as administrator)

```powershell
New-EventLog -LogName Application -Source "Deploy-GroupCalendars"
```

---

## Scheduling

To run on a schedule, create a Task Scheduler job that calls:

```
Program: powershell.exe
Arguments: -NonInteractive -ExecutionPolicy Bypass -Command "& 'C:\Scripts\Deploy-CalendarSubscriptions\Run-Deployment.ps1'"
```
_Make sure this points to the script on your own system!_

Ensure the task runs under an account that has:
- GAM7 on its `PATH`
- GAM7 credentials configured for that user profile
- Permission to write to the Windows Event Log (or the source pre-registered by an admin)

---
