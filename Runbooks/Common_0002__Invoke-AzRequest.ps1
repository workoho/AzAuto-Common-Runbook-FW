<#PSScriptInfo
.VERSION 1.0.0
.GUID a1ed793d-795e-4f1e-a986-3e84083e0829
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
    Invoke an Azure REST API request using Invoke-RestMethod.
    Similar to Invoke-MgGraphRequest, but for Azure REST API requests.

.DESCRIPTION
    This script is used to invoke an Azure REST API request using the Invoke-RestMethod cmdlet for requests where no specific Azure Az PowerShell cmdlet is available.
    It provides a simplified way to make Azure REST API calls by handling authentication, constructing the request URL, and handling retries for rate limiting or connection timeouts.

.PARAMETER SubscriptionId
    The ID of the Azure subscription to use. If not specified, the current subscription from the AzContext is used.

.PARAMETER ResourceGroupName
    The name of the resource group containing the resource.

.PARAMETER Provider
    The provider namespace of the resource.

.PARAMETER ResourceType
    The type of the resource.

.PARAMETER ResourceName
    The name of the resource.

.PARAMETER SubResourceUri
    The URI of a sub-resource, if applicable.

.PARAMETER ApiVersion
    The version of the Azure REST API to use.

.PARAMETER Method
    The HTTP method to use for the request. If not specified, 'Get' is used.

.PARAMETER Body
    The request body, if applicable.

.EXAMPLE
    PS> $response = Common_0002__Invoke-AzRequest.ps1 -ResourceGroupName "myResourceGroup" -Provider "Microsoft.Compute" -ResourceType "virtualMachines" -ResourceName "myVM" -ApiVersion "2021-04-01" -Method "Get"

    This example invokes a GET request to retrieve information about a virtual machine named "myVM" in the "myResourceGroup" resource group.

.OUTPUTS
    The response from the Azure REST API request.

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [string]$SubscriptionId = (Get-AzContext).Subscription.Id,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Provider,

    [Parameter(Mandatory = $true)]
    [string]$ResourceType,

    [Parameter(Mandatory = $true)]
    [string]$ResourceName,

    [string]$SubResourceUri,

    [Parameter(Mandatory = $true)]
    [string]$ApiVersion,

    [string]$Method,
    [hashtable]$Body
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }

$ResourceUrl = "https://management.azure.com"
$headers = @{
    Authorization = "Bearer $((Get-AzAccessToken -ResourceUrl $ResourceUrl).Token)"
}
if ($Body) {
    $headers.Add('Content-Type', 'application/json')
}

$uri = ([System.Text.StringBuilder]::new()).Append($ResourceUrl)
$uri.Append("/subscriptions/$SubscriptionId")
$uri.Append("/resourceGroups/$ResourceGroupName")
$uri.Append("/providers/$Provider")
$uri.Append("/$ResourceType")
$uri.Append("/$ResourceName")
if (-not [string]::IsNullOrEmpty($SubResourceUri)) {
    if ($SubResourceUri.StartsWith('/')) {
        $uri.Append($SubResourceUri)
    }
    else {
        $uri.Append("/$SubResourceUri")
    }
}

if ($uri.ToString().Contains('?')) {
    if (-not $uri.ToString().Contains('api-version=')) {
        $uri.Append("&api-version=$ApiVersion")
    }
}
else {
    $uri.Append("?api-version=$ApiVersion")
}

$maxRetries = 3
$retryCount = 0
$response = $null

do {
    try {
        $params = @{
            Method     = $(
                if ($Method) {
                    $Method
                }
                else {
                    'Get'
                }
            )
            Uri        = $uri.ToString()
            Headers    = $headers
            TimeoutSec = 30
        }
        if ($Body) {
            $params.Add('Body', ($Body | ConvertTo-Json -Depth 5))
        }

        $debugHeaders = $params.Headers.Clone()
        if ($debugHeaders.ContainsKey('Authorization')) { $debugHeaders['Authorization'] = '***' }
        $maxKeyLength = ($debugHeaders.Keys | Measure-Object -Maximum Length).Maximum
        Write-Debug @"
============================ HTTP REQUEST ============================

HTTP Method:
$($params.Method)

Absolute Uri:
$($params.Uri)

Headers:
$(
    if ($null -ne $debugHeaders) {
        foreach ($header in $debugHeaders.GetEnumerator()) {
            "{0,-$maxKeyLength} : {1}" -f $header.Name, $header.Value
        }
    }
)

Body:
$($params.Body)
"@

        $response = Invoke-RestMethod @params

        Write-Debug @"
============================ HTTP RESPONSE ============================

Body:
$($response | ConvertTo-Json -Depth 5)
"@
        break
    }
    catch {
        if (
            $_.Exception.Response.StatusCode -eq 'TooManyRequests' -and
            $retryCount -lt $maxRetries
        ) {
            $retryCount++
            Start-Sleep -Seconds (2 * $retryCount) # Wait before retrying
        }
        elseif (
            $_.Exception -is [System.Net.WebException] -and
            $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout -and
            $retryCount -lt $maxRetries
        ) {
            # Handle connection timeout
            $retryCount++
            Write-Verbose "The request timed out. Retrying... ($retryCount/$maxRetries)"
        }
        elseif (
            $_.Exception.Response.StatusCode -ge 400 -and
            $_.Exception.Response.StatusCode -lt 600
        ) {
            # Handle 4xx and 5xx status codes
            Write-Error "The server returned an error: $($_.Exception.Response.StatusCode): $($_.ErrorDetails.Message)"
            break
        }
        else {
            Write-Error "An error occurred: $($_.Exception.Message)"
            break
        }
    }
} while ($true)

return $response
