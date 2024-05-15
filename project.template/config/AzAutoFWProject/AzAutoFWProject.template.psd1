@{
    ModuleVersion = '1.3.0'     # This is the version of the framework you want to use. Only used if GitReference is set to 'ModuleVersion'.
    Author        = 'Azure Automation Common Runbook Framework'
    Description   = 'Main configuration file child project using the Azure Automation Common Runbook Framework.'
    PrivateData   = @{
        # GitReference can be one of the following:
        # 1. 'ModuleVersion' (see value above in the ModuleVersion key of this file)
        # 2. 'LatestRelease' (ignores ModuleVersion but detects latest release version automatically as it is released)
        # 3. 'latest' (will go to the latest commit of the branch to give you the latest code, but may be unstable)
        # 4. A Git commit hash or branch name (if you know what you're doing and want to pin to a specific commit or branch)
        GitReference                 = 'ModuleVersion'

        # GitRepositoryUrl must be a valid Git repository URL. You likely don't want to change this unless you're forking the framework.
        GitRepositoryUrl             = 'https://github.com/workoho/AzAuto-Common-Runbook-FW.git'

        # Files belonging to the framework are usually symlinked to the child project to keep them up to date.
        # On Windows, this requires SeCreateSymbolicLinkPrivilege to be enabled, or manually running the Update-AzAutoFWProjectRunbooks.ps1 script as an administrator.
        # If you would like to enforce using symlinks on Windows in any case, set this to $true.
        EnforceSymlink               = $false

        # In rare cases, common runbooks may be copied instead of using symbolic links.
        # If you set $EnforceSymlink to $true but still would like to copy the runbooks, set this to $true.
        CopyRunbooks                 = $false

        # If you enabled CopyRunbooks, or Windows is not enabled for symlinks, common runbooks are automatically updated when the
        # Update-AzAutoFWProjectRunbooks.ps1 script is run.
        # In case you want to update them manually, you can set this to $true. That way, you may keep changes you made to the runbooks.
        # Please note that you will need to manually keep track of updates to the common runbooks and apply them yourself.
        # We recommend that you instead write your own runbooks that call the common runbooks, so that you can update the common runbooks
        # automatically.
        UpdateRunbooksManually       = $false

        # The following Automation Variables are used by runbooks of the automation project.
        # SECURITY NOTE: Do _NOT_ set any critical values here. Use the AzAutoFWProject.local.psd1 file instead if needed.
        AutomationVariable           = @(
            # # EXAMPLE:
            # @{
            #     Name  = 'AV_ProjectName_VariableName'
            #     Value = [String]''
            # }
        )

        # Configure your Azure Automation Runtime Environments and packages to be installed.
        AutomationRuntimeEnvironment = @{


            # This is the system-generated Runtime Environment name for PowerShell 5.1.
            'PowerShell-5.1'   = @{
                Runtime  = @{
                    Language = 'PowerShell'
                    Version  = '5.1'
                }

                Packages = @(
                    # Due to a bug in Azure Automation Runtime Environments, we must install at least
                    # one package via the old method into the default environment
                    # (which is not writeable via GUI anymore, but old API's still make it accessibile for us)
                    @{
                        Name    = 'Microsoft.Graph.Authentication'
                        Version = '2.19.0'
                    }
                )
            }

            # # This is the system-generated Runtime Environment name for PowerShell 7.2.
            # 'PowerShell-7.2'          = @{
            #     Description = ''
            #     Runtime     = @{
            #         Language = 'PowerShell'
            #         Version  = '7.2'
            #     }

            #     Packages    = @(
            #     )
            # }

            # This is a custom Runtime Environment name for PowerShell 5.1 with Az 8.0.0 and additional modules.
            # This is currently required as Az 11.2.0 does not work correctly in PowerShell 5.1 in Azure Automation.
            'AzAutoProject-V1' = @{
                Description = 'Runtime environment for Cloud Administrator Tiering Automation Runbooks with Az 8.0.0 and additional modules.'
                Runtime     = @{
                    Language = 'PowerShell'
                    Version  = '5.1'    # We use PowerShell 5.1 here, as it is the only version that supports child runbooks at the time of writing.
                }

                Packages    = @(
                    @{
                        # This is the defaultPackage and must always be set.
                        Name      = 'Az'
                        Version   = '8.0.0'     # Note that version 11.2.0 currently does not work correctly in PowerShell 5.1 in Azure Automation
                        IsDefault = $true
                    }
                    @{
                        Name    = 'Microsoft.Graph.Authentication'
                        Version = '2.19.0'
                    }
                    @{
                        Name    = 'Microsoft.Graph.Identity.SignIns'
                        Version = '2.19.0'
                    }
                    @{
                        Name    = 'Microsoft.Graph.Applications'
                        Version = '2.19.0'
                    }
                )
            }
        }

        # Configure your Azure Automation Runbooks to be uploaded.
        AutomationRunbook            = @{
            DefaultRuntimeEnvironment = @{
                PowerShell = 'AzAutoProject-V1'
            }
            Runbooks                  = @(
                # # EXAMPLE:
                # @{
                #     Name               = 'MyRunbook.ps1'
                #     RuntimeEnvironment = 'PowerShell-5.1'   # In case you want to use a different Runtime Environment
                # }
            )
        }

        # Configure Managed Identities for the Azure Automation Account.
        ManagedIdentity              = @(

            # For security reasons, you may also move this to the AzAutoFWProject.local.psd1 file.
            @{
                Type           = 'SystemAssigned'  # 'SystemAssigned' or 'UserAssigned'

                # Azure role assignments for the Managed Identity.
                AzureRoles     = @{

                    # Scope 'self' means the Automation Account itself.
                    'self' = @(
                        @{
                            DisplayName      = 'Reader'                                # 'Reader' is the minimum required role for the Automation Account
                            RoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'  # RoleDefinitionId is optional, but recommended to ensure the correct role is assigned.
                            Justification    = 'Let the Managed Identity read its own properties and access its own resources.'
                        }
                        # @{
                        #     DisplayName      = 'Automation Operator'                   # 'Automation Operator' is required to read sensitive information, like encrypted Automation Variables
                        #     RoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'  # RoleDefinitionId is optional, but recommended to ensure the correct role is assigned.
                        #     Justification    = 'Let the Managed Identity read sensitive information, like encrypted Automation Variables.'
                        # }
                    )
                }

                # # Directory role assignments for the Managed Identity.
                # DirectoryRoles = @(
                #     @{
                #         DisplayName    = 'Reports Reader'
                #         RoleTemplateId = '4a5d8f65-41da-4de4-8968-e035b65339cf'                 # RoleTemplateId is optional, but recommended to ensure the correct role is assigned.
                #         Justification  = 'Read Sign-in logs for User Account Administration (e.g. last login date, etc.)'
                #     }

                #     # User Account Administration
                #     @{
                #         DisplayName    = 'Exchange Recipient Administrator'
                #         RoleTemplateId = '31392ffb-586c-42d1-9346-e59415a2cc4e'                 # RoleTemplateId is optional, but recommended to ensure the correct role is assigned.
                #         Justification  = 'Document some justification why this role is needed for the Managed Identity.'
                #     }
                #     @{
                #         DisplayName    = 'Groups Administrator'
                #         RoleTemplateId = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'                 # RoleTemplateId is optional, but recommended to ensure the correct role is assigned.
                #         # AdministrativeUnitReferenceTo = 'AdministrativeUnit.Example'          # reference to the Administrative Unit defined below to add the role
                #         Justification  = 'Document some justification why this role is needed for the Managed Identity.'
                #     }
                #     @{
                #         DisplayName    = 'License Administrator'
                #         RoleTemplateId = '4d6ac14f-3453-41d0-bef9-a3e0c569773a'                 # RoleTemplateId is optional, but recommended to ensure the correct role is assigned.
                #         # AdministrativeUnitReferenceTo = 'AdministrativeUnit.Example'          # reference to the Administrative Unit defined below to add the role
                #         Justification  = 'Document some justification why this role is needed for the Managed Identity.'
                #     }
                #     @{
                #         DisplayName    = 'User Administrator'
                #         RoleTemplateId = 'fe930be7-5e62-47db-91af-98c3a49a38b1'                 # RoleTemplateId is optional, but recommended to ensure the correct role is assigned.
                #         # AdministrativeUnitReferenceTo = 'AdministrativeUnit.Example'          # reference to the Administrative Unit defined below to add the role
                #         Justification  = 'Document some justification why this role is needed for the Managed Identity.'
                #     }
                # )

                # # App registrations and their permissions for the Managed Identity.
                # AppPermissions = @(
                #
                #     @{
                #         DisplayName = 'Microsoft Graph'
                #         AppId       = '00000003-0000-0000-c000-000000000000'   # AppId is optional, but recommended to ensure the roles are assigned to the correct app.
                #
                #         # Note: Required AppRoles depend on your runbooks and modules.
                #         AppRoles    = @(
                #             'Directory.Read.All'
                #             'Group.Read.All'
                #             'Group.ReadWrite.All'
                #             'Mail.Send'
                #             'User.Read.All'
                #             'User.ReadWrite.All'
                #         )
                #
                #         # # Note: Required Oauth2PermissionScopes depend on your runbooks and modules.
                #         # Oauth2PermissionScopes = @{
                #         #     Admin = @(
                #         #         'offline_access'
                #         #         'openid'
                #         #         'profile'
                #         #     )
                #         #     '<User-ObjectId>' = @(
                #         #     )
                #         # }
                #     }
                #
                #     @{
                #         DisplayName = 'Office 365 Exchange Online'
                #         AppId       = '00000002-0000-0ff1-ce00-000000000000'   # AppId is optional, but recommended to ensure the roles are assigned to the correct app.
                #
                #         # Note: Required AppRoles depend on your runbooks and modules.
                #         AppRoles    = @(
                #             'Exchange.ManageAsApp'  # Allow using EXO PowerShell V3 module
                #         )
                #
                #         # # Note: Required Oauth2PermissionScopes depend on your runbooks and modules.
                #         # Oauth2PermissionScopes = @{
                #         #     Admin = @(
                #         #     )
                #         #     '<User-ObjectId>' = @(
                #         #     )
                #         # }
                #     }
                # )
            }
        )

        # Administrative Units you want to create in your Entra ID tenant.
        AdministrativeUnit           = @{
            # 'Example' = @{
            #     DisplayName                  = 'CORP-Example-AdminUnit'
            #     Id                           = '' # After creation, you can set the ID here for future reference to be independent of DisplayName changes.
            #     Description                  = 'This is an example for an administrative unit.'
            # }

            # 'RestrictedManagementExample' = @{
            #     DisplayName                  = 'CORP-Example-RestrictedAdminUnit'
            #     Id                           = '' # After creation, you can set the ID here for future reference to be independent of DisplayName changes.
            #     Description                  = 'This is an example for a restricted management administrative unit.'
            #     IsMemberManagementRestricted = $true
            #     Visibility                   = 'HiddenMembership'

            #     # Scopable directory roles that shall be assigned to the current user during initial creation.
            #     # This is essential if the admin unit is management-restricted and groups are created in it.
            #     # This is required also for users with 'Global Administrator' or 'Privileged Role Administrator' role assignments.
            #     #
            #     # Note that after the initial creation, you can manually assign additional roles to the user or delegate the role assignment
            #     # to other users (requires either the 'Privileged Role Administrator' or 'Global Administrator' role).
            #     InitialRoleAssignment        = @(
            #         @{
            #             DisplayName    = 'Groups Administrator'
            #             RoleTemplateId = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'     # RoleTemplateId is optional, but recommended to ensure the correct role is assigned.
            #             AssignmentType = 'Eligible'                                 # 'Eligible' or 'Active'
            #             Duration       = 'P3M'                                      # Duration is optional, but recommended to ensure the role assignment is temporary.
            #         }
            #         @{
            #             DisplayName    = 'License Administrator'
            #             RoleTemplateId = '4d6ac14f-3453-41d0-bef9-a3e0c569773a'
            #             AssignmentType = 'Eligible'
            #             Duration       = 'P3M'
            #         }
            #     )
            # }
        }

        # Groups you want to create in your Entra ID tenant.
        Group                        = @{
            # 'Example'              = @{
            #     DisplayName     = 'CORP-Example-Group'
            #     Id              = '' # After creation, you can set the ID here for future reference to be independent of DisplayName changes.
            #     Description     = 'This is an example for a simple security group.'
            #     SecurityEnabled = $true
            #     MailEnabled     = $false
            # }

            # 'ExampleWithRoleAssignable' = @{
            #     DisplayName        = 'CORP-Example-RoleAssignable-Group'
            #     Id                 = '' # After creation, you can set the ID here for future reference to be independent of DisplayName changes.
            #     Description        = 'This is an example for a role-assignable security group.'
            #     SecurityEnabled    = $true
            #     MailEnabled        = $false
            #     IsAssignableToRole = $true
            # }

            # 'ExampleWithAdminUnit' = @{
            #     AdministrativeUnitReferenceTo = 'AdministrativeUnit.RestrictedManagementExample'   # reference to the Administrative Unit defined above to add the group
            #     DisplayName                   = 'CORP-Sensitive-Group'
            #     Id                            = '' # After creation, you can set the ID here for future reference to be independent of DisplayName changes.
            #     Description                   = 'This is an example for a sensitive security group that is protected by a management-restricted administrative unit.'
            #     SecurityEnabled               = $true
            #     MailEnabled                   = $false
            # }

            # 'ExampleWithDynamicLicensing' = @{
            #     DisplayName                   = 'CORP-User-Licensing-Group'
            #     Id                            = '' # After creation, you can set the ID here for future reference to be independent of DisplayName changes.
            #     Description                   = 'This is an example for a dynamic security group that is used for licensing users.'
            #     SecurityEnabled               = $true
            #     MailEnabled                   = $false
            #     GroupTypes                    = @(
            #         'DynamicMembership'
            #     )
            #     MembershipRule                = @'
            #         (user.userType -eq "Member") and
            #         (user.onPremisesSecurityIdentifier -eq null) and
            #         (user.userPrincipalName -notMatch "^.+@.+\.onmicrosoft\.com$")
            # '@ # IMPORTANT: Make sure that '@ has no leading spaces in this line!
            #
            #     MembershipRuleProcessingState = 'Off'     # Change to 'On' to enable the membership rule.
            #
            #     # Licenses that shall be assigned to the group during initial creation.
            #     # Note that after the initial creation, you can manually change licenses of the group.
            #     # (requires the 'Groups Administrator' and 'License Administrator' roles).
            #     InitialLicenseAssignment      = @(
            #         @{
            #             SkuPartNumber = 'EXCHANGEDESKLESS'
            #             # SkuId = '00000000-0000-0000-0000-000000000000'    # Replace with the SKU ID of the license you want to assign. Otherwise, it will be determined automatically from the SkuPartNumber.
            #             EnabledPlans  = @( # If you want to enable only specific service plans, add their full or partial name here. Otherwise, all service plans of the license will be enabled.
            #                 'EXCHANGE'
            #             )
            #             DisabledPlans = @( # If you want to disable specific service plans, add their full or partial name here. Otherwise, all service plans of the license will be enabled.
            #             )
            #         }
            #     )
            # }
        }
    }
}
