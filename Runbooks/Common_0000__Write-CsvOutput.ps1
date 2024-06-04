<#PSScriptInfo
.VERSION 1.0.1
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
    Version 1.0.1 (2024-06-04)
    - Remove SAS token from output when uploading to Azure Storage
#>

<#
.SYNOPSIS
    Write text in CSV format to output stream

.DESCRIPTION
    This script is used to write text in CSV format to the output stream. It takes an input object and converts it to CSV using the ConvertTo-Csv cmdlet.
    The converted CSV is then written to the output stream, or uploaded to a blob storage if the StorageUri parameter is specified.

.PARAMETER InputObject
    Specifies the object to be converted to CSV.

.PARAMETER ConvertToParam
    Specifies additional parameters to be passed to the ConvertTo-CSV cmdlet.
    NoTypeInformation is set to true by default. If you want to include type information, set NoTypeInformation to false (PS >= 5.1) or IncludeTypeInformation to true (PS >= 6.0).

.PARAMETER BooleanTrueValue
    Specifies the value to be used for boolean true values. Default is '1'.

.PARAMETER BooleanFalseValue
    Specifies the value to be used for boolean false values. Default is '0'.

.PARAMETER StorageUri
    Specifies the URI of the storage where the CSV file should be uploaded.
    If this parameter is specified, the CSV file will be uploaded to the specified storage.
    If this parameter is not specified, the CSV file will be written to the output stream.

    The URI must be in the format 'https://<storage-account-name>.blob.core.windows.net/<container-name>/<blob-name>.csv' for blob storage
    or 'https://<storage-account-name>.file.core.windows.net/<share-name>/<file-name>.csv' for file storage.

    Please note that the Azure Automation account's managed identity (or your developer account) must have the 'Storage Blob Data Contributor' or
    'Storage File Data SMB Share Contributor' role on the storage account, depending on the storage type.
    Remember that general Owner or Contributor roles are NOT sufficient for uploading blobs to a storage account.

    For information compliance reasons, consider to configure retention policies for the storage account and the blob container if you are uploading sensitive data like personal identifiable information (PII).

.EXAMPLE
    PS> Common_0000__Write-CsvOutput.ps1 -InputObject $data
    This example converts the $data object to CSV, and writes it to the output stream.

.EXAMPLE
    PS> Common_0000__Write-CsvOutput.ps1 -InputObject $data -StorageUri 'https://mystorageaccount.blob.core.windows.net/mycontainer/myblob.csv'
    This example converts the $data object to CSV, and uploads it to the specified blob storage.

.EXAMPLE
    PS> Common_0000__Write-CsvOutput.ps1 -InputObject $data -StorageUri 'https://mystorageaccount.file.core.windows.net/myshare/myfile.csv?sastoken'
    This example converts the $data object to CSV, and uploads it to the specified file storage.

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
    [string] $StorageUri
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
    if ($StorageUri) {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $streamWriter = New-Object System.IO.StreamWriter($tempFile, $false, [System.Text.Encoding]::UTF8)
        try {
            $InputObject | Convert-PropertyValues | ConvertTo-Csv @params | & { process { $streamWriter.WriteLine($_) } }
        }
        finally {
            $streamWriter.Close()
        }

        $uri = [System.Uri] $StorageUri
        $sasToken = $uri.Query.TrimStart('?')
        $hostParts = $uri.Host.Split('.')
        $storageAccountName = $hostParts[0]
        $storageType = $hostParts[1]
        $pathParts = $uri.AbsolutePath.Split('/')
        $containerName = $pathParts[1]
        $filePath = $pathParts[2..($pathParts.Length - 1)] -join '/'
        if ([string]::IsNullOrEmpty($filePath)) { $filePath = [System.IO.Path]::GetFileNameWithoutExtension($tempFile) }
        if (-not $filePath.EndsWith('.csv')) { $filePath += '.csv' }

        ./Common_0000__Import-Module.ps1 -Modules @(
            @{ Name = 'Az.Storage'; MinimumVersion = '3.0' }
        ) 1> $null

        if ([string]::IsNullOrEmpty($sasToken)) {
            $context = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount -ErrorAction Stop
        }
        else {
            $sasToken = [System.Uri]::UnescapeDataString($sasToken)
            $context = New-AzStorageContext -StorageAccountName $storageAccountName -SasToken $sasToken -ErrorAction Stop
        }

        if ($storageType -eq 'blob') {
            $params = @{
                File        = $tempFile
                Container   = $containerName
                Blob        = $filePath
                Context     = $context
                Force       = $true
                ErrorAction = 'Stop'
                Verbose     = $false
                Debug       = $false
            }
            $null = Set-AzStorageBlobContent @params
        }
        elseif ($storageType -eq 'file') {
            if (-not $context.StorageAccount.Credentials.IsSAS) {
                Throw "The storage type 'file' requires a SAS token in the StorageUri parameter."
            }
            $params = @{
                Source      = $tempFile
                ShareName   = $containerName
                Path        = $filePath
                Context     = $context
                Force       = $true
                ErrorAction = 'Stop'
                Verbose     = $false
                Debug       = $false
            }
            $null = Set-AzStorageFileContent @params
        }
        else {
            throw "Invalid storage type '$storageType'. The storage type must be 'blob' or 'file."
        }

        Write-Output "CSV file uploaded to $($uri.GetLeftPart([System.UriPartial]::Path))"
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
