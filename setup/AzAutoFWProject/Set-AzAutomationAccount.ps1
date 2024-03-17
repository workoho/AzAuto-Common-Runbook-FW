<#PSScriptInfo
.VERSION 1.0.0
.GUID 3668222f-3d80-4793-9af5-9663f4147fd6
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
    Sets up an Azure Automation Account for the AzAutoFWProject.

.DESCRIPTION
    This script sets up an Azure Automation Account for the AzAutoFWProject by creating a resource group and an automation account in Azure. It reads the project configuration from the local configuration file and connects to Azure using the provided credentials. If the resource group or automation account already exists, it will not be created again. The script requires privileged administrator account privileges to run interactively.

.PARAMETER None
    This script does not accept any parameters.

.EXAMPLE
    Set-AzAutomationAccount

    This example shows how to run the script to set up the Azure Automation Account for the AzAutoFWProject.
#>

#Requires -Module @{ ModuleName='Az.Accounts'; ModuleVersion='2.16.0' }
#Requires -Module @{ ModuleName='Az.Resources'; ModuleVersion='6.16.0' }
#Requires -Module @{ ModuleName='Az.Automation'; ModuleVersion='1.10.0' }

[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'High'
)]
Param()

if ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
    Write-Error 'This script must be run interactively by a privileged administrator account.' -ErrorAction Stop
    exit
}
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$commonParameters = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
$commonBoundParameters = @{}; $PSBoundParameters.Keys | Where-Object { $_ -in $commonParameters } | ForEach-Object { $commonBoundParameters[$_] = $PSBoundParameters[$_] }

if ($null -eq $MyInvocation.PSScriptRoot -or $MyInvocation.ScriptName -like '*Invoke-Setup.ps1') {
    Write-Host "`n`nAutomation Account Setup`n========================`n" -ForegroundColor White
}

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
    'Name'
    'ResourceGroupName'
    'SubscriptionId'
    'TenantId'
) | & {
    process {
        if ([string]::IsNullOrEmpty($config.Local.AutomationAccount.$_)) {
            Write-Error "Mandatory property '/PrivateData/AutomationAccount/$_' is missing or null in the AzAutoFWProject.local.psd1 local configuration file." -ErrorAction Stop
            exit
        }
    }
}

$SubscriptionScope = "/subscriptions/$($config.local.AutomationAccount.SubscriptionId)"
$RgScope = "$SubscriptionScope/resourcegroups/$($config.local.AutomationAccount.ResourceGroupName)"
$SelfScope = "$RgScope/providers/Microsoft.Automation/automationAccounts/$($config.local.AutomationAccount.Name)"
#endregion

#region Connect to Azure
try {
    Push-Location
    Set-Location (Join-Path $config.Project.Directory 'Runbooks')
    $connectParams = @{
        Tenant       = $config.local.AutomationAccount.TenantId
        Subscription = $config.local.AutomationAccount.SubscriptionId
    }
    .\Common_0001__Connect-AzAccount.ps1 @connectParams
}
catch {
    Write-Error "$_" -ErrorAction Stop
    exit
}
finally {
    Pop-Location
}
#endregion

try {
    $params = @{
        ResourceGroupName = $config.local.AutomationAccount.ResourceGroupName
        Name              = $config.local.AutomationAccount.Name
        ErrorAction       = 'SilentlyContinue'
    }
    $automationAccount = Get-AzAutomationAccount @params
}
catch {
    Write-Error "$_" -ErrorAction Stop
    exit
}

if ($automationAccount) {
    if ($null -eq $MyInvocation.PSScriptRoot -or $MyInvocation.ScriptName -like '*Invoke-Setup.ps1') {
        Write-Host "Working on Azure Automation Account" -NoNewline
        Write-Host " '$($automationAccount.AutomationAccountName)'" -ForegroundColor Green -NoNewline
        Write-Host " in resource group '$($automationAccount.ResourceGroupName)'"
    }
}
else {
    $commonBoundParameters.ErrorAction = 'Stop'

    if (-Not (Get-AzResourceGroup -Name $config.local.AutomationAccount.ResourceGroupName -ErrorAction SilentlyContinue)) {

        #region Confirm Azure Role Assignments
        try {
            Push-Location
            Set-Location (Join-Path $config.Project.Directory 'Runbooks')
            $confirmParams = @{
                Roles = @{
                    $SubscriptionScope = 'Contributor'
                }
            }
            if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
            $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams
        }
        catch {
            Write-Error "Insufficent Azure permissions: At least 'Contributor' role for the subscription is required for initial creation of the resource group." -ErrorAction Stop
            $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
            exit
        }
        finally {
            Pop-Location
        }
        #endregion

        $Location = if ([string]::IsNullOrEmpty($config.local.AutomationAccount.Location)) {
            if ($config.local.AutomationAccount.ResourceGroupName -match '^[^-]*-([^-]*)-.+$') {
                $Region = $Matches[1]
                if (Get-AzLocation | Where-Object { $_.Providers -contains 'Microsoft.Automation' -and $_.Location -eq $Region }) {
                    $Region
                }
                else {
                    Write-Error "Could not determine location for Resource Group $($config.local.AutomationAccount.ResourceGroupName) from local configuration file." -ErrorAction Stop
                    exit
                }
            }
            else {
                Write-Error "Could not determine location for Resource Group $($config.local.AutomationAccount.ResourceGroupName) from local configuration file." -ErrorAction Stop
                exit
            }
        }
        else { $config.local.AutomationAccount.Location }

        $params = @{
            Name     = $config.local.AutomationAccount.ResourceGroupName
            Location = $Location
        }
        if ($null -ne $config.local.AutomationAccount.Tag -and $config.local.AutomationAccount.Tag.Count -gt 0) {
            $params.Tag = $config.local.AutomationAccount.Tag
        }

        if ($PSCmdlet.ShouldProcess(
                "Create Resource Group '$($params.Name)' in location '$($params.Location)'",
                "Do you confirm to create new Resource Group '$($params.Name)' in location '$($params.Location)' ?",
                'Create new Resource Group'
            )) {

            try {
                if ($commonBoundParameters) { $params += $commonBoundParameters }
                $config.local.AutomationAccount.Location = (New-AzResourceGroup @params).Location
            }
            catch {
                Write-Error "$_" -ErrorAction Stop
                exit
            }
        }
        elseif ($WhatIfPreference) {
            Write-Verbose 'What If: A new Resource Group would have been created.'
        }
        else {
            Write-Verbose 'Creation of new Resource Group was aborted.'
            exit
        }
    }

    #region Confirm Azure Role Assignments
    try {
        Push-Location
        Set-Location (Join-Path $config.Project.Directory 'Runbooks')
        $confirmParams = @{
            Roles = @{
                $RgScope = 'Contributor'
            }
        }
        if ($commonBoundParameters) { $confirmParams += $commonBoundParameters }
        $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams
    }
    catch {
        Write-Error "Insufficent Azure permissions: At least 'Contributor' role for the resource group is required for initial creation of the Automation Account." -ErrorAction Stop
        $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
        exit
    }
    finally {
        Pop-Location
    }
    #endregion

    $Location = if ([string]::IsNullOrEmpty($config.local.AutomationAccount.Location)) {
        (Get-AzResourceGroup -Name $config.local.AutomationAccount.ResourceGroupName).Location
    }
    else { $config.local.AutomationAccount.Location }

    $params = @{
        ResourceGroupName = $config.local.AutomationAccount.ResourceGroupName
        Name              = $config.local.AutomationAccount.Name
        Location          = $Location
        Plan              = if ([string]::IsNullOrEmpty($config.local.AutomationAccount.Plan)) { 'Basic' } else { $config.local.AutomationAccount.Plan }
    }
    if ($null -ne $config.local.AutomationAccount.Tag -and $config.local.AutomationAccount.Tag.Count -gt 0) {
        $params.Tag = $config.local.AutomationAccount.Tag
    }

    if ($PSCmdlet.ShouldProcess(
            "Create Azure Automation Account '$($params.ResourceGroupName)'",
            "Do you confirm to create new Azure Automation Account '$($params.Name)' in resource group '$($params.ResourceGroupName)' ?",
            'Create new Azure Automation Account'
        )) {
        try {
            $automationAccount = New-AzAutomationAccount @params @commonBoundParameters
            Write-Host "Azure Automation Account '$($automationAccount.Name)' in resource group '$($automationAccount.ResourceGroupName)' created successfully." -ForegroundColor Green
        }
        catch {
            Write-Error "$_" -ErrorAction Stop
            exit
        }
    }
    elseif ($WhatIfPreference) {
        Write-Verbose 'What If: A new Azure Automation account would have been created.'
    }
    else {
        Write-Verbose 'Creation of new Azure Automation account was aborted.'
        exit
    }
}

Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"

if ($null -ne $MyInvocation.PSScriptRoot -and $MyInvocation.ScriptName -notLike '*Invoke-Setup.ps1') {
    return $automationAccount
}
