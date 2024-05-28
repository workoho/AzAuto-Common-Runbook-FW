<#PSScriptInfo
.VERSION 1.0.0
.GUID 6d840940-e0fe-4de7-80ad-c6d3d495d695
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
    Version 1.0.0 (2024-02-28)
    - Initial release.
#>

<#
.SYNOPSIS
    Find a user in Microsoft Graph including soft-deleted users.

.DESCRIPTION
    This script is used to find a user in Microsoft Graph including soft-deleted users.
    The script will expand the manager property by default, but you may specify which properties to return.

    In case the user cannot be found anymore, the script will return an empty object.
    The script will only throw an exception if any other error occurs.
    This way, one can be sure that if no user was found, it is not due to an error, but because the user does not exist.

.PARAMETER UserId
    The user ID or user principal name of the user to search for.
    May be an array, or a comma-separated string of object IDs or user principal names.

.PARAMETER Property
    The properties to return for the user.
    If not specified, the following properties will be returned:
    - displayName
    - userPrincipalName
    - onPremisesSamAccountName
    - id
    - accountEnabled
    - createdDateTime
    - deletedDateTime
    - mail
    - companyName
    - department
    - streetAddress
    - city
    - postalCode
    - state
    - country
    - signInActivity
    - onPremisesExtensionAttributes

    Note that the signInActivity property is only available for users with an Entra ID Premium P1 license, and requires at least Reports Reader role when working with delegated permissions.
    You may use the Common_0003__Confirm-MgDirectoryRoleActiveAssignment.ps1 script in your runbook to check if the role is assigned.

.PARAMETER ManagerProperty
    The properties to return for the manager.
    If not specified, the following properties will be returned:
    - displayName
    - userPrincipalName
    - id
    - accountEnabled
    - mail

.NOTES
    This script is intended to be used as a child runbook in other runbooks and can not be run directly in Azure Automation for security reasons.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [array] $UserId,
    [array] $Property,
    [array] $ManagerProperty
)

if (-Not $PSCommandPath) { Write-Error 'This runbook is used by other runbooks and must not be run directly.' -ErrorAction Stop; exit }

@($UserId) | & { process { ($_ -replace '\s', '').Split(',') } } | & {
    process {
        if (
            $_ -eq $null -or
            $_ -eq '00000000-0000-0000-0000-000000000000'
        ) {
            Throw 'User ID must not be null or empty.'
        }

        $filter = if ($_ -match '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$') {
            "id eq '$_'"
        }
        else {
            "userPrincipalName eq '$([System.Web.HttpUtility]::UrlEncode($_))'"
        }

        if ($null -eq $Property) {
            $Property = @(
                'displayName'
                'userPrincipalName'
                'onPremisesSamAccountName'
                'id'
                'accountEnabled'
                'createdDateTime'
                'deletedDateTime'
                'mail'
                'companyName'
                'department'
                'streetAddress'
                'city'
                'postalCode'
                'state'
                'country'
                'signInActivity'
                'onPremisesExtensionAttributes'
            ) -join ','
        }
        else {
            $Property = $Property -join ','
        }

        if ($null -eq $ManagerProperty) {
            $ManagerProperty = @(
                'displayName'
                'userPrincipalName'
                'id'
                'accountEnabled'
                'mail'
            ) -join ','
        }
        else {
            $ManagerProperty = $ManagerProperty -join ','
        }

        $params = @{
            Method      = 'POST'
            Uri         = 'https://graph.microsoft.com/v1.0/$batch'
            Body        = @{
                requests = [System.Collections.ArrayList] @(
                    # First, search in existing users. We're using $filter here because fetching the user by Id would return an error if the user is soft-deleted or not existing.
                    @{
                        id      = 1
                        method  = 'GET'
                        headers = @{
                            'Cache-Control' = 'no-cache'
                        }
                        url     = 'users?$filter={0}&$select={1}&$expand=manager($select={2})' -f $filter, $Property, $ManagerProperty
                    }

                    # If not found, search in deleted items. We're using $filter here because fetching the user by Id would return an error if the user is not existing.
                    @{
                        id      = 2
                        method  = 'GET'
                        headers = @{
                            'Cache-Control' = 'no-cache'
                        }
                        url     = 'directory/deletedItems/microsoft.graph.user?$filter={0}&$select={1}&$expand=manager($select={2})' -f $filter, $Property, $ManagerProperty
                    }
                )
            }
            OutputType  = 'PSObject'
            ErrorAction = 'Stop'
            Verbose     = $false
            Debug       = $false
        }

        $retryAfter = $null

        try {
            $response = ./Common_0002__Invoke-MgGraphRequest.ps1 $params
        }
        catch {
            Throw $_
        }

        while ($response) {
            $response.responses | Sort-Object -Property Id | & {
                process {
                    if ($_.status -eq 429) {
                        $retryAfter = if (-not $retryAfter -or $retryAfter -gt $_.Headers.'Retry-After') { [int] $_.Headers.'Retry-After' }
                    }
                    elseif ($_.status -eq 200 -or $_.status -eq 404) {
                        $responseId = $_.Id

                        if ($null -ne $_.body.value) {
                            @($_.body.value)[0]
                        }

                        $requestIndexId = $params.Body.requests.IndexOf(($params.Body.requests | Where-Object { $_.id -eq $responseId }))
                        $params.Body.requests.RemoveAt($requestIndexId)
                    }
                    else {
                        Throw "Error $($_.status): [$($_.body.error.code)] $($_.body.error.message)"
                    }
                }
            }

            if ($params.Body.requests.Count -gt 0) {
                if ($retryAfter) {
                    Write-Verbose "[Find-MgUserWithSoftDeleted]: - Rate limit exceeded, waiting for $retryAfter seconds..."
                    Start-Sleep -Seconds $retryAfter
                }
                try {
                    $response = ./Common_0002__Invoke-MgGraphRequest.ps1 $params
                }
                catch {
                    Throw $_
                }
            }
            else {
                $response = $null
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
            }
        }
    }
}
