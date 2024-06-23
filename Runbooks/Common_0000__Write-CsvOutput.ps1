<#PSScriptInfo
.VERSION 1.3.0
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
    Version 1.3.0 (2024-06-23)
    - Conversion of hashtable objects to PSCustomObject before converting to CSV
    - Add NullValue parameter to specify the value to be used for null values
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

.PARAMETER NullValue
    Specifies the value to be used for null values. Default is a $null value, which leaves the field empty.
    Note that if you want to have an empty string instead of a null value, you can set NullValue to an empty string ('').
    You may also set NullValue to any other value you want to use for null values, like 'NULL' or 'N/A'.

.PARAMETER Metadata
    Specifies the metadata to append to the CSV file. The metadata is represented as key-value pairs, where keys (prefixed by '#') are placed in the first column, and their corresponding values in the second column.
    This is useful for adding additional information to the CSV file, such as column descriptions or data source information.

    The metadata should be provided as a PSCustomObject. The properties of the PSCustomObject are used as column names in the CSV, and the corresponding values are used as the column values.

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

.PARAMETER FileEncoding
    Specifies the encoding to be used when writing the CSV file. Default is 'utf8BOM'.
    Possible values are 'ansi', 'ascii', 'bigendianunicode', 'bigendianutf32', 'oem', 'unicode', 'utf7', 'utf8', 'utf8BOM', 'utf8NoBOM', 'utf32'.

    Note that utf8BOM stands for UTF-8 with Byte Order Mark (BOM) and utf8NoBOM stands for UTF-8 without BOM.
    A BOM helps to identify the encoding of a file, like for Microsoft Excel. However, some applications may not support BOMs, or use other techniques to identify the encoding.

.PARAMETER FileNewLine
    Specifies the newline character to be used when writing the CSV file. Default is "`r`n" to use Windows-style line endings (CRLF).

.EXAMPLE
    PS> Common_0000__Write-CsvOutput.ps1 -InputObject $data
    This example converts the $data object to CSV, and writes it to the output stream.

.EXAMPLE
    PS> Common_0000__Write-CsvOutput.ps1 -InputObject $data -StorageUri 'https://mystorageaccount.blob.core.windows.net/mycontainer/myblob.csv?sastoken'
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
    [pscustomobject] $Metadata,

    [hashtable] $ConvertToParam,
    [string] $BooleanTrueValue = '1',
    [string] $BooleanFalseValue = '0',
    [string] $NullValue,
    [string] $StorageUri,
    [string] $FileEncoding = 'utf8BOM',
    [string] $FileNewLine = "`r`n"
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }
if ($null -eq $InputObject -or $InputObject.count -eq 0) { exit }
if (-Not $Global:hasRunBefore) { $Global:hasRunBefore = @{} }
if (-Not $Global:hasRunBefore.ContainsKey((Get-Item $PSCommandPath).Name)) {
    Write-Verbose "---START of $((Get-Item $PSCommandPath).Name), $((Test-ScriptFileInfo $PSCommandPath | Select-Object -Property Version, Guid | & { process{$_.PSObject.Properties | & { process{$_.Name + ': ' + $_.Value} }} }) -join ', ') ---"
}
$StartupVariables = (Get-Variable | & { process { $_.Name } })      # Remember existing variables so we can cleanup ours at the end of the script

$params = if ($ConvertToParam) { $ConvertToParam.Clone() } else { @{} }
if ([string]::IsNullOrEmpty($params.NoTypeInformation) -and ([string]::IsNullOrEmpty($params.IncludeTypeInformation) -or $params.IncludeTypeInformation -eq $false)) {
    $params.Remove('IncludeTypeInformation')
    $params.NoTypeInformation = $true # use NoTypeInformation for PowerShell 5.1 backwards compatibility
}
if ($params.UseCulture -eq $true) {
    $params.Delimiter = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ListSeparator
    $params.Remove('UseCulture')
}
elseif ([string]::IsNullOrEmpty($params.Delimiter)) {
    $params.Delimiter = ','
}
if ([string]::IsNullOrEmpty($params.ErrorAction)) {
    $params.ErrorAction = 'Stop'
}

function ConvertTo-CsvFriendlyObject {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
        [psobject]$InputObject,
        [string]$TrueString = "True",
        [string]$FalseString = "False",
        [string]$ArraySeparator = ", ", # Default is ", " for better readability
        [AllowNull()][string]$NullString = $null, # Default is $null to leave fields empty
        [int]$MaxDepth = 2  # Limit recursion depth to 2
    )

    process {
        if ($null -eq $InputObject) {
            Write-Debug "Skipping null input object"
            return
        }

        function Convert-Value {
            param (
                [object]$Value,
                [int]$CurrentDepth
            )

            if ($CurrentDepth -gt $MaxDepth) {
                if ($Value -is [System.Collections.IEnumerable] -or $Value -is [System.Collections.IDictionary]) {
                    Write-Debug "Converting complex nested structure to JSON"
                    return $Value | ConvertTo-Json -Compress
                }
                return $Value
            }

            if ($Value -is [DateTime]) {
                Write-Debug "Converting DateTime value"
                return $Value.ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            elseif ($Value -is [bool]) {
                Write-Debug "Converting Boolean value"
                return $(if ($Value) { $TrueString } else { $FalseString })
            }
            elseif ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
                Write-Debug "Converting Array value"
                return Process-Array -Array $Value -CurrentDepth ($CurrentDepth + 1)
            }
            elseif ($Value -is [System.Collections.Hashtable]) {
                Write-Debug "Converting Hashtable value"
                Process-Hashtable -Hashtable $Value -CurrentDepth ($CurrentDepth + 1)
                return [PSCustomObject]$Value
            }
            elseif ($null -eq $Value) {
                if ($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('NullString')) {
                    Write-Debug "Converting Null value"
                    return $NullString
                }
            }
            else {
                Write-Debug "Converting value to string"
                try {
                    return $Value.ToString()
                }
                catch {
                    Write-Debug "Unable to convert value to string"
                    return $Value.GetType().Name
                }
            }
            return $Value
        }

        function Process-Hashtable {
            param (
                [hashtable]$Hashtable,
                [int]$CurrentDepth
            )

            $keys = @($Hashtable.Keys)  # Create a copy of the keys to avoid modification issues
            foreach ($key in $keys) {
                $Hashtable[$key] = Convert-Value -Value $Hashtable[$key] -CurrentDepth $CurrentDepth
            }
        }

        function Process-Array {
            param (
                [array]$Array,
                [int]$CurrentDepth
            )

            $processedArray = [System.Collections.ArrayList]::new()
            foreach ($item in $Array) {
                $processedArray.Add((Convert-Value -Value $item -CurrentDepth $CurrentDepth))
            }

            # Escape occurrences of the trimmed ArraySeparator in array elements and join
            return ($processedArray.ForEach({
                        if ($_ -is [string]) {
                            $_.Replace($ArraySeparator.Trim(), "\" + $ArraySeparator.Trim())
                        }
                        else {
                            $_
                        }
                    })) -join $ArraySeparator
        }

        function Process-Object {
            param (
                [PSCustomObject]$Obj,
                [int]$CurrentDepth
            )

            if ($Obj -is [System.Collections.IDictionary]) {
                Process-Hashtable -Hashtable $Obj -CurrentDepth $CurrentDepth
                $Obj = [PSCustomObject]$Obj  # Convert hashtable to PSCustomObject
            }
            elseif ($Obj -is [PSObject]) {
                $properties = @($Obj.PSObject.Properties)  # Create a copy of the properties to avoid modification issues
                foreach ($property in $properties) {
                    if ($property.IsSettable) {
                        $Obj.$($property.Name) = Convert-Value -Value $property.Value -CurrentDepth $CurrentDepth
                    }
                }
            }
            elseif ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
                foreach ($item in $Obj) {
                    Process-Object -Obj $item -CurrentDepth ($CurrentDepth + 1)
                }
            }
            elseif ($Obj -is [System.Object]) {
                $Obj = [PSCustomObject]$Obj
            }

            return $Obj
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
            $processedItems = [System.Collections.ArrayList]::new()
            foreach ($item in $InputObject) {
                if ($item -is [PSObject] -or $item -is [System.Collections.IDictionary]) {
                    $processedItems.Add((Process-Object -Obj $item -CurrentDepth 0))
                }
                else {
                    $processedItems.Add($item)
                }
            }
            $InputObject = $processedItems
        }
        elseif ($InputObject -is [PSObject] -or $InputObject -is [System.Collections.IDictionary]) {
            $InputObject = Process-Object -Obj $InputObject -CurrentDepth 0
        }
        elseif ($InputObject -is [System.Object]) {
            $InputObject = [PSCustomObject]$InputObject
        }

        Write-Debug "Final processed input object type: $($InputObject.GetType().Name)"
        Write-Debug "Final processed input object: $($InputObject | Out-String)"

        $InputObject
    }
}

function ConvertTo-PSCustomObject {
    param (
        [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
        [psobject]$InputObject
    )

    process {
        if ($null -eq $InputObject) {
            Write-Debug "Received a null input, returning null."
            return $null
        }
        elseif ($InputObject -is [System.Collections.IDictionary]) {
            Write-Debug "Converting Hashtable to PSCustomObject"
            return [PSCustomObject]$InputObject
        }
        else {
            Write-Debug "Returning input as is"
            return $InputObject
        }
    }
}

try {
    if ($StorageUri) {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $encodingObject = switch ($FileEncoding) {
            "ansi" { [System.Text.Encoding]::Default }
            "ascii" { [System.Text.Encoding]::ASCII }
            "bigendianunicode" { [System.Text.Encoding]::BigEndianUnicode }
            "bigendianutf32" { [System.Text.Encoding]::BigEndianUTF32 }
            "oem" { [System.Text.Encoding]::Default }
            "unicode" { [System.Text.Encoding]::Unicode }
            "utf7" { [System.Text.Encoding]::UTF7 }
            "utf8" { New-Object System.Text.UTF8Encoding($false) }
            "utf8BOM" { New-Object System.Text.UTF8Encoding($true) }
            "utf8NoBOM" { New-Object System.Text.UTF8Encoding($false) }
            "utf32" { [System.Text.Encoding]::UTF32 }
            default { New-Object System.Text.UTF8Encoding($true) }
        }
        $streamWriter = New-Object System.IO.StreamWriter($tempFile, $false, $encodingObject)
        $streamWriter.NewLine = $FileNewLine
        try {
            if ($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('NullValue')) {
                $InputObject | ConvertTo-PSCustomObject | ConvertTo-CsvFriendlyObject -TrueString $BooleanTrueValue -FalseString $BooleanFalseValue -NullString $NullValue | ConvertTo-Csv @params | & { process { $streamWriter.WriteLine($_) } }
            }
            else {
                $InputObject | ConvertTo-PSCustomObject | ConvertTo-CsvFriendlyObject -TrueString $BooleanTrueValue -FalseString $BooleanFalseValue | ConvertTo-Csv @params | & { process { $streamWriter.WriteLine($_) } }
            }

            if (
                $null -ne $Metadata -and
                ($Metadata | Get-Member -MemberType NoteProperty | Measure-Object).Count -gt 0
            ) {
                $streamWriter.Close()
                $missingColumnsString = $params.Delimiter * (Get-Content $tempFile -TotalCount 1 | & { process { $_ | ConvertFrom-Csv -Header $_.Split($params.Delimiter) -Delimiter $params.Delimiter } } | Get-Member -MemberType NoteProperty | Measure-Object).Count
                $streamWriter = New-Object System.IO.StreamWriter($tempFile, $true)
                $streamWriter.WriteLine('')
                $Metadata.PSObject.properties | & { process {
                        $key = "# $($_.Name)"
                        $val = $_.Value | & {
                            process {
                                if ($_ -is [string]) {
                                    $_
                                }
                                elseif ($_ -is [array]) {
                                    $_ -join ', '
                                }
                                elseif ($_ -is [DateTime]) {
                                    [DateTime]::Parse($_).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                                }
                                elseif ($_.PSObject.Methods.Name -contains 'ToString') {
                                    $_.ToString()
                                }
                                else {
                                    return
                                }
                            }
                        }

                        if (
                            $null -eq $params.UseQuotes -or
                            $params.UseQuotes -eq 'Always' -or
                            (
                                $params.UseQuotes -eq 'AsNeeded' -and
                                (
                                    $key -like "*$($params.Delimiter)*" -or
                                    $key -like '*"*' -or
                                    $key -match "`n|`r"
                                )
                            )
                        ) {
                            $key = "`"$($key -replace '`"', '`"`"')`""
                        }

                        if (
                            -not [string]::IsNullOrEmpty($val) -and
                            (
                                $null -eq $params.UseQuotes -or
                                $params.UseQuotes -eq 'Always' -or
                                (
                                    $params.UseQuotes -eq 'AsNeeded' -and
                                    (
                                        $val -like "*$($params.Delimiter)*" -or
                                        $val -like '*"*' -or
                                        $val -match "`n|`r"
                                    )
                                )
                            )
                        ) {
                            $val = "`"$($val -replace '`"', '`"`"')`""
                        }

                        $streamWriter.WriteLine("$key$($params.Delimiter)$val$missingColumnsString")
                    }
                }
            }
        }
        finally {
            $streamWriter.Close()
        }

        $uri = [System.Uri] $StorageUri
        $sasToken = if ($uri.Query) { $uri.Query.TrimStart('?') } else { $null }
        $hostParts = if ($uri.Host) { $uri.Host.Split('.') } else { throw 'Invalid storage URI' }
        $storageAccountName = $hostParts[0]
        $storageType = $hostParts[1]
        $pathParts = if ($uri.AbsolutePath) { $uri.AbsolutePath.Split('/') } else { throw 'Invalid storage URI' }
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
            if ($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('NullValue')) {
                $csv = $InputObject | ConvertTo-PSCustomObject | ConvertTo-CsvFriendlyObject -TrueString $BooleanTrueValue -FalseString $BooleanFalseValue -NullString $NullValue | ConvertTo-Csv @params
            }
            else {
                $csv = $InputObject | ConvertTo-PSCustomObject | ConvertTo-CsvFriendlyObject -TrueString $BooleanTrueValue -FalseString $BooleanFalseValue | ConvertTo-Csv @params
            }
            $csv

            if (
                $null -ne $Metadata -and
                ($Metadata | Get-Member -MemberType NoteProperty | Measure-Object).Count -gt 0
            ) {
                ''
                $missingColumnsString = $params.Delimiter * ($csv | Select-Object -First 1 | & { process { $_ | ConvertFrom-Csv -Header $_.Split($params.Delimiter) -Delimiter $params.Delimiter } } | Get-Member -MemberType NoteProperty | Measure-Object).Count
                $Metadata.PSObject.properties | & { process {
                        $key = "# $($_.Name)"
                        $val = $_.Value | & {
                            process {
                                if ($_ -is [string]) {
                                    $_
                                }
                                elseif ($_ -is [array]) {
                                    $_ -join ', '
                                }
                                elseif ($_ -is [DateTime]) {
                                    [DateTime]::Parse($_).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                                }
                                elseif ($_.PSObject.Methods.Name -contains 'ToString') {
                                    $_.ToString()
                                }
                                else {
                                    return
                                }
                            }
                        }

                        if (
                            $null -eq $params.UseQuotes -or
                            $params.UseQuotes -eq 'Always' -or
                            (
                                $params.UseQuotes -eq 'AsNeeded' -and
                                (
                                    $key -like "*$($params.Delimiter)*" -or
                                    $key -like '*"*' -or
                                    $key -match "`n|`r"
                                )
                            )
                        ) {
                            $key = "`"$($key -replace '`"', '`"`"')`""
                        }

                        if (
                            -not [string]::IsNullOrEmpty($val) -and
                            (
                                $null -eq $params.UseQuotes -or
                                $params.UseQuotes -eq 'Always' -or
                                (
                                    $params.UseQuotes -eq 'AsNeeded' -and
                                    (
                                        $val -like "*$($params.Delimiter)*" -or
                                        $val -like '*"*' -or
                                        $val -match "`n|`r"
                                    )
                                )
                            )
                        ) {
                            $val = "`"$($val -replace '`"', '`"`"')`""
                        }

                        "$key$($params.Delimiter)$val$missingColumnsString"
                    }
                }
            }
        )
    }
}
catch {
    throw $_
}
finally {
    if ($tempFile) { Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue }
}

Get-Variable | Where-Object { $StartupVariables -notcontains $_.Name } | & { process { Remove-Variable -Scope 0 -Name $_.Name -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -Verbose:$false -Debug:$false -Confirm:$false -WhatIf:$false } }        # Delete variables created in this script to free up memory for tiny Azure Automation sandbox
if (-Not $Global:hasRunBefore.ContainsKey((Get-Item $PSCommandPath).Name)) {
    $Global:hasRunBefore[(Get-Item $PSCommandPath).Name] = $true
    Write-Verbose "-----END of $((Get-Item $PSCommandPath).Name) ---"
}
