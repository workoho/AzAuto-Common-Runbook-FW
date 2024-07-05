<#PSScriptInfo
.VERSION 1.1.1
.GUID ac0280b2-7ee2-46bf-8a32-c1277189fb60
.AUTHOR Julian Pawlowski
.COMPANYNAME Workoho GmbH
.COPYRIGHT © 2024 Workoho GmbH
.TAGS
.LICENSEURI https://github.com/workoho/AzAuto-Common-Runbook-FW/LICENSE.txt
.PROJECTURI https://github.com/workoho/AzAuto-Common-Runbook-FW
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
    Version 1.1.1 (2024-07-05)
    - Fix version conversion in Compare method
#>

<#
.SYNOPSIS
    Sets up and updates an Azure Automation Runbook.

.DESCRIPTION
    This script is used to set up and update an Azure Automation Runbook. It takes various parameters to control the behavior of the script, such as the name of the runbook, whether to update and publish the runbook, discard draft runbook, etc.

    New runbooks will be published immediately.

    Existing runbooks will only be published immediately if the switch 'UpdateAndPublishRunbook' is specified.
    Otherwise, existing runbooks will be published as draft runbooks for further testing.

    After testing, the switch 'PublishDraftRunbook' can be used to publish the draft runbooks.
    Note that in this case, no upload or update will be performed.

.PARAMETER RunbookName
    The name of the runbook to be uploaded and updated. If not specified, all runbooks will be processed.

.PARAMETER UpdateAndPublishRunbook
    Update and publish the runbook in Azure Automation Account.

.PARAMETER PublishDraftRunbook
    Publish the draft runbook in Azure Automation Account. This switch is only effective if the switch 'DiscardDraftRunbook' is not specified.
    When switch 'UpdateAndPublishRunbook' is specified and a runbook is not in 'Edit' state, the runbook will be updated and published immediately only when the switch 'Force' is specified.

.PARAMETER DiscardDraftRunbook
    Discard the draft runbook in Azure Automation Account.

.PARAMETER AllowPreReleaseRunbooks
    Allow publication of runbooks with a pre-release version.

.PARAMETER AllowUntrackedRunbooks
    Allow publication of runbooks whose changes are not tracked in a Git repository.

.PARAMETER Force
    Force the operation.
    For example, when the switch 'PublishDraftRunbook' is specified and a runbook is not in 'Edit' state, and the 'UpdateAndPublishRunbook' switch is also specified, the runbook will be updated and published immediately.
    For runbooks that are already up-to-date, a draft version is uploaded without publishing it, unless 'UpdateAndPublishRunbook' is specified.

.EXAMPLE
    Set-AzAutomationRunbook -RunbookName "MyRunbook" -UpdateAndPublishRunbook

    This example sets up and updates an Azure Automation Runbook named "MyRunbook" and publishes it.
#>

#Requires -Module @{ ModuleName='Az.Accounts'; ModuleVersion='3.0.0' }
#Requires -Module @{ ModuleName='Az.Resources'; ModuleVersion='6.16.0' }
#Requires -Module @{ ModuleName='Az.Automation'; ModuleVersion='1.10.0' }

[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'High'
)]
Param (
    [array]$RunbookName,
    [switch]$UpdateAndPublishRunbook,
    [switch]$PublishDraftRunbook,
    [switch]$DiscardDraftRunbook,
    [switch]$AllowPreReleaseRunbooks,
    [switch]$AllowUntrackedRunbooks,
    [switch]$Force
)

if ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
    Write-Error 'This script must be run interactively by a privileged administrator account.' -ErrorAction Stop
    exit
}
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$commonParameters = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
$commonBoundParameters = @{}; $PSBoundParameters.Keys | Where-Object { $_ -in $commonParameters } | ForEach-Object { $commonBoundParameters[$_] = $PSBoundParameters[$_] }

Write-Host "`n`nRunbook Upload and Update`n=========================`n" -ForegroundColor White

#region Read Project Configuration
$config = $null
$configScriptPath = Join-Path (Get-Item $PSScriptRoot).Parent.Parent.FullName (Join-Path 'scripts' (Join-Path 'AzAutoFWProject' 'Get-AzAutoFWConfig.ps1'))
if (
    (Test-Path $configScriptPath -PathType Leaf) -and
    (
        ((Get-Item $configScriptPath).LinkType -ne "SymbolicLink") -or
        (
            Test-Path -LiteralPath (
                Resolve-Path -Path (
                    Join-Path -Path (Split-Path $configScriptPath) -ChildPath (
                        Get-Item -LiteralPath $configScriptPath | Select-Object -ExpandProperty Target
                    )
                )
            ) -PathType Leaf
        )
    )
) {
    if ($commonBoundParameters) {
        $config = & $configScriptPath @commonBoundParameters
    }
    else {
        $config = & $configScriptPath
    }
}
else {
    Write-Error 'Project configuration incomplete: Run ./scripts/Update-AzAutoFWProject.ps1 first.' -ErrorAction Stop
    exit
}

@(
    'AutomationRunbook'
) | & {
    process {
        if ($null -eq $config.$_) {
            Write-Error "Mandatory property '/PrivateData/$_' is missing or null in the AzAutoFWProject.psd1 configuration file." -ErrorAction Stop
            exit
        }
    }
}
@(
    'DefaultRuntimeEnvironment'
    'Runbooks'
) | & {
    process {
        if ($null -eq $config.AutomationRunbook.$_) {
            Write-Error "Mandatory property '/PrivateData/AutomationRunbook/$_' is missing or null in the AzAutoFWProject.psd1 configuration file." -ErrorAction Stop
            exit
        }
    }
}

$SubscriptionScope = "/subscriptions/$($config.local.AutomationAccount.SubscriptionId)"
$RgScope = "$SubscriptionScope/resourcegroups/$($config.local.AutomationAccount.ResourceGroupName)"
$SelfScope = "$RgScope/providers/Microsoft.Automation/automationAccounts/$($config.local.AutomationAccount.Name)"
#endregion

#region Connect to Azure
$automationAccount = $null
try {
    Push-Location
    Set-Location $PSScriptRoot
    if ($commonBoundParameters) {
        $automationAccount = .\Set-AzAutomationAccount.ps1 @commonBoundParameters
    }
    else {
        $automationAccount = .\Set-AzAutomationAccount.ps1
    }
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Stop
    exit
}
finally {
    Pop-Location
}
#endregion

#region Confirm Azure Role Assignments
try {
    Push-Location
    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
    $confirmParams = @{
        Roles = @{
            $SelfScope = 'Reader'
        }
    }
    if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
    $null = ./Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams
}
catch {
    Write-Error "Insufficent Azure permissions: At least 'Reader' role for the Automation Account is required to validate automation runbooks." -ErrorAction Stop
    $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
    exit
}
finally {
    Pop-Location
}
#endregion

#region Functions
class AACRFSemanticVersion {
    <#
    .SYNOPSIS
        Represents a Semantic Version (SemVer).

    .LINK
        https://gist.github.com/jpawlowski/1c81fff8a55f5e368d831e60e235893c
    #>
    [int]$Major
    [int]$Minor
    [int]$Patch
    [System.Collections.ArrayList]$PreReleaseLabel
    [System.Collections.ArrayList]$BuildLabel
    [hashtable]$PreReleaseLabelDict
    [hashtable]$BuildLabelDict

    <#
    .SYNOPSIS
        Creates a new instance of the AACRFSemanticVersion class.
    #>
    AACRFSemanticVersion([int]$Major, [int]$Minor, [int]$Patch, $PreReleaseLabel, $BuildLabel, [bool]$CreateDict = $false) {
        $this.Major = $Major
        $this.Minor = $Minor
        $this.Patch = $Patch

        $this.PreReleaseLabel = New-Object System.Collections.ArrayList
        $this.ProcessLabel($PreReleaseLabel, $this.PreReleaseLabel)

        $this.BuildLabel = New-Object System.Collections.ArrayList
        $this.ProcessLabel($BuildLabel, $this.BuildLabel)

        if ($CreateDict) {
            $date = New-Object DateTime
            $this.PreReleaseLabelDict = $this.CreateLabelDict($this.PreReleaseLabel, $date)
            $this.BuildLabelDict = $this.CreateLabelDict($this.BuildLabel, $date)
        }
    }

    hidden [void] ProcessLabel($label, [System.Collections.ArrayList]$labelList) {
        if ($label -is [array]) {
            foreach ($item in $label) {
                if ($item -is [string]) {
                    $this.ProcessItem($item, $labelList)
                }
                else {
                    throw "Invalid label value of type: $($item.GetType().FullName)"
                }
            }
        }
        elseif ($label -is [string]) {
            $this.ProcessItem($label, $labelList)
        }
        else {
            throw "Invalid label value of type: $($label.GetType().FullName)"
        }
    }

    hidden [void] ProcessItem([string]$item, [System.Collections.ArrayList]$labelList) {
        $splitResult = $item.Split('.')
        foreach ($item in $splitResult) {
            [void]$labelList.Add($item)
        }
    }

    hidden [hashtable] CreateLabelDict([System.Collections.ArrayList]$labelList, [DateTime]$date) {
        $dict = @{}
        if ($labelList.Count % 2 -eq 0) {
            for ($i = 0; $i -lt $labelList.Count; $i += 2) {
                if ($labelList[$i + 1] -match '^\d+$') {
                    [void]$labelList.Add([int]$labelList[$i + 1])
                }
                elseif ($labelList[$i + 1] -eq 'true' -or $labelList[$i + 1] -eq 'false') {
                    [void]$labelList.Add([bool]::Parse($labelList[$i + 1]))
                }
                elseif ([DateTime]::TryParse($labelList[$i + 1], [ref]$date)) {
                    $dict[$labelList[$i]] = $date
                }
                else {
                    $dict[$labelList[$i]] = $labelList[$i + 1]
                }
            }
        }
        return $dict
    }

    <#
    .SYNOPSIS
        Converts the pre-release label to a string.
    #>
    [string] PreReleaseLabelToString() {
        if ($this.PreReleaseLabel) {
            return "-$($this.PreReleaseLabel -join '.')"
        }
        else { return '' }
    }

    <#
    .SYNOPSIS
        Converts the build label to a string.
    #>
    [string] BuildLabelToString() {
        if ($this.BuildLabel) {
            return "+($this.BuildLabel -join '.')"
        }
        else { return '' }
    }

    <#
    .SYNOPSIS
        Converts the AACRFSemanticVersion object to a semantic version compatible string.
    #>
    [string] ToString() {
        $preRelease = $this.PreReleaseLabelToString()
        $build = $this.BuildLabelToString()
        return "$($this.Major).$($this.Minor).$($this.Patch)$preRelease$build"
    }

    <#
    .SYNOPSIS
        Parses a Semantic Version (SemVer) string.

    .DESCRIPTION
        This function parses a version string and returns a AACRFSemanticVersion object.
        The version string could be in the format 'Major.Minor.Patch-PreReleaseLabel+BuildLabel' or 'Major.Minor.Patch.Revision' or a mix of it.
        Some common prefixes like 'v' or '<SHA265> refs/tags/v' or 'Version:' are automatically removed.

    .PARAMETER versionString
        The version string to parse.

    .PARAMETER asString
        If specified, the function returns the version as a string.

    .PARAMETER createDict
        If specified, the function creates a dictionary for the pre-release and build labels.
    #>
    static [object] Parse([string]$versionString, [bool]$asString = $false, [bool]$createDict = $false) {
        if ($null -ne $Matches) { $Matches.Clear() }
        $null = $versionString -match '^(?:.*refs\/tags\/v|.*Version *:? *|v)?(?<Major>\d+)(?:(?:\.(?<Minor>\d+))?(?:(?:\.(?<Patch>\d+))?(?:\.(?<Revision>\d+))?)?)?(?:-(?<PreReleaseLabel>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+(?<BuildLabel>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
        if ($Matches.Count -eq 0) {
            Write-Error "Invalid version string: $versionString" -ErrorAction Stop
        }
        $lMajor = [int]$Matches['Major']
        $lMinor = if ($null -ne $Matches['Minor']) { [int]$Matches['Minor'] } else { 0 }
        $lPatch = if ($null -ne $Matches['Patch']) { [int]$Matches['Patch'] } else { 0 }
        $lRevision = if ($null -ne $Matches['Revision']) { [int]$Matches['Revision'] }
        $lPreReleaseLabel = if ($null -ne $Matches['PreReleaseLabel']) { $Matches['PreReleaseLabel'] } else { '' }
        $lBuildLabel = if ($null -ne $Matches['BuildLabel']) { $Matches['BuildLabel'] } else { '' }

        if ($null -ne $lRevision -and $lBuildLabel -notmatch '^Rev(?:ision)?\.\d+') {
            $lBuildLabel = "Rev.$lRevision$lBuildLabel"
        }

        if ($asString) {
            return "$lMajor.$lMinor.$lPatch$(if ($lPreReleaseLabel) { "-$lPreReleaseLabel" })$(if ($lBuildLabel) { "+$lBuildLabel" })"
        }
        else {
            return [AACRFSemanticVersion]::new($lMajor, $lMinor, $lPatch, $lPreReleaseLabel, $lBuildLabel, $createDict)
        }
    }

    <#
    .SYNOPSIS
        Compares two version strings. Returns a negative number if $v1 is less than $v2, zero if $v1 is equal to $v2, or a positive number if $v1 is greater than $v2.
        Can be used in the [Array]::Sort method as a custom comparer.

    .DESCRIPTION
        This function compares two SemVer version strings and returns:
        - a negative number if $v1 is less than $v2
        - zero if $v1 is equal to $v2
        - a positive number if $v1 is greater than $v2
        In other words, if the function returns a positive number, $v1 is the newer version.
    #>
    static [int] Compare($v1, $v2) {
        $semVer1 = $null
        $semVer2 = $null

        try {
            # Convert the version strings to AACRFSemanticVersion objects
            $semVer1 = if ($v1 -is [AACRFSemanticVersion]) { $v1 } elseif ($v1 -is [string]) { [AACRFSemanticVersion]::Parse($v1, $false, $false) } elseif ($v1 -is [System.Version]) { [AACRFSemanticVersion]::Parse($v1.ToString(), $false, $false) } else { Write-Error "Invalid type for version 1: $($v1.GetType().FullName)" -ErrorAction Stop }
            $semVer2 = if ($v2 -is [AACRFSemanticVersion]) { $v2 } elseif ($v2 -is [string]) { [AACRFSemanticVersion]::Parse($v2, $false, $false) } elseif ($v2 -is [System.Version]) { [AACRFSemanticVersion]::Parse($v2.ToString(), $false, $false) } else { Write-Error "Invalid type for version 2: $($v2.GetType().FullName)" -ErrorAction Stop }
        }
        catch {
            Write-Error $_.Exception.Message -ErrorAction Stop
        }

        # Compare the major, minor, and patch versions
        foreach ($part in 'Major', 'Minor', 'Patch') {
            if ($semVer1.$part -ne $semVer2.$part) {
                return $semVer1.$part - $semVer2.$part
            }
        }

        # Compare the revision if it exists
        if ($semVer1.BuildLabel -and $semVer2.BuildLabel) {
            $revision1 = if ($semVer1.BuildLabel -match '^Rev(?:ision)?\.(\d+)') { [int]$matches[1] } else { $null }
            $revision2 = if ($semVer2.BuildLabel -match '^Rev(?:ision)?\.(\d+)') { [int]$matches[1] } else { $null }
            if ($null -ne $revision1 -and $null -ne $revision2) {
                if ($revision1 -ne $revision2) {
                    return $revision1 - $revision2
                }
            }
        }

        # If one version has a pre-release tag and the other doesn't, the one without is greater
        if ($semVer1.PreReleaseLabel -and !$semVer2.PreReleaseLabel) { return -1 }
        if (!$semVer1.PreReleaseLabel -and $semVer2.PreReleaseLabel) { return 1 }

        # If both versions have pre-release tags, compare them
        if ($semVer1.PreReleaseLabel -and $semVer2.PreReleaseLabel) {
            # Compare each part of the pre-release tag
            for ($i = 0; $i -lt [Math]::Max($semVer1.PreReleaseLabel.Count, $semVer2.PreReleaseLabel.Count); $i++) {
                # If one pre-release tag is shorter and all previous parts are equal, it is smaller
                if ($i -ge $semVer1.PreReleaseLabel.Count) { return -1 }
                if ($i -ge $semVer2.PreReleaseLabel.Count) { return 1 }

                # If both parts are numeric, compare them numerically
                if ($semVer1.PreReleaseLabel[$i] -match '^\d+$' -and $semVer2.PreReleaseLabel[$i] -match '^\d+$') {
                    if ([int]$semVer1.PreReleaseLabel[$i] -ne [int]$semVer2.PreReleaseLabel[$i]) {
                        return [int]$semVer1.PreReleaseLabel[$i] - [int]$semVer2.PreReleaseLabel[$i]
                    }
                }
                # If one part is numeric and the other isn't, the numeric one is smaller
                elseif ($semVer1.PreReleaseLabel[$i] -match '^\d+$') {
                    return -1
                }
                elseif ($semVer2.PreReleaseLabel[$i] -match '^\d+$') {
                    return 1
                }
                # If both parts are non-numeric, compare them lexicographically
                elseif ($semVer1.PreReleaseLabel[$i] -ne $semVer2.PreReleaseLabel[$i]) {
                    if ($semVer1.PreReleaseLabel[$i] -lt $semVer2.PreReleaseLabel[$i]) { return -1 }
                    if ($semVer1.PreReleaseLabel[$i] -gt $semVer2.PreReleaseLabel[$i]) { return 1 }
                }
            }
        }

        # If all parts are equal, the versions are equal
        return 0
    }

    <#
    .SYNOPSIS
        Sorts an array of version strings.
    #>
    static [string[]] SortVersions([string[]]$versions) {
        # Define a custom comparer
        $comparer = [System.Collections.Generic.Comparer[Object]]::Create({
                param($v1, $v2)
                return [AACRFSemanticVersion]::Compare($v1, $v2)
            })

        # Sort the array using the custom comparer
        try {
            [Array]::Sort($versions, $comparer)
        }
        catch {
            Write-Error "Failed to sort versions: $($_.Exception.Message)" -ErrorAction Stop
        }

        # Output each sorted version
        return $versions
    }
}
#endregion

$AzApiVersion = '2023-05-15-preview'
try {
    Push-Location
    Set-Location (Join-Path $config.Project.Directory 'Runbooks')

    #region Get current status
    $params = @{
        ResourceGroupName    = $automationAccount.ResourceGroupName
        Name                 = $automationAccount.AutomationAccountName
        ResourceProviderName = 'Microsoft.Automation'
        ResourceType         = 'automationAccounts', 'runtimeEnvironments'
        ApiVersion           = $AzApiVersion
    }
    if ($commonBoundParameters) { $params += $commonBoundParameters }
    $runtimeEnvironments = (./Common_0001__Invoke-AzRestMethod.ps1 $params).Content.value

    if (-Not $runtimeEnvironments) {
        Write-Error "No runtime environments found in $($automationAccount.AutomationAccountName)." -ErrorAction Stop
        exit
    }

    $params = @{
        ResourceGroupName    = $automationAccount.ResourceGroupName
        Name                 = $automationAccount.AutomationAccountName
        ResourceProviderName = 'Microsoft.Automation'
        ResourceType         = 'automationAccounts', 'runbooks'
        ApiVersion           = $AzApiVersion
    }
    if ($commonBoundParameters) { $params += $commonBoundParameters }
    $runbooks = (./Common_0001__Invoke-AzRestMethod.ps1 $params).Content.value
    #endregion

    $ConfirmedAzPermission = $false
    $GUIDs = @{}
    $gitCache = @{}
    $commonFilters = @('Common_*.ps1', 'Common_*.py')
    $otherFilters = @('*.ps1', '*.py')
    ($commonFilters + $otherFilters) | & {
        process {
            $filter = $_
            Get-ChildItem . -File -Filter $filter -Depth 0 -ErrorAction SilentlyContinue | Where-Object {
                # Exclude 'Common_*' files when the filter is not a 'Common_*' filter
                if ($filter -notin $commonFilters -and $_.Name -like 'Common_*') {
                    $false
                }
                else {
                    $true
                }
            } | ForEach-Object {
                if ($RunbookName) {
                    $currentRunbookName = $_.Name
                    $currentRunbookBaseName = $_.BaseName
                    $matchFound = $false
                    $RunbookName | ForEach-Object {
                        if (
                            (Split-Path $_ -Leaf) -eq $currentRunbookName -or
                            (Split-Path $_ -LeafBase) -eq $currentRunbookBaseName
                        ) {
                            $matchFound = $true
                            return
                        }
                    }
                    if (-not $matchFound) {
                        Write-Verbose "Runbook: $($_.Name) - SKIPPED"
                        return
                    }
                }
                Write-Verbose "Runbook: $($_.Name)"
                $runbook = $runbooks | Where-Object Name -eq $_.BaseName

                $script:tags = $null
                $params = @{
                    ResourceGroupName    = $automationAccount.ResourceGroupName
                    Name                 = $automationAccount.AutomationAccountName, $_.BaseName
                    ResourceProviderName = 'Microsoft.Automation'
                    ResourceType         = 'automationAccounts', 'runbooks'
                    ApiVersion           = $AzApiVersion
                    Method               = 'PATCH'
                    Payload              = @{
                        name       = $_.BaseName
                        location   = $automationAccount.Location
                        properties = @{
                            runbookType = if ($_.Extension -eq '.ps1') {
                                Write-Verbose " Runbook type: PowerShell"
                                'PowerShell'
                            }
                            elseif ($_.Extension -eq '.py') {
                                Write-Verbose " Runbook type: Python"
                                'Python'
                            }
                            else {
                                Write-Error "Unsupported runbook type: $($_.Extension)" -ErrorAction Stop
                                return
                            }
                        }
                    }
                }

                $runbookConfig = $config.AutomationRunbook.Runbooks | Where-Object { $_.Name -eq $_.BaseName -or $_.Name -eq $_.Name }
                if ($runbookConfig.Count -gt 1) { Write-Error "Configuration for runbook '$($_.Name)' is ambiguous."; return }

                $params.Payload.properties.runtimeEnvironment = $(
                    if ($runbookConfig.RuntimeEnvironment) {
                        $runtimeEnvironment = $runtimeEnvironments | Where-Object { $_.Name -eq $runbookConfig.RuntimeEnvironment -and $_.properties.runtime.language -eq $params.Payload.properties.runbookType }
                    }
                    else {
                        $runtimeEnvironment = $runtimeEnvironments | Where-Object { $_.Name -eq $config.AutomationRunbook.DefaultRuntimeEnvironment.$($params.Payload.properties.runbookType) -and $_.properties.runtime.language -eq $params.Payload.properties.runbookType }
                    }
                    if ($runtimeEnvironment) {
                        Write-Verbose " Using runtime environment: $($runtimeEnvironment.Name)"
                        $runtimeEnvironment.Name
                    }
                    else {
                        Write-Error "Defined runtime environment for runbook '$($_.Name)' is not available."
                        return
                    }
                )

                $scriptHelp = Get-Help $_.FullName -Full -ErrorAction SilentlyContinue

                # Set description
                $description = $null
                if ($null -ne $scriptHelp.SYNOPSIS -and -not [string]::IsNullOrEmpty($scriptHelp.SYNOPSIS)) {
                    Write-Verbose " Adding description: Using SYNOPSIS from script file."
                    $description = [string]$scriptHelp.SYNOPSIS
                }
                elseif ($null -ne $scriptHelp.DESCRIPTION -and -not [string]::IsNullOrEmpty($scriptHelp.DESCRIPTION)) {
                    Write-Verbose " Adding description: Using DESCRIPTION from script file."
                    $description = $scriptHelp.DESCRIPTION
                }
                elseif ($null -ne $runbookConfig.Description -and $runbookConfig.Description -is [string] -and -not [string]::IsNullOrEmpty($runbookConfig.Description)) {
                    Write-Verbose " Adding description: Using description from configuration file."
                    $description = $runbookConfig.Description
                }
                else {
                    Write-Verbose " Adding description: No description available."
                    $description = 'No description available.'
                }
                if ($description.Length -gt 512) {
                    Write-Verbose " Stripping description to 508 characters with ' ...'"
                    $description = $description.Substring(0, 508) + ' ...'
                }
                $params.Payload.properties.description = $description

                function Set-ScriptTags {
                    param(
                        [Parameter(Mandatory = $true)]
                        $Item,
                        [Parameter(Mandatory = $true)]
                        [hashtable]$Params
                    )

                    $scriptFileInfo = Test-ScriptFileInfo -LiteralPath $Item.FullName -ErrorAction SilentlyContinue

                    if ($null -eq $scriptFileInfo.GUID) {
                        Write-Warning "Runbook '$($Item.Name)' has no GUID defined in PSScriptInfo block."
                    }
                    else {
                        if ($GUIDs.ContainsKey($scriptFileInfo.GUID)) {
                            throw "Duplicate GUID found in runbook files: $($Item.Name) and $($GUIDs[$scriptFileInfo.GUID])."
                        }
                        if (
                            $null -ne $runbook.tags.'Script.Guid' -and
                            $runbook.tags.'Script.Guid' -ne $scriptFileInfo.GUID
                        ) {
                            throw "Runbook '$($_.Name)' has a different Script GUID than the one in Azure Automation. Please assign a unique GUID for each runbook."
                        }
                        $GUIDs.$($scriptFileInfo.GUID) = $Item.Name
                        Write-Verbose "  Using GUID from script file."
                        $tags.'Script.Guid' = $scriptFileInfo.GUID
                    }
                    if ($null -ne $scriptFileInfo.VERSION) {
                        try {
                            if ($null -ne $runbook.tags.'Script.Version') {
                                if (([AACRFSemanticVersion]::Compare($scriptFileInfo.VERSION, $runbook.tags.'Script.Version')) -gt 0) {
                                    Write-Verbose " Local script version is newer than the one in Azure Automation."
                                    $script:updateRequired = $true
                                }
                            }
                            Write-Verbose "  Using VERSION from script file."
                            $tags.'Script.Version' = $scriptFileInfo.VERSION
                        }
                        catch {
                            throw "Invalid VERSION format in runbook file $($Item.Name): " + $_.Exception.Message
                        }
                    }
                    if ($null -ne $scriptFileInfo.AUTHOR) {
                        Write-Verbose "  Using AUTHOR from script file."
                        $tags.'Script.Author' = $scriptFileInfo.AUTHOR
                    }
                    if ($null -ne $scriptFileInfo.COMPANYNAME) {
                        Write-Verbose "  Using COMPANYNAME from script file."
                        $tags.'Script.CompanyName' = $scriptFileInfo.COMPANYNAME
                    }
                    if ($null -ne $scriptFileInfo.COPYRIGHT) {
                        Write-Verbose "  Using COPYRIGHT from script file."
                        $tags.'Script.Copyright' = $scriptFileInfo.COPYRIGHT
                    }
                    if ($null -ne $scriptFileInfo.LICENSEURI) {
                        Write-Verbose "  Using LICENSEURI from script file."
                        $tags.'Script.LicenseUri' = $scriptFileInfo.LICENSEURI
                    }
                    if ($null -ne $scriptFileInfo.PROJECTURI) {
                        Write-Verbose "  Using PROJECTURI from script file."
                        $tags.'Script.ProjectUri' = $scriptFileInfo.PROJECTURI
                    }
                    if ($null -ne $scriptFileInfo.PRIVATEDATA -and $scriptFileInfo.PRIVATEDATA.Count -gt 0) {
                        Write-Verbose "  Using TAGs from script file."
                        $scriptFileInfo.PRIVATEDATA | ForEach-Object {
                            if ($_ -isnot [string] -or $_ -match '^\s*@[({]') { continue }
                            $_ | ConvertFrom-StringData -ErrorAction SilentlyContinue | ForEach-Object {
                                if ([string]::IsNullOrEmpty($_.Values) -or $_.Values -match '^\s*@[({]') { continue }
                                if ($tags.Count -gt 50) { continue }
                                if (@('GUID', 'VERSION', 'AUTHOR', 'COMPANYNAME', 'COPYRIGHT', 'LICENSEURI', 'PROJECTURI', 'ICONURI', 'EXTERNALMODULEDEPENDENCIES', 'REQUIREDSCRIPTS', 'EXTERNALSCRIPTDEPENDENCIES', 'RELEASENOTES') -contains $_.Keys) {
                                    Write-Warning "PrivateData Key '$($_.Keys)' is reserved and cannot be used as Tag in Azure."
                                }
                                elseif ($_.Keys -match '^(Script|Microsoft|Azure|Windows)') {
                                    Write-Warning "PrivateData Key '$($_.Keys)' uses a reserved prefix '$($Matches[1])' and cannot be used as Tag in Azure."
                                }
                                else {
                                    Write-Verbose "  Using PrivateData Key '$($_.Keys)' from script file."
                                    $tags."Script.$($_.Keys)" = if ([string]::IsNullOrEmpty($_.Values)) { '' } else { $_.Values.Trim() }
                                }
                            }
                        }
                    }
                }

                function Set-GitTags {
                    param(
                        [Parameter(Mandatory = $true)]
                        [string]$FilePath,
                        [Parameter(Mandatory = $true)]
                        [hashtable]$Params
                    )

                    $currentDirectory = (Get-Location).Path
                    if ($null -eq $gitCache.Repository -or -not $gitCache.Repository.Contains($currentDirectory)) {
                        $null = git status 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            throw " No Git repository found at $currentDirectory."
                        }
                        if ($null -eq $gitCache.Repository) { $gitCache.Repository = @{} }
                        $gitCache.Repository.$currentDirectory = @{}
                        $gitCache.Repository.$currentDirectory.FileList = git ls-files 2>$null
                        Write-Verbose "  Found Git repository at $currentDirectory."
                    }
                    if ($gitCache.Repository.$currentDirectory.FileList -contains $filePath) {
                        Write-Verbose "  Runbook is tracked in Git repository at $currentDirectory."
                        $buildInfo = $null
                        $gitRoot = (git rev-parse --show-toplevel 2>$null).Trim()
                        $tags.'Git.Repository' = Split-Path -Leaf $gitRoot
                        $remotes = git remote 2>$null
                        if ($remotes -contains 'origin') {
                            $remoteOrigin = git config --get remote.origin.url 2>$null
                        }
                        elseif ($remotes.Count -eq 1) {
                            $remoteOrigin = git config --get remote.$($remotes).url 2>$null
                        }
                        elseif ($remotes.Count -gt 1) {
                            Write-Error "Multiple Git remotes found and none is named 'origin'. Cannot determine the main remote for repository in $gitRoot."
                            $remotes = $null
                        }
                        if ($null -ne $remoteOrigin) {
                            Write-Verbose "  Using remote '$remoteOrigin' for Git tags."
                            $tags.'Git.RepositoryUrl' = $remoteOrigin
                            if ($gitCache.Repository.$currentDirectory.latestRemoteTag) { $latestRemoteTag = $gitCache.Repository.$currentDirectory.latestRemoteTag } else {
                                $latestRemoteTag = (git ls-remote --tags $remoteOrigin 2>$null | Where-Object { $_ -match 'refs/tags/v' } | Select-Object -Last 1) -replace '.*refs/tags/v', ''
                                $gitCache.Repository.$currentDirectory.latestRemoteTag = $latestRemoteTag
                            }
                            Write-Verbose "  Latest remote tag: $latestRemoteTag"
                        }
                        else {
                            if ($PSVersionTable.Platform -eq 'Unix') { $hostname = hostname -f } else { $hostname = hostname }
                            $hFilePath = Split-Path -Parent $currentDirectory
                            $homeDirectory = [Environment]::GetFolderPath('UserProfile')
                            if ($hFilePath.StartsWith($homeDirectory)) { $hFilePath = "~" + $hFilePath.Substring($homeDirectory.Length) }
                            $tags.'Git.RepositoryUrl' = "file://$hostname/$($hFilePath.Replace('\', '/'))"
                            Write-Verbose "  Using only local repository '$($tags.'Git.RepositoryUrl')' for Git tags."
                        }
                        if ($gitCache.Repository.$currentDirectory.latestLocalTag) { $latestLocalTag = $gitCache.Repository.$currentDirectory.latestLocalTag } else {
                            $latestLocalTag = (git tag --list 'v*' 2>$null | Select-Object -Last 1) -replace '^v', ''
                            $gitCache.Repository.$currentDirectory.latestLocalTag = $latestLocalTag
                        }
                        Write-Verbose "  Latest local tag : $latestLocalTag"
                        if (
                            $null -ne $remoteOrigin -and
                            -not [string]::IsNullOrEmpty($latestLocalTag) -and
                            (
                                [string]::IsNullOrEmpty($latestRemoteTag) -or
                                ([AACRFSemanticVersion]::Compare($latestLocalTag, $latestRemoteTag)) -gt 0
                            )
                        ) {
                            throw "Local tag '$latestLocalTag' is not pushed to remote yet."
                        }

                        # Get the full hash of the latest commit that modified the file
                        $latestFileCommitHash = git log -n 1 --pretty=format:%H -- $filePath 2>$null

                        # Check if there is a latest local tag
                        if (-not [string]::IsNullOrEmpty($latestLocalTag)) {
                            # Get the full hash of the latest commit associated with the latest tag
                            $latestTagCommitHashFull = git rev-list -n 1 $latestLocalTag 2>$null

                            # Get a list of all the commits between the latest tag and the head of the repository that modified the file
                            $commitsModifyingFileAfterLatestTag = git log --pretty=format:%H $latestTagCommitHashFull..HEAD -- $filePath 2>$null

                            # Check if the file was changed after the latest tag
                            if ($commitsModifyingFileAfterLatestTag -contains $latestFileCommitHash) {
                                # Append the short hash of the latest commit that modified the file to the base version
                                $latestFileCommitHashShort = $latestFileCommitHash.Substring(0, 7)
                                if ($latestLocalTag -like '*-*') {
                                    $version = "$latestLocalTag.commit.$latestFileCommitHashShort"
                                }
                                else {
                                    $version = "$latestLocalTag-commit.$latestFileCommitHashShort"
                                }
                            }
                            else {
                                # Use the latest tag as the base version
                                $version = $latestLocalTag
                            }
                        }
                        else {
                            # If there is no latest local tag, use the short hash of the latest commit that modified the file as the base version
                            if ([string]::IsNullOrEmpty($tags.'Script.Version')) {
                                $version = "0.0.0-commit.$latestFileCommitHashShort"
                            }
                            else {
                                $version = "$($tags.'Script.Version')+commit.$latestFileCommitHashShort"
                            }
                        }

                        if (-not $gitCache.Repository.$currentDirectory.Contains('Branch')) {
                            try {
                                $tag = git describe --exact-match --tags HEAD 2>$null
                                if ($tag -match '^v.+') {
                                    $gitCache.Repository.$currentDirectory.Branch = $null
                                }
                                else {
                                    throw
                                }
                            }
                            catch {
                                $gitCache.Repository.$currentDirectory.Branch = git rev-parse --abbrev-ref HEAD 2>$null
                            }
                        }
                        if (
                            -not [string]::IsNullOrEmpty($gitCache.Repository.$currentDirectory.Branch) -and
                            $gitCache.Repository.$currentDirectory.Branch -ne 'master' -and
                            $gitCache.Repository.$currentDirectory.Branch -ne 'main'
                        ) {
                            $branches = git branch --contains $latestFileCommitHash 2>$null | ForEach-Object { ($_ -replace '\*|\(.*\)', '').Trim() }
                            $branch = $null
                            if ($branches -contains $gitCache.Repository.$currentDirectory.Branch) {
                                $branch = $gitCache.Repository.$currentDirectory.Branch
                            }
                            elseif ($branches.Count -gt 0 -and $branches -notcontains 'master' -and $branches -notcontains 'main') {
                                if ($branches.Count -gt 1) {
                                    Write-Verbose "  File is associated with multiple pre-release branches: $($branches -join ', '). Using the first one for versioning: $($branches[0])."
                                }
                                $branch = $branches[0]
                            }

                            if ($null -ne $branch) {
                                Write-Verbose "  Adding branch '$branch' to versioning."
                                if ($version -like '*-*') {
                                    $version += ".$branch"
                                }
                                else {
                                    $version += "-$branch"
                                }
                            }
                        }

                        if (-not $gitCache.Repository.$currentDirectory.Contains('DiffList')) {
                            $gitCache.Repository.$currentDirectory.DiffList = git diff --name-only . 2>$null | ForEach-Object { Split-Path -Path $_ -Leaf }
                        }
                        if ($gitCache.Repository.$currentDirectory.DiffList -contains (Split-Path -Path $filePath -Leaf)) {
                            if ($version -like '*-*') {
                                $version += ".modified.$($Item.LastWriteTimeUtc.ToString('yyyyMMddTHHmmssZ'))"
                            }
                            else {
                                $version += "-modified.$($Item.LastWriteTimeUtc.ToString('yyyyMMddTHHmmssZ'))"
                            }
                        }

                        if ($null -ne $runbook.tags.'File.Version') {
                            try {
                                if (([AACRFSemanticVersion]::Compare($version, $runbook.tags.'File.Version')) -gt 0) {
                                    Write-Verbose "  Local Git file version is newer than the one in Azure Automation."
                                    $script:updateRequired = $true
                                }
                                else {
                                    Write-Verbose "  Local Git file version is older or the same as the one in Azure Automation."
                                }
                            }
                            catch {
                                Write-Verbose "  The version information cannot be compared: $($_.Exception.Message)"
                            }
                        }

                        $tags.'File.Version' = $version
                        $tags.'File.Hash' = "SHA256:$((Get-FileHash -Path $filePath -Algorithm SHA256).Hash.ToLower())"
                    }
                    else {
                        throw " Runbook is not tracked in Git repository at $currentDirectory."
                    }
                }

                function Set-LocalFileTags {
                    param(
                        [Parameter(Mandatory = $true)]
                        $Item,
                        [Parameter(Mandatory = $true)]
                        [hashtable]$Params
                    )

                    Write-Verbose "  Runbook is a local file only."
                    if ($PSVersionTable.Platform -eq 'Unix') { $hostname = hostname -f } else { $hostname = hostname }
                    $hFilePath = Split-Path (Split-Path $Item.FullName -Parent) -Parent
                    $homeDirectory = [Environment]::GetFolderPath('UserProfile')
                    if ($hFilePath.StartsWith($homeDirectory)) { $hFilePath = "~" + $hFilePath.Substring($homeDirectory.Length) }
                    $tags.'Git.Repository' = Split-Path -Leaf $hFilePath
                    $tags.'Git.RepositoryUrl' = "file://$hostname/$($hFilePath.Replace('\', '/'))"
                    if ([string]::IsNullOrEmpty($tags.'Script.Version')) {
                        $tags.'File.Version' = "0.0.0-local.$($Item.LastWriteTimeUtc.ToString('yyyyMMddTHHmmssZ'))"
                    }
                    else {
                        $tags.'File.Version' = "$($tags.'Script.Version')+local.$($Item.LastWriteTimeUtc.ToString('yyyyMMddTHHmmssZ'))"
                    }

                    if ($null -ne $runbook.tags.'File.Version') {
                        try {
                            if (([AACRFSemanticVersion]::Compare($tags.'File.Version', $runbook.tags.'File.Version')) -gt 0) {
                                Write-Verbose "  Local file version is newer than the one in Azure Automation."
                                $script:updateRequired = $true
                            }
                            else {
                                Write-Verbose "  Local file version is older or the same as the one in Azure Automation."
                            }
                        }
                        catch {
                            Write-Verbose "  The version information cannot be compared: $($_.Exception.Message)"
                        }
                    }

                    $tags.'File.Hash' = "SHA256:$((Get-FileHash -Path $Item.FullName -Algorithm SHA256).Hash.ToLower())"
                }

                function Set-Tags {
                    param(
                        [Parameter(Mandatory = $true)]
                        $Item,
                        [Parameter(Mandatory = $true)]
                        [hashtable]$Params
                    )

                    # Read tags from configuration file
                    if ($null -ne $runbookConfig.Tags -and $runbookConfig.Tags -is [hashtable]) {
                        Write-Verbose " Azure Tags: Adding tags from configuration file."
                        $script:tags = $runbookConfig.Tags
                    }
                    else { $script:tags = @{} }

                    # Script tags
                    try {
                        Write-Verbose " Azure Tags: Adding script tags."
                        Set-ScriptTags -Item $Item -Params $Params
                    }
                    catch {
                        throw $_.Exception.Message
                    }

                    # Git tags
                    Write-Verbose " Azure Tags: Adding Git tags."
                    try {
                        Set-GitTags -FilePath $Item.Name -Params $Params
                    }
                    catch {
                        Write-Verbose " $($_.Exception.Message)"
                        if ($Item.Attributes -eq 'ReparsePoint') {
                            Write-Verbose '  Symlink detected. Checking symlink target directory.'
                            # Check symlink target directory
                            try {
                                $symlinkTarget = Resolve-Path $Item.Target
                                Push-Location
                                Set-Location -Path (Split-Path -Parent $symlinkTarget) -ErrorAction Stop
                                Set-GitTags -FilePath $Item.Name -Params $Params
                            }
                            catch {
                                Write-Verbose " $($_.Exception.Message)"
                                # The symlink target directory is not a git repository
                                Set-LocalFileTags -Item $Item -Params $Params
                            }
                            finally {
                                Pop-Location
                            }
                        }
                        else {
                            Write-Verbose ' Checking parent project directory.'
                            # Check parent project directory
                            try {
                                Push-Location
                                Set-Location -Path $item.Directory.FullName.Replace($config.Project.Directory, $config.ParentProject.Directory) -ErrorAction Stop
                                Set-GitTags -FilePath $Item.Name -Params $Params
                            }
                            catch {
                                Write-Verbose " $($_.Exception.Message)"
                                # The parent project directory is not a git repository
                                Set-LocalFileTags -Item $Item -Params $Params
                            }
                            finally {
                                Pop-Location
                            }
                        }
                    }

                    Write-Verbose "  Generated FileVersion: $($tags.'File.Version')"

                    if (
                        $script:updateRequired -eq $false -and
                        $null -eq $runbook.tags.'File.Hash' -or
                        $runbook.tags.'File.Hash' -ne $tags.'File.Hash'
                    ) {
                        Write-Verbose " Runbook has a different Git File Hash than the one in Azure Automation: remote '$(if ($runbook.tags.'File.Hash') {$runbook.tags.'File.Hash'} else {''})' vs. local '$($tags.'File.Hash')'"
                        $script:updateRequired = $true
                    }
                }

                try {
                    $script:updateRequired = $false
                    Set-Tags -Item $_ -Params $params
                }
                catch {
                    Write-Error $_.Exception.Message -ErrorAction Stop
                    return
                }

                if ($commonBoundParameters) { $params += $commonBoundParameters }

                $importNewAsPublished = $true

                if (
                    (
                        ($null -eq $runbook -or $UpdateAndPublishRunbook -eq $true) -and
                        $tags.'File.Version' -like '*modified*'
                    ) -or
                    (
                        $PublishDraftRunbook -eq $true -and
                        $null -ne $runbook.tags -and
                        $null -ne $runbook.tags.'Draft.File.Version' -and
                        $runbook.tags.'Draft.File.Version' -like '*modified*'
                    )
                ) {
                    if ($null -eq $runbook) {
                        Write-Warning "Runbook '$($_.Name)' is a locally modified file. It will be imported as a draft."
                        $importNewAsPublished = $false
                    }
                    else {
                        Write-Warning "Runbook '$($_.Name)' is a locally modified file. The changes must be undone or added to the Git repository before publication."
                        Write-Host "    (BLOCKED)        " -NoNewline -ForegroundColor Red
                        Write-Host "$($_.Name) (Draft File Version: $($runbook.tags.'Draft.File.Version')$(if ($null -ne $runbook.tags.'Draft.Script.Version') {", Draft Script Version: $($runbook.tags.'Draft.Script.Version')"}))"
                        return
                    }
                }

                if (
                    (
                        ($null -eq $runbook -or $UpdateAndPublishRunbook -eq $true) -and
                        $tags.'File.Version' -like '*local*'
                    ) -or
                    (
                        $PublishDraftRunbook -eq $true -and
                        $null -ne $runbook.tags -and
                        $null -ne $runbook.tags.'Draft.File.Version' -and
                        $runbook.tags.'Draft.File.Version' -like '*local*'
                    )
                ) {
                    if ($AllowUntrackedRunbooks) {
                        Write-Warning "Runbook '$($_.Name)' is an untracked file. Publication is enforced by the -AllowUntrackedRunbooks parameter."
                    }
                    elseif ($null -eq $runbook) {
                        if ($importNewAsPublished) { Write-Warning "Runbook '$($_.Name)' is an untracked file. It will be imported as a draft. To publish it, either add it to the project repository, or use the -AllowUntrackedRunbooks parameter to override." }
                        $importNewAsPublished = $false
                    }
                    else {
                        Write-Warning "Runbook '$($_.Name)' changes are not tracked by a Git repository. To publish it, either add it to the project repository, or use the -AllowUntrackedRunbooks parameter to override."
                        Write-Host "    (BLOCKED)        " -NoNewline -ForegroundColor Red
                        Write-Host "$($_.Name) (Draft File Version: $($runbook.tags.'Draft.File.Version')$(if ($null -ne $runbook.tags.'Draft.Script.Version') {", Draft Script Version: $($runbook.tags.'Draft.Script.Version')"}))"
                        return
                    }
                }

                if (
                    (
                        ($null -eq $runbook -or $UpdateAndPublishRunbook -eq $true) -and
                        $tags.'File.Version' -like '*-*'
                    ) -or
                    (
                        $PublishDraftRunbook -eq $true -and
                        $null -ne $runbook.tags -and
                        $null -ne $runbook.tags.'Draft.File.Version' -and
                        $runbook.tags.'Draft.File.Version' -like '*-*'
                    )
                ) {
                    if ($AllowPreReleaseRunbooks) {
                        Write-Warning "Runbook '$($_.Name)' is a pre-release version. Publication is enforced by the -AllowPreReleaseRunbooks parameter."
                    }
                    elseif ($null -eq $runbook) {
                        if ($importNewAsPublished) { Write-Warning "Runbook '$($_.Name)' is a pre-release version. It will be imported as a draft. To publish it, either create a release version, or use the -AllowPreReleaseRunbooks parameter to override." }
                        $importNewAsPublished = $false
                    }
                    else {
                        Write-Warning "Runbook '$($_.Name)' as a pre-release version. To publish it, either create a release version, or use the -AllowPreReleaseRunbooks parameter to override."
                        Write-Host "    (BLOCKED)        " -NoNewline -ForegroundColor Red
                        Write-Host "$($_.Name) (Draft File Version: $($runbook.tags.'Draft.File.Version')$(if ($null -ne $runbook.tags.'Draft.Script.Version') {", Draft Script Version: $($runbook.tags.'Draft.Script.Version')"}))"
                        return
                    }
                }

                $thisPublishDraftRunbook = $PublishDraftRunbook
                $thisUpdateAndPublishRunbook = $UpdateAndPublishRunbook

                # Only generate draft tags if the runbook does not exist in Azure Automation and the import is not published
                if (
                    (
                        $null -eq $runbook -and
                        $importNewAsPublished -eq $false
                    ) -or
                    (
                        $null -ne $runbook -and
                        $thisUpdateAndPublishRunbook -eq $false -and
                        $thisPublishDraftRunbook -eq $false -and
                        $DiscardDraftRunbook -eq $false
                    )
                ) {
                    Write-Verbose " Generating draft tags."
                    $updatedTag = $false
                    $newTags = @{}
                    if ($null -ne $runbook.tags) {
                        $runbook.tags.PSObject.Properties | ForEach-Object {
                            $newTags[$_.Name] = $_.Value
                        }
                    }
                    $tags.GetEnumerator() | ForEach-Object {
                        if (@('Script.Version', 'File.Version', 'File.Hash') -contains $_.Key) {
                            Write-Verbose "  Adding draft tag: Draft.$($_.Key) --> $($_.Value)"
                            $newTags["Draft.$($_.Key)"] = $_.Value
                        }
                        elseif ($_.Key -notmatch '^Draft\.(.+)$') {
                            if ($newTags.ContainsKey($_.Key) -and $newTags[$_.Key] -ne $_.Value) {
                                Write-Verbose "  Updating tag: $($_.Key) --> $($_.Value)"
                                $updatedTag = $true
                            }
                            $newTags[$_.Key] = $_.Value
                        }
                    }
                    $tags = $newTags

                    if (
                        -not $Force -and
                        -not $updatedTag -and
                        (
                            $runbook.properties.state -eq 'New' -or
                            $runbook.properties.state -eq 'Edit'
                        ) -and
                        $null -ne $runbook.tags.'Draft.Script.Version' -and
                        $null -ne $runbook.tags.'Draft.File.Version' -and
                        $null -ne $runbook.tags.'Draft.File.Hash' -and
                        $tags.'Draft.Script.Version' -eq $runbook.tags.'Draft.Script.Version' -and
                        $tags.'Draft.File.Version' -eq $runbook.tags.'Draft.File.Version' -and
                        $tags.'Draft.File.Hash' -eq $runbook.tags.'Draft.File.Hash'
                    ) {
                        Write-Verbose " Draft is the same as the one in Azure Automation - SKIPPED"
                        Write-Host "    (Draft)          " -NoNewline -ForegroundColor Yellow
                        Write-Host "$($_.Name) (Draft File Version: $($runbook.tags.'Draft.File.Version')$(if ($null -ne $runbook.tags.'Draft.Script.Version') {", Draft Script Version: $($runbook.tags.'Draft.Script.Version')"}))"
                        return
                    }
                    else {
                        Write-Verbose " Draft requires update."
                    }
                }

                if ($null -eq $runbook) {
                    $importParams = @{
                        ResourceGroupName     = $automationAccount.ResourceGroupName
                        AutomationAccountName = $automationAccount.AutomationAccountName
                        Name                  = $_.BaseName
                        Type                  = $params.Payload.properties.runbookType
                        Path                  = $_.FullName
                        Publish               = $importNewAsPublished
                        Description           = $params.Payload.properties.description
                        Tags                  = $tags
                    }
                    if ($commonBoundParameters) { $importParams += $commonBoundParameters }
                    $importParams.Confirm = $false

                    if ($importNewAsPublished -eq $false -or $PSCmdlet.ShouldProcess(
                            "Import and publish new runbook '$($importParams.Name)' file version $($tags.'File.Version') to '$($automationAccount.AutomationAccountName)' for PRODUCTION USE",
                            "Do you confirm to import and publish new runbook '$($importParams.Name)' file version $($tags.'File.Version') to '$($automationAccount.AutomationAccountName)' for PRODUCTION USE ?",
                            'Import and publish new runbook to Azure Automation Account for PRODUCTION USE'
                        )) {

                        #region Confirm Azure Role Assignments
                        try {
                            Push-Location
                            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                            $confirmParams = @{
                                Roles = @{
                                    $SelfScope = 'Automation Contributor'
                                }
                            }
                            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                            if (-not $ConfirmedAzPermission) { $null = ./Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams; $ConfirmedAzPermission = $true }
                        }
                        catch {
                            Write-Error "Insufficent Azure permissions: At least 'Automation Contributor' role for the Automation Account is required to setup automation runbooks." -ErrorAction Stop
                            $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                        #endregion

                        if ($importNewAsPublished) {
                            Write-Host "    (Publish)        " -NoNewline -ForegroundColor White
                            Write-Host "$($_.Name) (File Version: $($tags.'File.Version')$(if ($null -ne $tags.'Script.Version') {", Script Version: $($tags.'Script.Version')"}))"
                        }
                        else {
                            Write-Host "    (Missing)        " -NoNewline -ForegroundColor White
                            Write-Host "$($_.Name) (Draft File Version: $($tags.'Draft.File.Version')$(if ($null -ne $tags.'Draft.Script.Version') {", Draft Script Version: $($tags.'Draft.Script.Version')"}))"
                        }

                        try {
                            $runbook = Import-AzAutomationRunbook @importParams
                            # Basically to set the runtimeEnvironment as Import-AzAutomationRunbook does not support it yet
                            $null = ./Common_0001__Invoke-AzRestMethod.ps1 $params
                            if ($importNewAsPublished) {
                                Write-Host "    (Published)      " -NoNewline -ForegroundColor Green
                                Write-Host "$($_.Name) (File Version: $($tags.'File.Version')$(if ($null -ne $tags.'Script.Version') {", Script Version: $($tags.'Script.Version')"}))"
                            }
                            else {
                                Write-Host "    (Draft)          " -NoNewline -ForegroundColor Yellow
                                Write-Host "$($_.Name) (Draft File Version: $($tags.'Draft.File.Version')$(if ($null -ne $tags.'Draft.Script.Version') {", Draft Script Version: $($tags.'Draft.Script.Version')"}))"
                            }
                        }
                        catch {
                            Write-Error "Failed to import runbook '$($_.Name)' to Azure Automation: $($_.Exception.Message)" -ErrorAction Stop
                            return
                        }
                    }
                    else {
                        Write-Host "    (Skip)           " -NoNewline -ForegroundColor White
                        Write-Host "$($_.Name) (File Version: $($tags.'File.Version')$(if ($null -ne $tags.'Script.Version') {", Script Version: $($tags.'Script.Version')"}))"
                    }
                }
                else {
                    if ($script:updateRequired -eq $false) {
                        if ($Force) {
                            Write-Verbose " Forcing update."
                        }
                        else {
                            Write-Host "    (Published)      " -NoNewline -ForegroundColor Green
                            Write-Host "$($_.Name) (File Version: $($runbook.tags.'File.Version')$(if ($null -ne $runbook.tags.'Script.Version') {", Script Version: $($runbook.tags.'Script.Version')"}))"
                            return
                        }
                    }

                    if ($DiscardDraftRunbook -eq $true) {
                        if ($runbook.properties.state -ne 'New' -and $runbook.properties.state -ne 'Edit') {
                            Write-Verbose " Not in New/Edit state in Azure Automation - SKIPPED"
                            return
                        }
                        else {
                            Write-Verbose " Removing draft tags from existing runbook."
                            if ($null -eq $runbook.tags -or $runbook.tags.Count -eq 0) {
                                $tags = @{}
                            }
                            else {
                                $newTags = @{}
                                $runbook.tags.PSObject.Properties | ForEach-Object {
                                    if ($_.Name -notmatch '^Draft\.(.+)$') {
                                        Write-Verbose "  Keeping tag: $($_.Name)"
                                        $newTags[$_.Name] = $_.Value
                                    }
                                    else {
                                        Write-Verbose "  Removing draft tag: $($_.Name)"
                                    }
                                }
                                $tags = $newTags
                            }
                        }
                        $thisPublishDraftRunbook = $false
                        $thisUpdateAndPublishRunbook = $false
                    }
                    elseif ($thisPublishDraftRunbook -eq $true) {
                        if ($runbook.properties.state -ne 'New' -and $runbook.properties.state -ne 'Edit') {
                            if ($thisUpdateAndPublishRunbook -eq $false -or -not $Force) {
                                Write-Verbose " Not in New/Edit state in Azure Automation - SKIPPED"
                                return
                            }
                            Write-Warning "Runbook '$($_.Name)' is not in New/Edit state. Enforcing update and publish."
                            $thisPublishDraftRunbook = $false
                        }
                        elseif (
                            $null -eq $runbook.tags -or
                            $runbook.tags.Count -eq 0 -or
                            $null -eq $runbook.tags.'Draft.File.Version' -or
                            $null -eq $runbook.tags.'Draft.File.Hash'
                        ) {
                            Write-Warning "Missing or incomplete draft tags for runbook '$($_.Name)' in Azure Automation: Uploading new draft for testing first."
                            $thisPublishDraftRunbook = $false
                            $thisUpdateAndPublishRunbook = $false
                        }
                        else {
                            Write-Verbose " Refactoring existing runbook draft tags for publishing."
                            $newTags = @{}
                            $runbook.tags.PSObject.Properties | ForEach-Object {
                                if ($_.Name -match '^Draft\.(.+)$') {
                                    Write-Verbose "  Renaming draft tag: $($_.Name) --> $($Matches[1])"
                                    $newTags[$Matches[1]] = $_.Value
                                }
                                elseif (@('Script.Version', 'File.Version', 'File.Hash') -contains $_.Name) {
                                    Write-Verbose "  Ignoring old tag: $($_.Name)"
                                }
                                else {
                                    Write-Verbose "  Keeping tag: $($_.Name)"
                                    $newTags[$_.Name] = $_.Value
                                }
                            }
                            $tags = $newTags
                        }
                    }

                    if ($tags.Count -gt 15) {
                        Write-Error "Runbook '$($_.Name)' has more than 15 tags. Azure Automation supports a maximum of 15 tags per resource."
                        return
                    }

                    if ($thisUpdateAndPublishRunbook -eq $true) {
                        if ($PSCmdlet.ShouldProcess(
                                "UPDATE/UPDATE and publish runbook '$($_.Name)' file version $($tags.'File.Version') in '$($automationAccount.AutomationAccountName)' for PRODUCTION USE",
                                "Do you confirm to UPLOAD/UPDATE runbook '$($_.Name)' file version $($tags.'File.Version') in '$($automationAccount.AutomationAccountName)' and publish for PRODUCTION USE ?",
                                'UPLOAD/UPDATE and publish runbook in Azure Automation Account for PRODUCTION USE'
                            )) {
                            Write-Host "    (Update+Publish) " -NoNewline -ForegroundColor Green
                            Write-Host "$($_.Name) (File Version: $($tags.'File.Version')$(if ($null -ne $tags.'Script.Version') {", Script Version: $($tags.'Script.Version')"}))"
                        }
                        else {
                            Write-Host "    (Skip)           " -NoNewline -ForegroundColor White
                            Write-Host "$($_.Name) (File Version: $($runbook.tags.'File.Version')$(if ($null -ne $runbook.tags.'Script.Version') {", Script Version: $($runbook.tags.'Script.Version')"}))"
                            return
                        }
                    }
                    elseif ($thisPublishDraftRunbook -eq $true) {
                        if ($PSCmdlet.ShouldProcess(
                                "Publish existing draft runbook '$($_.Name)' file version $($tags.'File.Version') in '$($automationAccount.AutomationAccountName)' for PRODUCTION USE",
                                "Do you confirm to publish existing draft runbook '$($_.Name)' file version $($tags.'File.Version') '$($automationAccount.AutomationAccountName)' for PRODUCTION USE ?",
                                'Publish existing draft runbook in Azure Automation Account for PRODUCTION USE'
                            )) {
                            Write-Host "    (Publish)        " -NoNewline -ForegroundColor Green
                            Write-Host "$($_.Name) (File Version: $($tags.'File.Version')$(if ($null -ne $tags.'Script.Version') {", Script Version: $($tags.'Script.Version')"}))"
                        }
                        else {
                            Write-Host "    (Skip)           " -NoNewline -ForegroundColor White
                            Write-Host "$($_.Name) (File Version: $($runbook.tags.'File.Version')$(if ($null -ne $runbook.tags.'Script.Version') {", Script Version: $($runbook.tags.'Script.Version')"}))"
                            return
                        }
                    }
                    elseif ($DiscardDraftRunbook -eq $true) {
                        if ($runbook.properties.state -eq 'New') {
                            Write-Host "    (Remove)         " -NoNewline -ForegroundColor DarkGreen
                            Write-Host "$($_.Name) (Draft File Version: $($runbook.tags.'Draft.File.Version')$(if ($null -ne $runbook.tags.'Draft.Script.Version') {", Draft Script Version: $($runbook.tags.'Draft.Script.Version')"}))"
                        }
                        else {
                            Write-Host "    (Revert)         " -NoNewline -ForegroundColor DarkGreen
                            Write-Host "$($_.Name) (File Version: $($runbook.tags.'File.Version')$(if ($null -ne $runbook.tags.'Script.Version') {", Script Version: $($runbook.tags.'Script.Version')"}))"
                        }
                    }
                    else {
                        Write-Host "    (Draft)          " -NoNewline -ForegroundColor Yellow
                        Write-Host "$($_.Name) (Draft File Version: $($tags.'Draft.File.Version')$(if ($null -ne $tags.'Draft.Script.Version') {", Draft Script Version: $($tags.'Draft.Script.Version')"}))"
                    }

                    #region Confirm Azure Role Assignments
                    try {
                        Push-Location
                        Set-Location (Join-Path $config.Project.Directory 'Runbooks')
                        $confirmParams = @{
                            Roles = @{
                                $SelfScope = 'Automation Contributor'
                            }
                        }
                        if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
                        if (-not $ConfirmedAzPermission) { $null = ./Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams; $ConfirmedAzPermission = $true }
                    }
                    catch {
                        Write-Error "Insufficent Azure permissions: At least 'Automation Contributor' role for the Automation Account is required to setup automation runbooks." -ErrorAction Stop
                        $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
                        exit
                    }
                    finally {
                        Pop-Location
                    }
                    #endregion

                    try {
                        if ($DiscardDraftRunbook) {
                            if ($runbook.properties.state -eq 'New') {
                                Write-Verbose "(Remove) $($_.Name) - Removing unpublished draft runbook from Azure Automation"
                                $null = Remove-AzAutomationRunbook -Name $_.BaseName -ResourceGroupName $automationAccount.ResourceGroupName -AutomationAccountName $automationAccount.AutomationAccountName -Force -Confirm:$false @commonBoundParameters
                                return
                            }

                            Write-Verbose "(Revert) $($_.Name) - Discarding draft and removing draft tags from published runbook"
                            $undoParams = @{
                                ResourceGroupName    = $automationAccount.ResourceGroupName
                                Name                 = $automationAccount.AutomationAccountName, $_.BaseName, 'undoEdit'
                                ResourceProviderName = 'Microsoft.Automation'
                                ResourceType         = 'automationAccounts', 'runbooks', 'draft'
                                ApiVersion           = $AzApiVersion
                                Method               = 'POST'
                            }
                            if ($commonBoundParameters) { $undoParams += $commonBoundParameters }
                            $null = ./Common_0001__Invoke-AzRestMethod.ps1 $undoParams

                            Write-Verbose "(Update) $($_.Name) - Updating Azure Tags"
                            $null = Set-AzAutomationRunbook -Tag $tags @params
                            return
                        }
                        elseif ($thisPublishDraftRunbook -eq $true) {
                            Write-Verbose "(Publish) $($_.Name) - Publish current draft as production version"
                            $publishParams = @{
                                ResourceGroupName     = $automationAccount.ResourceGroupName
                                AutomationAccountName = $automationAccount.AutomationAccountName
                                Name                  = $_.BaseName
                            }
                            if ($commonBoundParameters) { $publishParams += $commonBoundParameters }
                            $publishParams.ErrorAction = 'Stop'
                            $null = Publish-AzAutomationRunbook @publishParams

                            Write-Verbose "(Update) $($_.Name) - Updating Azure Tags"
                            $null = Set-AzAutomationRunbook -Tag $tags @publishParams
                        }
                        else {
                            Write-Verbose "(Update) $($_.Name) - Runbook content $(if($thisUpdateAndPublishRunbook) {'and publish'} else {'as draft'})"

                            try {
                                $importParams = @{
                                    ResourceGroupName     = $automationAccount.ResourceGroupName
                                    AutomationAccountName = $automationAccount.AutomationAccountName
                                    Name                  = $_.BaseName
                                    Type                  = $params.Payload.properties.runbookType
                                    Path                  = $_.FullName
                                    Force                 = $true
                                    Publish               = if ($thisUpdateAndPublishRunbook -eq $true) { $true } else { $false }
                                    Description           = $params.Payload.properties.description
                                    Tags                  = $tags
                                }
                                if ($commonBoundParameters) { $importParams += $commonBoundParameters }
                                $importParams.Confirm = $false
                                $importParams.ErrorAction = 'Stop'
                                $null = Import-AzAutomationRunbook @importParams
                            }
                            catch {
                                Write-Error "$_" -ErrorAction Stop
                                return
                            }
                        }
                    }
                    catch {
                        Write-Error $_.Exception.Message
                        return
                    }

                    if (
                        $thisUpdateAndPublishRunbook -eq $true -or
                        $thisPublishDraftRunbook -eq $true
                    ) {
                        # Basically to set the runtimeEnvironment as Import-/Set-AzAutomationRunbook does not support it yet
                        Write-Verbose "(Update) $($_.Name) - Runbook settings"
                        $null = ./Common_0001__Invoke-AzRestMethod.ps1 $params
                    }
                }
            }
        }
    }
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Stop
    exit
}
finally {
    Pop-Location
}

Write-Host "`nThe runbook file(s) have been successfully imported and published to the Azure Automation Account.`n" -ForegroundColor White

Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
