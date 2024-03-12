<#PSScriptInfo
.VERSION 1.0.0
.GUID 21809011-e700-46e3-8743-c6dfde9b75ee
.AUTHOR Julian Pawlowski
.COMPANYNAME Workoho GmbH
.COPYRIGHT © 2024 Workoho GmbH
.TAGS
.LICENSEURI https://github.com/Workoho/AzAuto-Common-Runbook-FW/LICENSE.txt
.PROJECTURI https://github.com/Workoho/AzAuto-Common-Runbook-FW
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
    Sets Azure Automation variables based on the project configuration.

.DESCRIPTION
    This script sets Azure Automation variables based on the project configuration files. It reads the project configuration, connects to Azure, and compares the variables in the configuration with the variables in the Azure Automation account. It creates missing variables and updates existing variables if necessary.

.PARAMETER VariableName
    Specifies the name of the variable to set. If not specified, all variables will be processed.

.PARAMETER UpdateVariableValue
    Indicates whether to update the value of existing variables. By default, only missing variables will be created.

.EXAMPLE
    Set-AzAutomationVariable -VariableName 'MyVariable' -UpdateVariableValue

    This example sets the value of the 'MyVariable' variable in the Azure Automation account. If the variable already exists, its value will be updated.
#>

#Requires -Module @{ ModuleName='Az.Accounts'; ModuleVersion='2.16.0' }
#Requires -Module @{ ModuleName='Az.Resources'; ModuleVersion='6.16.0' }
#Requires -Module @{ ModuleName='Az.Automation'; ModuleVersion='1.10.0' }

[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'High'
)]
Param (
    [array]$VariableName,
    [switch]$UpdateVariableValue
)

if ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) {
    Write-Error 'This script must be run interactively by a privileged administrator account.' -ErrorAction Stop
    exit
}
Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$commonParameters = 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable'
$commonBoundParameters = @{}; $PSBoundParameters.Keys | Where-Object { $_ -in $commonParameters } | ForEach-Object { $commonBoundParameters[$_] = $PSBoundParameters[$_] }

Write-Host "`n`nAutomation Variables Setup`n==========================`n" -ForegroundColor White

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
    $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams
}
catch {
    Write-Error "Insufficent Azure permissions: At least 'Reader' role for the Automation Account is required to validate automation variables. Further permissions may be required to perform changes." -ErrorAction Stop
    $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
    exit
}
finally {
    Pop-Location
}
#endregion

$SetVariables = Get-AzAutomationVariable -ResourceGroupName $automationAccount.ResourceGroupName -AutomationAccountName $automationAccount.AutomationAccountName -ErrorAction SilentlyContinue

$ConfirmedAzPermission = $false
($Variables | Sort-Object -Property Name).GetEnumerator() | & {
    process {
        if ($VariableName -and ($VariableName -notcontains $_.Name)) { return }
        $SetVariable = $SetVariables | Where-Object Name -eq $_.Name

        if ($SetVariable) {
            if (
                (
                    $null -eq $_.Encrypted -and
                    $SetVariable.Encrypted -eq $true
                ) -or
                (
                    $null -ne $_.Encrypted -and
                    $SetVariable.Encrypted -eq $_.Encrypted
                )
            ) {
                Write-Host "    (ERROR)        " -NoNewline -ForegroundColor Red
                Write-Host "$($SetVariable.Name)"
                Write-Error $($SetVariable.Name + ': Variable encryption missmatch: Should be ' + $_.Encrypted + ', not ' + $SetVariable.Encrypted)
            }
            elseif ($SetVariable.Value.PSObject.TypeNames[0] -ne $_.Value.PSObject.TypeNames[0]) {
                Write-Host "    (ERROR)        " -NoNewline -ForegroundColor Red
                Write-Host "$($SetVariable.Name)"
                Write-Error $($SetVariable.Name + ': Variable type missmatch: Should be ' + $_.Value.PSObject.TypeNames[0] + ', not ' + $SetVariable.Value.PSObject.TypeNames[0])
            }
            elseif (
                (
                    -not $SetVariable.Encrypted -and
                    -not [string]::IsNullOrEmpty($_.Value) -and
                    $SetVariable.Value -ne $_.Value
                ) -or
                ($SetVariable.Encrypted -and $UpdateVariableValue)
            ) {
                if ($UpdateVariableValue) {
                    Write-Host "    (Update value) " -NoNewline -ForegroundColor White
                    Write-Host $SetVariable.Name
                    if ($PSCmdlet.ShouldProcess(
                            "Update the VALUE of Automation Variable '$($SetVariable.Name)' in '$($automationAccount.AutomationAccountName)'",
                            "Do you confirm to update the VALUE of Automation Variable '$($SetVariable.Name)' in '$($automationAccount.AutomationAccountName)' ?",
                            'Update the VALUE of Automation Variables in Azure Automation Account'
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
                            $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams
                        }
                        catch {
                            Write-Error "Insufficent Azure permissions: At least 'Automation Contributor' role for the Automation Account is required to setup automation variables." -ErrorAction Stop
                            $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
                            exit
                        }
                        finally {
                            Pop-Location
                        }
                        #endregion

                        try {
                            $params = @{
                                ResourceGroupName     = $automationAccount.ResourceGroupName
                                AutomationAccountName = $automationAccount.AutomationAccountName
                                Name                  = $SetVariable.Name
                                Value                 = $_.Value
                                Encrypted             = $SetVariable.Encrypted
                            }
                            if ($commonBoundParameters) { $params += $commonBoundParameters }
                            $null = Set-AzAutomationVariable @params
                            Write-Host "    (Ok)           " -NoNewline -ForegroundColor Green
                            Write-Host "$($SetVariable.Name)"
                        }
                        catch {
                            Write-Host "    (ERROR)        " -NoNewline -ForegroundColor Red
                            Write-Host "$($SetVariable.Name)"
                            Write-Error "$_" -ErrorAction Stop
                            exit
                        }
                    }
                    else {
                        return
                    }
                }
                else {
                    Write-Host "    (WARNING)      " -NoNewline -ForegroundColor Yellow
                    Write-Host "$($SetVariable.Name)"
                    Write-Warning $($_.Name + ': Variable value missmatch: Should be ''' + $_.Value + ''', not ''' + $SetVariable.Value + '''')
                }
            }
            else {
                Write-Host "    (Ok)           " -NoNewline -ForegroundColor Green
                Write-Host "$($SetVariable.Name)"
            }
            return
        }

        Write-Host "    (Missing)      " -NoNewline -ForegroundColor White
        Write-Host $_.Name
        if ($PSCmdlet.ShouldProcess(
                "Create missing Automation Variable '$($_.Name)' in '$($automationAccount.AutomationAccountName)'",
                "Do you confirm to create missing Automation Variable '$($_.Name)' in '$($automationAccount.AutomationAccountName)' ?",
                'Create missing Automation Variables in Azure Automation Account'
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
                $null = .\Common_0003__Confirm-AzRoleActiveAssignment.ps1 @confirmParams
            }
            catch {
                Write-Error "Insufficent Azure permissions: At least 'Automation Contributor' role for the Automation Account is required to setup automation variables." -ErrorAction Stop
                $null = Disconnect-AzAccount -ErrorAction SilentlyContinue
                exit
            }
            finally {
                Pop-Location
            }
            #endregion

            try {
                $params = @{
                    ResourceGroupName     = $automationAccount.ResourceGroupName
                    AutomationAccountName = $automationAccount.AutomationAccountName
                    Name                  = $_.Name
                    Value                 = $_.Value
                    Encrypted             = if ($_.Encrypted) { $_.Encrypted } else { $false }
                }
                if (-not [string]::IsNullOrEmpty($_.Description)) { $params.Description = $_.Description }
                $null = New-AzAutomationVariable @params
                Write-Host "    (Ok)           " -NoNewline -ForegroundColor Green
                Write-Host "$($_.Name)"
            }
            catch {
                Write-Host "    (ERROR)        " -NoNewline -ForegroundColor Red
                Write-Host "$($_.Name)"
                Write-Error "$_" -ErrorAction Stop
                exit
            }
        }
        else {
            return
        }
    }
}

Write-Host "`nThe automation variables have been successfully configured.`n" -ForegroundColor White

Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
