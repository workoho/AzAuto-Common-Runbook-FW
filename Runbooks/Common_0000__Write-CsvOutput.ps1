<#PSScriptInfo
.VERSION 1.0.0
.GUID 7086a21d-f021-4f05-99a7-ec2a6de6f749
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
    Version 1.0.0 (2024-05-30)
    - Initial release.
#>

<#
.SYNOPSIS
    Write text in CSV format to output stream

.DESCRIPTION
    This script is used to write text in CSV format to the output stream. It takes an input object and converts it to CSV using the ConvertTo-Csv cmdlet.
    The converted CSV is then written to the output stream, or uploaded to a blob storage if the BlobStorageUri parameter is specified.

.PARAMETER InputObject
    Specifies the object to be converted to CSV.

.PARAMETER ConvertToParam
    Specifies additional parameters to be passed to the ConvertTo-CSV cmdlet.
    NoTypeInformation is set to true by default. If you want to include type information, set NoTypeInformation to false (PS >= 5.1) or IncludeTypeInformation to true (PS >= 6.0).

.PARAMETER BooleanTrueValue
    Specifies the value to be used for boolean true values. Default is '1'.

.PARAMETER BooleanFalseValue
    Specifies the value to be used for boolean false values. Default is '0'.

.PARAMETER BlobStorageUri
    Specifies the URI of the blob storage where the CSV file should be uploaded.
    If this parameter is specified, the CSV file will be uploaded to the specified blob storage.
    If this parameter is not specified, the CSV file will be written to the output stream.

    Please note that the Azure Automation account's managed identity (or your developer account) must have the 'Storage Blob Data Contributor' role assigned to the storage account.
    Remember that general Owner or Contributor roles are NOT sufficient for uploading blobs to a storage account.

    For information compliance reasons, consider to configure retention policies for the storage account and the blob container if you are uploading sensitive data like personal identifiable information (PII).

.EXAMPLE
    PS> Common_0000__Write-CsvOutput.ps1 -InputObject $data
    This example converts the $data object to CSV, and writes it to the output stream.

.EXAMPLE
    PS> Common_0000__Write-CsvOutput.ps1 -InputObject $data -BlobStorageUri 'https://mystorageaccount.blob.core.windows.net/mycontainer/myblob.csv'
    This example converts the $data object to CSV, and uploads it to the specified blob storage.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    $InputObject,

    [hashtable] $ConvertToParam,
    [string] $BooleanTrueValue = '1',
    [string] $BooleanFalseValue = '0',
    [string] $BlobStorageUri
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
# Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$params = if ($ConvertToParam) { $ConvertToParam.Clone() } else { @{} }
if ($null -eq $params.NoTypeInformation -and ($null -eq $params.IncludeTypeInformation -or $params.IncludeTypeInformation -eq $false)) {
    $params.Remove('IncludeTypeInformation')
    $params.NoTypeInformation = $true # use NoTypeInformation for PowerShell 5.1 backwards compatibility
}
if ($null -eq $params.ErrorAction) {
    $params.ErrorAction = 'Stop'
}

function Convert-PropertyValues {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSObject]$Obj
    )

    process {
        foreach ($property in $Obj.PSObject.Properties) {
            if ($property.IsSettable) {
                if ($property.Value -is [DateTime]) {
                    $property.Value = [DateTime]::Parse($property.Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                }
                elseif ($property.Value -is [bool]) {
                    $property.Value = if ($property.Value) { $BooleanTrueValue } else { $BooleanFalseValue }
                }
                elseif ($property.Value -is [array]) {
                    $property.Value = $property.Value -join ', '
                }
            }
        }
        return $Obj
    }
}

try {
    if ($BlobStorageUri) {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $InputObject | Convert-PropertyValues | ConvertTo-Csv @params | Out-File -FilePath $tempFile -Encoding UTF8

        $uri = [System.Uri] $BlobStorageUri
        $storageAccountName = $uri.Host.Split('.')[0]
        $pathParts = $uri.AbsolutePath.Split('/')
        $containerName = $pathParts[1]
        $blobName = $pathParts[2]
        if ([string]::IsNullOrEmpty($blobName)) { $blobName = [System.IO.Path]::GetFileNameWithoutExtension($tempFile) }
        if (-not $blobName.EndsWith('.csv')) { $blobName += '.csv' }

        ./Common_0000__Import-Module.ps1 -Modules @(
            @{ Name = 'Az.Storage'; MinimumVersion = '3.0' }
        ) 1> $null

        $params = @{
            File        = $tempFile
            Container   = $containerName
            Blob        = $blobName
            Context     = (New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount -ErrorAction Stop)
            Force       = $true
            ErrorAction = 'Stop'
            Verbose     = $false
            Debug       = $false
        }
        $null = Set-AzStorageBlobContent @params
        Write-Output "CSV file uploaded to $BlobStorageUri"
    }
    else {
        Write-Output $(
            $InputObject | Convert-PropertyValues | ConvertTo-Csv @params
        )
    }
}
catch {
    throw $_.Exception.Message
}
finally {
    if ($tempFile) { Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue }
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
# Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
