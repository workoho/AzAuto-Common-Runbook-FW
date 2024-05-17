<#PSScriptInfo
.VERSION 1.0.0
.GUID a775a4d9-9195-4410-a2bf-b1eeaa0da599
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
    Version 1.0.0 (2024-02-25)
    - Initial release.
#>

<#
.SYNOPSIS
    This script converts PowerShell environment variables to script variables, based on a configuration file.

.DESCRIPTION
    This script takes an array of variables and converts them to script variables. It provides options to respect script parameters with higher priority and set default values, based on a configuration file.
    When used in conjunction with the Common_0002__Import-AzAutomationVariableToPSEnv.ps1 runbook, it allows for the import of Azure Automation variables to PowerShell environment variables and then to script variables.

    The advantage is that during local development, the script can be tested with environment variables, and in Azure Automation, the script can use Azure Automation variables instead.
    This is in particular useful for configuration options or sensitive information, such as passwords, which should not be stored in the script itself.

.PARAMETER Variable
    An array of variables to convert to script variables.

.PARAMETER scriptParameterOnly
    A boolean value indicating whether to process only script parameters.

.EXAMPLE
    PS> Convert-PSEnvToPSScriptVariable -Variable MyVariable -scriptParameterOnly $true

    This example converts the environment variable 'MyVariable' to a script variable, respecting script parameters only.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(mandatory = $true)]
    [AllowEmptyCollection()]
    [Array]$Variable,

    [Boolean]$scriptParameterOnly
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$Variable | & {
    process {
        # Script parameters be of type array/collection and be processed during a loop,
        # and therefore updated multiple times
        if (
            (($scriptParameterOnly -eq $true) -and ($null -eq $_.respectScriptParameter)) -or
            (($scriptParameterOnly -eq $false) -and ($null -ne $_.respectScriptParameter))
        ) { return }

        if ($null -eq $_.mapToVariable) {
            Write-Warning "[COMMON]: - [$($_.sourceName) --> `$script:???] Missing mapToVariable property in configuration."
            return
        }

        $params = @{
            Name  = $_.mapToVariable
            Scope = 2
            Force = $true
        }

        if (-Not $_.respectScriptParameter) { $params.Option = 'Constant' }

        if (
            ($_.respectScriptParameter) -and
            ($null -ne $(Get-Variable -Name $_.respectScriptParameter -Scope $params.Scope -ValueOnly -ErrorAction SilentlyContinue))
        ) {
            $params.Value = Get-Variable -Name $_.respectScriptParameter -Scope $params.Scope -ValueOnly
            Write-Verbose "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Using value from script parameter $($_.respectScriptParameter)"
        }
        elseif ($null -ne [Environment]::GetEnvironmentVariable($_.sourceName)) {
            $params.Value = (Get-ChildItem -Path "env:$($_.sourceName)").Value
            Write-Verbose "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Using value from `$env:$($_.sourceName)"
        }
        elseif ($_.ContainsKey('defaultValue')) {
            $params.Value = $_.defaultValue
            Write-Verbose "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] `$env:$($_.sourceName) not found, using built-in default value"
        }
        else {
            Write-Error "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Missing default value in configuration."
            return
        }

        if (
            $null -ne $params.Value -and
            $params.Value.GetType().Name -eq 'String' -and
            (
                $params.Value -eq '""' -or
                $params.Value -eq "''"
            )
        ) {
            Write-Verbose "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Value converted to empty string."
            $params.Value = [string]''
        }

        if (
            -Not $_.Regex -and
            $null -ne $params.Value -and
            $params.Value.GetType().Name -eq 'String'
        ) {
            if ($params.Value -eq 'True') {
                $params.Value = $true
                Write-Verbose "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Value converted to boolean True"
            }
            elseif ($params.Value -eq 'False') {
                $params.Value = $false
                Write-Verbose "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Value converted to boolean False"
            }
            elseif ($_.ContainsKey('defaultValue')) {
                $params.Value = $_.defaultValue
                Write-Warning "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Value does not seem to be a boolean, using built-in default value"
            }
            else {
                Write-Error "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Value does not seem to be a boolean, and no default value was found in configuration."
                return
            }
        }

        if (
            $_.Regex -and
            (-Not [String]::IsNullOrEmpty($params.Value)) -and
            ($params.Value -notmatch $_.Regex)
        ) {
            $params.Value = $null
            if ($_.ContainsKey('defaultValue')) {
                $params.Value = $_.defaultValue
                Write-Warning "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Value does not match '$($_.Regex)', using built-in default value"
            }
            else {
                Write-Error "[COMMON]: - [$($_.sourceName) --> `$script:$($params.Name)] Value does not match '$($_.Regex)', and no default value was found in configuration."
                return
            }
        }
        New-Variable @params
    }
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
