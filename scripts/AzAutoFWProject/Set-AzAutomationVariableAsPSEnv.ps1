<#PSScriptInfo
.VERSION 1.0.0
.GUID 1b43d025-33ad-4216-8088-6624565dfbc2
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
    Version 1.0.0 (2024-05-01)
    - Initial release.
#>

<#
.SYNOPSIS
    Set Azure Automation Variables from configuration file as environment variables.

.PARAMETER Variable
    Specifies an array of variable names to set. If provided, only the specified variables will be set. If not provided, all configured variables will be set.

.PARAMETER Force
    Specifies that the environment variables should be set in any case, even if they are already set with the same value.

.DESCRIPTION
    This script reads the project configuration file and sets the automation variables as environment variables.
    It also checks if the environment variables are already set and if they are set with the same value.

    This is useful for local development and testing, as the automation variables are set as environment variables for the current process.
    It replicates the same behavior as when the automation variables are set as environment variables in the Azure Automation account using
    the 'Common_0002__Import-AzAutomationVariableToPSEnv.ps1' runbook.

    This is the prerequisite for running the Azure Automation runbooks locally when using the 'Common_0000__Convert-PSEnvToPSScriptVariable.ps1' runbook.
#>

[CmdletBinding()]
Param(
    [array]$Variable,
    [switch]$Force
)

Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$commonParameters = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
$commonBoundParameters = @{}; $PSBoundParameters.Keys | Where-Object { $_ -in $commonParameters } | ForEach-Object { $commonBoundParameters[$_] = $PSBoundParameters[$_] }

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
    'AutomationVariable'
) | & {
    process {
        if ($null -eq $config.$_) {
            Write-Error "Mandatory property '/PrivateData/$_' is missing or null in the AzAutoFWProject.psd1 configuration file." -ErrorAction Stop
            exit
        }
    }
}
@(
    'AutomationVariable'
) | & {
    process {
        if ($null -eq $config.Local.$_) {
            Write-Error "Mandatory property '/PrivateData/$_' is missing or null in the AzAutoFWProject.local.psd1 configuration file." -ErrorAction Stop
            exit
        }
    }
}
#endregion

#region Set Automation Variables as Environment Variables
$Variables = @($config.AutomationVariable + $config.Local.AutomationVariable) | Group-Object -Property Name | ForEach-Object {
    if ($_.Count -gt 2) {
        Write-Error "Automation Variable '$($_.Name)' has too many definitions."
        exit
    }
    elseif ($_.Count -eq 2) {
        $item = $_.Group | Where-Object { -not [string]::IsNullOrEmpty($_.Value) } | Select-Object -Last 1
        if ($null -eq $item) { $item = $_.Group | Select-Object -Last 1 }
        $description = $_.Group | Where-Object { $null -ne $_.Description -and -not [string]::IsNullOrEmpty($_.Description) } | Select-Object -ExpandProperty Description -Last 1
        if ($null -eq $item.PSObject.Properties['Description']) {
            $item | Add-Member -MemberType NoteProperty -Name 'Description' -Value $description
        }
        else {
            $item.Description = $description
        }
        $item
    }
    else {
        $_.Group | Select-Object -First 1
    }
}

($Variables | Sort-Object -Property Name).GetEnumerator() | & {
    process {
        if (($null -ne $script:Variable) -and ($_.Name -notin $script:Variable)) { return }

        if (
            -not $Force -and
            [Environment]::GetEnvironmentVariables('Process').ContainsKey($_.Name)
        ) {
            if ([Environment]::GetEnvironmentVariable($_.Name, 'Process') -ne $_.Value) {
                Write-Warning "Environment variable '$($_.Name)' already set, but with different value."
            }
            else {
                Write-Verbose "Environment variable '$($_.Name)' already set."
            }
        }
        else {
            Write-Verbose "Setting environment variable '$($_.Name)'."
            [Environment]::SetEnvironmentVariable($_.Name, $_.Value, 'Process')
        }
    }
}
#endregion

Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
