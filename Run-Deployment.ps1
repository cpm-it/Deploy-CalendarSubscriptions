<#
    .SYNOPSIS
      Headless automated deployment processor called via Task Scheduler.
    .PARAMETER AppTitle

#>
[CmdletBinding()]
param(
  [string]$AppTitle   = "Deploy-CalendarSubscriptions",
  [string]$ConfigName = "config.psd1",
  [string]$StateDir   = "State",
  [int]$GamThreads    = 5,
  [int]$MaxRetries    = 2
)

$ConfigPath = Join-Path $PSScriptRoot $ConfigName
$StateDir   = Join-Path $PSScriptRoot $StateDir

function Write-Log {
    <#
    .SYNOPSIS
    Writes event logs!
    .Parameter Message
    The message you would like to log
    .Parameter EntryType
    The type of event (Information, Warning, Error)
  #>
    param(
        [string]$Message,
        [ValidateSet("Information", "Warning", "Error")]
        $EntryType = "Information"
    )
    $logTimestamp = Get-Date -Format 'o'
    Write-Output "$logTimestamp | [$EntryType] | $Message"

    # Enforce safe local Windows Event Provider Registration check
    if (-not [System.Diagnostics.EventLog]::SourceExists($AppTitle)) {
        try {
            New-EventLog -LogName Application -Source $AppTitle -ErrorAction Stop
        } catch { return } # Fail silently if service account permissions constrain registration
    }
    Write-EventLog -LogName Application -Source $AppTitle -EntryType $EntryType -EventId 1001 -Message $Message -ErrorAction SilentlyContinue
}

try {
    # Bootstrapper Check
    $EngineModulePath = Join-Path $PSScriptRoot "Modules\CalendarEngine.psm1"
    if (-not (Test-Path $EngineModulePath)) { throw "Core Engine Module Missing at: $EngineModulePath" }
    Import-Module $EngineModulePath -Force

    if (-not (Test-Path $ConfigPath)) { throw "Target configuration profile missing at '$ConfigPath'." }
    if (-not (Get-Command "gam" -ErrorAction SilentlyContinue)) { throw "GAM structural execution path boundary not found." }

    # Verify \State exists - creates it if not!
    if (-not (Test-Path $StateDir)) {
      New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }

    # Extract configuration dataset
    $cfg = Read-Config -ConfigPath $ConfigPath
    $groups = @($cfg.Groups)

    if ($groups.Count -eq 0) {
        Write-Log "No group provisioning blocks found inside profiles." -EntryType Warning
        exit 0
    }

    if ($($cfg.Calendars).Count -eq 0) {
      Write-Log "No calendars defined." -EntryType Warning
      exit 0
    }

    $TempCsv = [System.IO.Path]::GetTempFileName()
    $DeltaCsv = [System.IO.Path]::GetTempFileName()

    # Process each configured Group
    foreach ($group in $groups) {
        $linkedCalendars = @($cfg.Calendars | Where-Object { $group.CalendarIds -contains $_.Id })
        if ($linkedCalendars.Count -eq 0) { Write-Log "No calendars linked to $($group.Label)" -EntryType Warning; continue }

        Write-Log "Parsing group boundary: $($group.Label) ($($group.Email)) - $($linkedCalendars.Count) calendar(s)."

        <# ------
          GAM: 'redirect' writes directly to csv, ensuring there's no PS pipe formatting/artifacts to contend with
          'print group-members group ...' and 'recursive types user'
          ensures we grab all users that are members of this group and child groups.
        ------ #>
        $retryCount = 0
        $csvData = @()

        # Gather up corporate dynamic structures via GAM
        while ($csvData.Count -eq 0 -and $retryCount -le $MaxRetries) {
          if ($retryCount -gt 0) {
              Write-Log "Retry $retryCount/$MaxRetries for '$($group.Email)' - waiting 30s..." -EntryType Warning
              Start-Sleep -Seconds 30
          }

          gam redirect csv "$TempCsv" print group-members group "$($group.Email)" recursive types user
          if ($LASTEXITCODE -eq 0) {
              $csvData = @(Import-Csv $TempCsv -ErrorAction SilentlyContinue)
          }
          $retryCount++
        }

        if ($csvData.Count -eq 0) {
          Write-Log "Group context target '$($group.Label)' generated no processing artifacts. Skipping." -EntryType Warning
          continue
        }

        # Load state for this group
        $state = Read-State -StateDir $StateDir -GroupEmail $group.Email

        # Process each Calendar mapped to this Group
        foreach ($calendar in $linkedCalendars) {
            # Execute delta calculation
            $usersToSub = Get-UsersNeedingSubscription -Members $csvData -State $state -CalendarId $calendar.Id

            if ($usersToSub.Count -eq 0) {
                Write-Log "All users up to date for calendar: $($calendar.Label). Skipping provisioning statement."
                continue
            }

            Write-Log "Target delta calculated: Deploying $($calendar.Label) to $($usersToSub.Count) member(s)."

            # Export targeted users to CSV for GAM execution
            $usersToSub | Export-Csv $DeltaCsv -NoTypeInformation

            # Trigger parallel GAM transaction pipeline
            gam config num_threads $GamThreads csv "$DeltaCsv" gam user "~email" add calendar "$($calendar.Id)"

            # Commit updates to JSON state
            $state = Update-SubscriptionState -State $state -CalendarId $calendar.Id -SubscribedUsers $usersToSub
        }
        Save-State -StateDir $StateDir -GroupEmail $group.Email -State $state
    }
    Write-Log "Deployment cycle executed successfully."
}
catch {
    Write-Log "CRITICAL RUNNER ERROR: $($_.Exception.Message)" -EntryType Error
    exit 1
}
finally {
    # Absolute environmental teardown cleanup safety guarantee
    foreach ($file in @($TempCsv, $DeltaCsv)) {
        if ($file -and (Test-Path $file)) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}
