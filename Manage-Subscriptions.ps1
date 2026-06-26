<#
    .SYNOPSIS
        Interactive TUI for managing Google Calendar subscriptions.
    .DESCRIPTION
        Provides a menu-driven interface to manage groups, calendars, and
        state records utilizing a config.psd1 file and a SQLite database.
#>
[CmdletBinding()]
param(
  [string]$AppTitle   = "Deploy-CalendarSubscriptions",
  [string]$ConfigPath = (Join-Path $PSScriptRoot "Config.psd1"),
  [string]$StateDir   = (Join-Path $PSScriptRoot "State")
)

# --- Bootstrapper / Module Loading ---
$EngineModulePath = Join-Path $PSScriptRoot "Modules\CalendarEngine.psm1"
if (-not (Test-Path $EngineModulePath)) {
    Write-Error "Core Engine Module missing at '$EngineModulePath'."
    exit 1
}
Import-Module $EngineModulePath -Force

# --- TUI Exclusives / Menu Helpers ---
function Write-Header {
    param([string]$Title)
    Clear-Host
    Write-Host ""
    Write-Host "=== $AppTitle - $Title ===" -ForegroundColor Cyan
    Write-Host ""
}

function Select-FromList {
  param(
    [string]$Prompt,
    [array]$Items,
    [scriptBlock]$DisplayScript
  )
  if ($null -eq $Items -or $Items.Count -eq 0) {
    Write-Host "  (none)" -ForegroundColor DarkGray
    return $null
  }
  for ($i = 0; $i -lt $Items.Count; $i++) {
    Write-Host "  [$($i + 1)]  $(& $DisplayScript $Items[$i])"
  }
  Write-Host "`n  [X]  Cancel"
  $choice = Read-Host $Prompt
  if ($choice.ToUpper() -eq "X" -or [string]::IsNullOrWhiteSpace($choice)) { return $null }

  $index = 0
  if ([int]::TryParse($choice, [ref]$index)) {
    $index--
    if ($index -ge 0 -and $index -lt $Items.Count) { return $Items[$index] }
  }
  Write-Host "Invalid Selection" -ForegroundColor Red
  Start-Sleep -Seconds 2
  return $null
}

# --- MENU: Calendars ---
function Show-CalendarMenu {
  while ($true) {
    $cfg = Read-Config -ConfigPath $ConfigPath
    Write-Header "Manage Calendars"

    $calendars = @($cfg.Calendars)
    if ($calendars.Count -eq 0) {
      Write-Host "  (no calendars defined)`n" -ForegroundColor DarkGray
    } else {
      Write-Host "Calendars:`n" -ForegroundColor Yellow
      $calendars | ForEach-Object { Write-Host "  - $($_.Label) ( $($_.Id) )" }
      Write-Host ""
    }

    Write-Host "  [1]  Add Calendar`n  [2]  Link/Unlink Group`n  [3]  Delete Calendar`n  [X]  Back"
    $choice = Read-Host "`nSelection"

    switch ($choice.ToUpper()) {
      "1" {
        $id = (Read-Host "Enter Calendar ID").Trim()
        $label = (Read-Host "Enter Label (e.g. Corporate Events)").Trim()
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($label)) { continue }

        if ($cfg.Calendars | Where-Object { $_.Id -eq $id }) {
          Write-Host "A calendar with that ID already exists." -ForegroundColor Yellow
          Start-Sleep -Seconds 2
          continue
        }
        $cfg.Calendars += @{ Id = $id; Label = $label }
        Save-Config -ConfigPath $ConfigPath -ConfigData $cfg
      }
      "2" {
        Write-Header "Select Calendar to manage"
        $calendar = Select-FromList -Prompt "`nSelect calendar" -Items $calendars -DisplayScript { param($c) "$($c.Label) ($($c.Id))" }
        if ($calendar) { Show-LinkCalendarMenu -Calendar $calendar -Source "Calendar"}
      }
      "3" {
        Write-Header "Delete Calendar"
        $cal = Select-FromList -Prompt "`nSelect calendar to delete" -Items @($cfg.Calendars) -DisplayScript { param($c) "$($c.Label) ($($c.Id))" }
        if ($cal) {
          Write-Host "`nThis will delete '$($cal.Label)' from this system. `nAny linked groups will still remain in the system." -ForegroundColor Yellow
          $confirm = Read-Host "`nEnter 'DELETE' to verify '$($cal.Label)' deletion"
          if ($confirm.ToUpper() -eq "DELETE") {
            # Handle Group Unlinking
            foreach ($group in $cfg.Groups) {
              if ($group.CalendarIds -contains $cal.Id) {
                $group.CalendarIds = @($group.CalendarIds | Where-Object { $_ -ne $cal.Id })
              }
            }
            $cfg.Calendars = @($cfg.Calendars | Where-Object { $_.Id -ne $cal.Id })
            Save-Config -ConfigPath $ConfigPath -ConfigData $cfg -Operation "Calendar Deletion"
            return
          } else {
            Write-Host "`nCalendar Deletion Cancelled." -ForegroundColor Red
            Start-Sleep -Seconds 2
            continue
          }
        }
      }
      "X" { return }
    }
  }
}

# --- MENU: Groups ---
function Show-LinkCalendarMenu {
  <#
    .SYNOPSIS
      Menu for linking groups and calendars.
    .PARAMETER Source
      Switch - expects "Group" or "Calendar" - denoting which is the source menu (are you linking a Calendar to a Group or a Group to a Calendar)
    .PARAMETER Group
      Group object
    .PARAMETER Calendar
      Calendar object
  #>
  param(
    [string]$Source,
    [PSCustomObject]$Group    = $null,
    [PSCustomObject]$Calendar = $null
    )

    while ($true) {
      $cfg = Read-Config -ConfigPath $ConfigPath

      switch ($Source.ToLower()) {
        "group" {
          $selectedGroup = $cfg.Groups | Where-Object { $_.Email -eq $Group.Email }
          if (-not $selectedGroup) { return }

          Write-Header "Group: $($selectedGroup.Label)"
          # A Calendar is linked if this Group's CalendarIds contain the Calendar Id
          $linked = @($cfg.Calendars | Where-Object { $selectedGroup.CalendarIds -contains $_.Id })

          Write-Host "Linked Calendars: "
          if ($linked.Count -eq 0) { Write-Host " (none)" -ForegroundColor DarkGray }
          else { $linked | ForEach-Object { Write-Host "  - $($_.Label) ($($_.Id))" } }
          Write-Host ""

          Write-Host "  [1]  Link Calendar`n  [2]  Unlink Calendar`n  [X]  Back"
          $choice = Read-Host "`nSelection"

          switch ($choice.ToUpper()) {
            "1" {
              Write-Header "Link Calendar"
              $unlinked = @($cfg.Calendars | Where-Object { $selectedGroup.CalendarIds -notcontains $_.Id })
              if ($unlinked.Count -eq 0) {Write-Host "No unlinked calendars for this group."; Start-Sleep -Seconds 2 }
              $targetCal = Select-FromList -Prompt "`nSelect calendar to link" -Items $unlinked -DisplayScript { param($c) "$($c.Label)" }
              if ($targetCal) {
                $selectedGroup.CalendarIds = @($selectedGroup.CalendarIds) + $targetCal.Id
                Save-Config -ConfigPath $ConfigPath -ConfigData $cfg
              }
            }
            "2" {
              Write-Header "Unlink Calendar"
              $targetCal = Select-FromList -Prompt "`nSelect calendar to unlink" -Items $linked -DisplayScript { param($c) "$($c.Label)" }
              if ($targetCal) {
                $selectedGroup.CalendarIds = @($selectedGroup.CalendarIds | Where-Object { $_ -ne $targetCal.Id })
                Save-Config -ConfigPath $ConfigPath -ConfigData $cfg
              }
            }
            "X" { return }
          }
        }
        "calendar" {
          $selectedCal = $cfg.Calendars | Where-Object { $_.Id -eq $Calendar.Id }
          if (-not $selectedCal) { return }

          Write-Header "Calendar: $($selectedCal.Label)"
          # Group is linked if its CalendarIds contain this calendar's ID
          $linked = @($cfg.Groups | Where-Object { $_.CalendarIds -contains $selectedCal.Id })

          Write-Host "Linked Groups: "
          if ($linked.Count -eq 0) { Write-Host " (none)" -ForegroundColor DarkGray }
          else { $linked | ForEach-Object { Write-Host "  - $($_.Label) ($($_.Email))" } }
          Write-Host ""

          Write-Host "  [1]  Link Group`n  [2]  Unlink Group`n  [X]  Back"
          $choice = Read-Host "`nSelection"

          switch ($choice.ToUpper()) {
            "1" {
              Write-Header "Link Group"
              $unlinked = @($cfg.Groups | Where-Object { $_.CalendarIds -notcontains $selectedCal.Id })
              if ($unlinked.count -eq 0) {Write-Host "No unlinked groups for this calendar."; Start-Sleep -Seconds 2 }
              $targetGroup = Select-FromList -Prompt "`nSelect group to link" -Items $unlinked -DisplayScript { param($g) "$($g.Label)" }
              if ($targetGroup) {
                $group = $cfg.Groups | Where-Object { $_.Email -eq $targetGroup.Email }
                $group.CalendarIds = @($group.CalendarIds + $selectedCal.Id)
                Save-Config -ConfigPath $ConfigPath -ConfigData $cfg
              }
            }
            "2" {
              Write-Header "Unlink Group"
              $targetGroup = Select-FromList -Prompt "`nSelect group to unlink" -Items $linked -DisplayScript { param($g) "$($g.Label)" }
              if ($targetGroup) {
                $group = $cfg.Groups | Where-Object { $_.Email -eq $targetGroup.Email }
                $group.CalendarIds = @($group.CalendarIds | Where-Object { $_ -ne $selectedCal.Id })
                Save-Config -ConfigPath $ConfigPath -ConfigData $cfg
              }
            }
            "X" { return }

        }
      }
    }
  }
}

function Show-GroupMenu {
  while ($true) {
    $cfg = Read-Config -ConfigPath $ConfigPath
    Write-Header "Manage Groups"

    $groups = @($cfg.Groups)
    if ($groups.Count -eq 0) {
      Write-Host "  (no groups defined)`n" -ForegroundColor DarkGray
    } else {
      Write-Host "Groups:`n" -ForegroundColor Yellow
      $groups | ForEach-Object {
          $cCount = @($_.CalendarIds).Count
          Write-Host "  - $($_.Label) ($($_.Email)) [Linked Calendars: $cCount]"
      }
      Write-Host ""
    }

    Write-Host "  [1]  Add Group`n  [2]  Link/Unlink Calendars`n  [3]  Delete Group`n  [X]  Back"
    $choice = Read-Host "`nSelection"

    switch ($choice.ToUpper()) {
      "1" {
        $email = (Read-Host "Enter Group Email").Trim()
        $label = (Read-Host "Enter Label (e.g. Sales)").Trim()
        if ([string]::IsNullOrWhiteSpace($email) -or [string]::IsNullOrWhiteSpace($label)) {
          Write-Host "You must fill out both fields." -ForegroundColor Yellow
          Start-Sleep -Seconds 2
          continue
        }

        if ($cfg.Groups | Where-Object { $_.Email -eq $email }) {
          Write-Host "A group with that email already exists." -ForegroundColor Yellow
          Start-Sleep -Seconds 2
          continue
        }
        $cfg.Groups += @{ Email = $email; Label = $label; CalendarIds = @() }
        Write-Host "This will create group $label, with email $email. Edit this group to link to calendars."
        Write-Host "Saving group details..."
        Start-Sleep -Seconds 2
        Save-Config -ConfigPath $ConfigPath -ConfigData $cfg
      }
      "2" {
        Write-Header "Select Group to manage"
        $group = Select-FromList -Prompt "Select group" -Items $groups -DisplayScript { param($g) "$($g.Label) ($($g.Email))" }
        if ($group) { Show-LinkCalendarMenu -Group $group -Source "Group"}
      }
      "3" {
        Write-Header "Select Group to Delete"
        $group = Select-FromList -Prompt "Select group" -Items $groups -DisplayScript { param($g) "$($g.Label) ($($g.Email))" }
        if ($group) {
          Write-Host "`nThis will delete '$($group.Label)' from this system. `nAny linked calendars will still remain in the system." -ForegroundColor Yellow
          $confirm = Read-Host "`nEnter 'DELETE' to verify '$($group.Label)' deletion"
          if ($confirm.ToUpper() -eq "DELETE") {
            $cfg.Groups = @($cfg.Groups | Where-Object { $_.Email -ne $group.Email })
            Save-Config -ConfigPath $ConfigPath -ConfigData $cfg -Operation "Group Deletion"
            return
          } else {
            Write-Host "Group Deletion Cancelled." -ForegroundColor Red
            Start-Sleep -Seconds 2
            continue
          }
        }
      }
      "X" { return }
    }
  }
}

# --- MENU: Database State Settings ---
function Show-StateMenu {
  while ($true) {
    $cfg = Read-Config -ConfigPath $ConfigPath
    Write-Header "Calendar Database State Operations"

    # Gets all state files in database
    $stateFiles = @(Get-ChildItem -Path $StateDir -Filter "state-*.json" -ErrorAction SilentlyContinue)
    # If no state files exist - inform user and exit!
    if ($stateFiles.Count -eq 0) {
      Write-Host "No state files in database." -ForegroundColor Yellow
      Start-Sleep -Seconds 2
    }


    Write-Host "  Active Database Subscriptions Registered: $($stateFiles.Count) entries" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [1]  Purge Specific User State"
    Write-Host "  [2]  WIPE Entire Subscription Database (Reset Everything)"
    Write-Host "  [X]  Back"

    $choice = Read-Host "`nSelection"
    switch ($choice.ToUpper()) {
      "1" {
        $filesCleared = 0
        $targetUser = (Read-Host "Enter exact user email").Trim()
        if (-not [string]::IsNullOrWhiteSpace($targetUser)) {
          # Gets records in each state file
          foreach ($file in $stateFiles) {
            $stateObj = Get-Content -Raw -Path $file.FullName | ConvertFrom-JSON
            $fileModified = $false

            # Loops through each calendar id node in the state file
            foreach ($calendarId in $stateObj.PSObject.Properties.Name) {
              $calendarNode = $stateObj.$calendarId
              # Check if the user's email exists as a property in this calendar
              if ($null -ne $calendarNode -and $null -ne $calendarNode.$targetUser) {
                # Target specific property and drop from the object
                $calendarNode.PSObject.Properties.Remove($targetUser)
                $fileModified = $true
              }
            }
            # Only write if we actually altered something.
            if ($fileModified) {
              $stateObj | ConvertTo-Json -Depth 10 | Out-File -FilePath $file.FullName -Force
              $filesCleared++
            }
          }

          if ($filesCleared -gt 0) {
            Write-Host "Cleared records matching '$targetUser' across $filesCleared state profile(s). User preferences may be overwritten next deployment run." -ForegroundColor Green
          } else {
            Write-Host "No records found for '$targetUser'" -ForegroundColor Yellow
          }
          Start-Sleep -Seconds 2
        }
      }
      "2" {
        Write-Host "WARNING: This will delete $($stateFiles.Count) data files. Users preferences may be overwritten next deployment run." -ForegroundColor Red
        $confirm = Read-Host "Enter 'PURGE' to verify master drop sequence"
        if ($confirm -eq "PURGE") {
          $stateFiles | Remove-Item -Force
          Write-Host "State system synchronized to zero." -ForegroundColor Green
          Start-Sleep -Seconds 2
        }
      }
      "X" { return }
    }
  }
}

# --- MAIN LOOP ---
while ($true) {
  $cfg = Read-Config -ConfigPath $ConfigPath
  Write-Header "Main Menu"
  Write-Host "  Calendars Defined:  $(@($cfg.Calendars).Count)"
  Write-Host "  Groups Defined:     $(@($cfg.Groups).Count)"
  Write-Host "  Database Target:    $StateDir" -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  [1]  Manage Calendars"
  Write-Host "  [2]  Manage Groups"
  Write-Host "  [3]  Manage State Database"
  Write-Host "  [Q]  Quit"

  $choice = Read-Host "`nSelection"
  switch ($choice.ToUpper()) {
    "1" { Show-CalendarMenu }
    "2" { Show-GroupMenu }
    "3" { Show-StateMenu }
    "Q" { Clear-Host; Start-Sleep -Seconds 2; break }
  }
}