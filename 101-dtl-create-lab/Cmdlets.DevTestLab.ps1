<##################################################################################################

    Usage Example
    =============

    Login-AzureRmAccount
    Import-Module .\Cmdlets.DevTestLab.ps1
    Get-AzureDtlLab   


    Help / Documentation
    ====================
    - To view a cmdlet's help description: Get-help "cmdlet-name" -Detailed
    - To view a cmdlet's usage example: Get-help "cmdlet-name" -Examples


    Pre-Requisites
    ==============
    - Please ensure that the powershell execution policy is set to unrestricted or bypass.
    - Please ensure that the latest version of Azure Powershell in installed on the machine.


    Known Issues
    ============
    - The following regression in the Azure PS cmdlets impacts us currently. 
      - https://github.com/Azure/azure-powershell/issues/1259

##################################################################################################>

#
# Configurations
#

# Resource types exposed by the DevTestLab provider.
$LabResourceType = "microsoft.devtestlab/labs"
$EnvironmentResourceType = "microsoft.devtestlab/environments"
$VMTemplateResourceType = "microsoft.devtestlab/labs/vmtemplates"

# Other resource types
$StorageAccountResourceType = "microsoft.storage/storageAccounts"

# The API version required to query DTL resources
$RequiredApiVersion = "2015-05-21-preview"

##################################################################################################

#
# Private helper methods
#

function GetLabFromVM_Private
{
    Param(
        [ValidateNotNull()]
        # An existing VM (please use the Get-AzureDtlVirtualMachine cmdlet to get this VM object).
        $VM
    )

    $vm = GetResourceWithProperties_Private -Resource $VM

    $lab = Get-AzureRmResource | Where-Object {
        $_.ResourceType -eq $LabResourceType -and 
        $_.ResourceId -eq $vm.Properties.LabId
    }

    if ($null -eq $lab)
    {
        throw $("Unable to detect lab for VM '" + $VM.ResourceName + "'")
    }
}

function GetDefaultStorageAccountContextFromLab_Private
{
    Param(
        [ValidateNotNull()]
        # An existing Lab (please use the Get-AzureDtlLab cmdlet to get this lab object).
        $Lab
    )

    $lab = GetResourceWithProperties_Private -Resource $Lab

    # Get the default storage account associated with the lab.
    $labStorageAccount = Get-AzureRmResource | Where-Object {
        $_.ResourceType -eq $StorageAccountResourceType -and 
        $_.ResourceId -eq $lab.Properties.DefaultStorageAccount
    }

    if ($null -eq $labStorageAccount)
    {
        throw $("Unable to extract the default storage account for lab '" + $Lab.Name + "'")
    }

    # Extracting the lab's storage account key
    $labStorageAccountKey = Get-AzureRmStorageAccountKey -ResourceGroupName $labStorageAccount.ResourceGroupName -Name $labStorageAccount.ResourceName

    if ($null -eq $labStorageAccountKey)
    {
        throw $("Unable to extract the storage account key for lab '" + $Lab.Name + "'")
    }

    # Create a new storage context using the lab's default storage account .
    $labStorageAccountContext = New-AzureStorageContext -StorageAccountName $labStorageAccount.ResourceName -StorageAccountKey $labStorageAccountKey.Key1

    if ($null -eq $labStorageAccountContext)
    {
        throw $("Unable to create a new storage account context for storage account '" + $labStorageAccount.ResourceName + "'")
    }

    return $labStorageAccountContext
}

function GetResourceWithProperties_Private
{
    Param(
        [ValidateNotNull()]
        # ResourceId of an existing Azure RM resource.
        $Resource
    )

    if ($null -eq $Resource.Properties)
    {
        Get-AzureRmResource -ExpandProperties -ResourceId $Resource.ResourceId -ApiVersion $RequiredApiVersion
    }
    else
    {
        return $Resource
    }
}

function CreateNewResourceGroup_Private
{
    Param(
        [ValidateNotNullOrEmpty()]
        [string]
        # Seed/Prefix for the new resource group name to be generated.
        $ResourceGroupSeedPrefixName,

        [ValidateNotNullOrEmpty()]
        [string]
        # Location where the new resource group will be generated.
        $Location
    )

    # Using the seed/prefix, we'll generate a unique random name for the resource group.
    # We'll then check if there is an existing resource group with the same name.
    do
    {
        # NOTE: Unfortunately the Get-AzureRmResourceGroup cmdlet throws a terminating error 
        # if the specified resource group name does not exist. So we'll use a try/catch block.
        try
        {
            $randomRGName = $($ResourceGroupSeedPrefixName + (Get-Random).ToString())
            $randomRG = Get-AzureRmResourceGroup -Name $randomRGName
        }
        catch [ArgumentException]
        {
            $randomRG = $null
        }
    }
    until ($null -eq $randomRG)

    return (New-AzureRmResourceGroup -Name $randomRGName -Location $Location)
}

function IsFileRemote_Private
{
    Param(
        [ValidateNotNullOrEmpty()] 
        [string] 
        #  The full path or Uri of a file.
        $FilePathOrUri
    )

    # Poor man's check for UNC paths
    if ($FilePathOrUri.StartsWith("\\"))
    {
        return $true
    }

    # Poor man's check for Uris.
    if ($FilePathOrUri.StartsWith("https://"))
    {
        return $true
    }

    # A more formal check for UNC paths
    $uri = New-Object -TypeName System.Uri -ArgumentList @($FilePathOrUri) 
    if (($null -ne $uri) -and ($true -eq $uri.IsUnc))
    {
        return $true
    }

    # Check for network-mapped drives
    $driveInfo = New-Object -TypeName System.IO.DriveInfo -ArgumentList @($FilePathOrUri)
    if (($null -ne $driveInfo) -and ($driveInfo.DriveType -eq [System.IO.DriveType]::Network))
    {
        return $true
    }
            
    # else just assume it is local
    return $false
}

function CopyVhdToStagingIfNeeded_Private
{
    Param(
        [ValidateNotNullOrEmpty()] 
        [string] 
        # The full path a local or remote (available from a UNC share or a network-mapped drive) file.
        $VhdFilePathOrUri
    )

    # check whether the file resides locally or is remote. 
    $isRemoteVhd = IsFileRemote_Private -FilePathOrUri $VhdFilePathOrUri

    # if this is a local vhd, then don't copy it to the local staging area
    if ($false -eq $isRemoteVhd)
    {
        return $VhdFilePathOrUri
    }

    # Location of vhd staging area
    $VhdStagingFolder = Join-Path $env:USERPROFILE -ChildPath "UploadVhdToDTL\Staging"

    # Create the local staging folder if it doesn't already exist
    if ($false -eq (Test-Path -Path $VhdStagingFolder))
    {
        New-Item -Path $VhdStagingFolder -ItemType directory | Out-Null
    }

    $vhdFileName = Split-Path -Path $VhdFilePathOrUri -Leaf
    $vhdStagingPath = Join-Path -Path $VhdStagingFolder -ChildPath $vhdFileName

    # copy the vhd to staging folder.
    Write-Warning $("Copying the vhd to local staging area '" + $vhdStagingPath + "' (Note: This can take a while)...")
    Write-Verbose $("Copying the vhd to local staging area.")
    Write-Verbose $("Source : " + $VhdFilePathOrUri)
    Write-Verbose $("Staging Destination : " + $vhdStagingPath)

    if ($true -eq $VhdFilePathOrUri.StartsWith("https://"))
    {
        # @Todo: Blob Uris are currently not supported. Will be fixed in a future update.
        throw "Blob Uris are currently not supported by this cmdlet."
    }
    else
    {
        Copy-Item -Path $VhdFilePathOrUri -Destination $vhdStagingPath -Force | Out-Null
    }

    Write-Verbose "Successfully copied vhd to staging folder."

    return $vhdStagingPath
}

function CopyVhdToStaging_Private
{
    Param(
        [ValidateNotNullOrEmpty()] 
        [string] 
        # The name of the blob representing the vhd file.
        $SrcVhdBlobName,

        [ValidateNotNullOrEmpty()] 
        [string] 
        # The name of the container which houses the vhd file.
        $SrcVhdContainerName,

        [Parameter(Mandatory=$true, ParameterSetName="AddByBlobDetails")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the storage account assoiciated with the vhd file.
        $SrcVhdStorageAccountName,

        [Parameter(Mandatory=$true, ParameterSetName="AddByBlobDetails")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The key of the storage account associated with the vhd file.
        $SrcVhdStorageAccountKey
    )

    # Location of vhd staging area
    $VhdStagingFolder = Join-Path $env:USERPROFILE -ChildPath "UploadVhdToDTL\Staging"

    # Create the local staging folder if it doesn't already exist
    if ($false -eq (Test-Path -Path $VhdStagingFolder))
    {
        New-Item -Path $VhdStagingFolder -ItemType directory | Out-Null
    }

    $vhdStagingPath = Join-Path -Path $VhdStagingFolder -ChildPath $SrcVhdBlobName

    # Create a new storage context using the provided storage account name and key.
    $storageAccountContext = New-AzureStorageContext -StorageAccountName $SrcVhdStorageAccountName -StorageAccountKey $SrcVhdStorageAccountKey

    if ($null -eq $storageAccountContext)
    {
        throw $("Unable to create a new storage account context for storage account '" + $SrcVhdStorageAccountName + "'")
    }

    # copy the vhd to staging folder.
    Write-Warning $("Copying the vhd to local staging area '" + $vhdStagingPath + "' (Note: This can take a while)...")
    Write-Verbose $("Copying the vhd to local staging area.")
    Write-Verbose $("Source : " + $SrcVhdBlobName)
    Write-Verbose $("Staging Destination : " + $vhdStagingPath)

    # Note: We're explicitly using '-ErrorAction Stop' to ensure that a terminating error is thrown if the vhd cannot be copied to local staging folder. 
    Get-AzureStorageBlobContent -Blob $SrcVhdBlobName -Container $SrcVhdContainerName -Context $storageAccountContext -Destination $vhdStagingPath -CheckMd5:$false -ErrorAction Stop -Force | Out-Null
    Write-Verbose "Successfully copied vhd to staging folder."

    return $vhdStagingPath
}

##################################################################################################

function Get-AzureDtlLab
{
    <#
        .SYNOPSIS
        Gets labs under the current subscription.

        .DESCRIPTION
        The Get-AzureDtlLab cmdlet does the following: 
        - Gets a specific lab, if the -LabId parameter is specified.
        - Gets all labs with matching name, if the -LabName parameter is specified.
        - Gets all labs with matching name within a resource group, if the -LabName and -LabResourceGroupName parameters are specified.
        - Gets all labs in a resource group, if the -LabResourceGroupName parameter is specified.
        - Gets all labs in a location, if the -LabLocation parameter is specified.
        - Gets all labs within current subscription, if no parameters are specified. 

        .EXAMPLE
        Get-AzureDtlLab -LabId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/labs/MyLab"
        Gets a specific lab, identified by the specified resource-id.

        .EXAMPLE
        Get-AzureDtlLab -LabName "MyLab"
        Gets all labs with the name "MyLab".

        .EXAMPLE
        Get-AzureDtlLab -LabName "MyLab" -LabResourceGroupName "MyLabRG"
        Gets all labs with the name "MyLab" within the resource group "MyLabRG".

        .EXAMPLE
        Get-AzureDtlLab -LabResourceGroupName "MyLabRG"
        Gets all labs in the "MyLabRG" resource group.

        .EXAMPLE
        Get-AzureDtlLab -LabLocation "westus"
        Gets all labs in the "westus" location.

        .EXAMPLE
        Get-AzureDtlLab
        Gets all labs within current subscription (use the Select-AzureRmSubscription cmdlet to change the current subscription).

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="ListAll")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="ListByLabId")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The ResourceId of the lab (e.g. "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/labs/MyLab").
        $LabId,

        [Parameter(Mandatory=$true, ParameterSetName="ListByLabName")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the lab.
        $LabName,

        [Parameter(Mandatory=$false, ParameterSetName="ListByLabName")] 
        [Parameter(Mandatory=$true, ParameterSetName="ListAllInResourceGroup")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the lab's resource group.
        $LabResourceGroupName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInLocation")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The location of the lab ("westus", "eastasia" etc).
        $LabLocation,

        [Parameter(Mandatory=$false, ParameterSetName="ListByLabId")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListByLabName")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListAllInResourceGroup")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListAllInLocation")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListAll")] 
        [switch]
        # Optional. If specified, fetches the properties of the lab(s).
        $ShowProperties
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        $output = $null

        switch($PSCmdlet.ParameterSetName)
        {
            "ListByLabId"
            {
                $output = Get-AzureRmResource | Where-Object { 
                    $_.ResourceType -eq $LabResourceType -and 
                    $_.ResourceId -eq $LabId 
                }
            }
                    
            "ListByLabName"
            {
                if ($PSBoundParameters.ContainsKey("LabResourceGroupName"))
                {
                    $output = Get-AzureRmResource | Where-Object { 
                        $_.ResourceType -eq $LabResourceType -and 
                        $_.ResourceName -eq $LabName -and 
                        $_.ResourceGroupName -eq $LabResourceGroupName 
                    }
                }
                else
                {
                    $output = Get-AzureRmResource | Where-Object { 
                        $_.ResourceType -eq $LabResourceType -and 
                        $_.ResourceName -eq $LabName 
                    }     
                }
            }

            "ListAllInResourceGroup"
            {
                $output = Get-AzureRmResource | Where-Object { 
                    $_.ResourceType -eq $LabResourceType -and 
                    $_.ResourceGroupName -eq $LabResourceGroupName 
                }
            }

            "ListAllInLocation"
            {
                $output = Get-AzureRmResource | Where-Object { 
                    $_.ResourceType -eq $LabResourceType -and 
                    $_.Location -eq $LabLocation 
                }
            }

            "ListAll" 
            {
                $output = Get-AzureRmResource | Where-Object { 
                    $_.ResourceType -eq $LabResourceType 
                }
            }
        }

        # now let us display the output
        if ($PSBoundParameters.ContainsKey("ShowProperties"))
        {
            foreach ($item in $output)
            {
                GetResourceWithProperties_Private -Resource $item | Write-Output
            }
        }
        else
        {
            $output | Write-Output
        }
    }
}

##################################################################################################

function Get-AzureDtlVMTemplate
{
    <#
        .SYNOPSIS
        Gets VM templates from a specified lab.

        .DESCRIPTION
        The Get-AzureDtlVMTemplate cmdlet does the following: 
        - Gets a specific VM template, if the -VMTemplateId parameter is specified.
        - Gets all VM templates with matching name from a lab, if the -VMTemplateName and -Lab parameters are specified.
        - Gets all VM templates from a lab, if the -Lab parameter is specified.

        .EXAMPLE
        Get-AzureDtlVMTemplate -VMTemplateId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/labs/MyLab1/vmtemplates/MyVMTemplate1"
        Gets a specific VM template, identified by the specified resource-id.

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab1"
        Get-AzureDtlVMTemplate -VMTemplateName "MyVMTemplate1" -Lab $lab

        Gets all VM templates with the name "MyVMTemplate1" from the lab "MyLab1".

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab1"
        Get-AzureDtlVMTemplate -Lab $lab

        Gets all VM templates from the lab "MyLab1".

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="ListAllInLab")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="ListByVMTemplateId")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The ResourceId of the VM template (e.g. "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/labs/MyLab1/vmtemplates/MyVMTemplate1").
        $VMTemplateId,

        [Parameter(Mandatory=$true, ParameterSetName="ListByVMTemplateName")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the VM template 
        $VMTemplateName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInLab")] 
        [Parameter(Mandatory=$true, ParameterSetName="ListByVMTemplateName")] 
        [ValidateNotNull()]
        # An existing lab (please use the Get-AzureDtlLab cmdlet to get this lab object).
        $Lab,

        [Parameter(Mandatory=$false, ParameterSetName="ListByVMTemplateId")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListByVMTemplateName")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListAllInLab")] 
        [switch]
        # Optional. If specified, fetches the properties of the VM template(s).
        $ShowProperties
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        $output = $null

        switch ($PSCmdlet.ParameterSetName)
        {
            "ListByVMTemplateId"
            {
                $output = Get-AzureRmResource -ResourceId $VMTemplateId -ApiVersion $RequiredApiVersion
            }

            "ListByVMTemplateName"
            {
                $output = Get-AzureRmResource -ResourceName $Lab.ResourceName -ResourceGroupName $Lab.ResourceGroupName -ResourceType $VMTemplateResourceType -ApiVersion $RequiredApiVersion | Where-Object {
                    $_.Name -eq $VMTemplateName
                }
            }

            "ListAllInLab"
            {
                $output = Get-AzureRmResource -ResourceName $Lab.ResourceName -ResourceGroupName $Lab.ResourceGroupName -ResourceType $VMTemplateResourceType -ApiVersion $RequiredApiVersion
            }
        }

        # now let us display the output
        if ($PSBoundParameters.ContainsKey("ShowProperties"))
        {
            foreach ($item in $output)
            {
                GetResourceWithProperties_Private -Resource $item | Write-Output
            }
        }
        else
        {
            $output | Write-Output
        }
    }
}

##################################################################################################

function Get-AzureDtlVhd
{
    <#
        .SYNOPSIS
        Gets vhds from a specified lab.

        .DESCRIPTION
        The Get-AzureDtlVhd cmdlet does the following: 
        - Gets a specific vhd from a lab, if the -VhdName parameter is specified.
        - Gets a specific vhd from a lab, if the -VhdUri parameter is specified.
        - Gets all vhds from a lab, if the -Lab parameter is specified.

        .EXAMPLE 
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab1"
        Get-AzureDtlVhd -VhdName "myVhd.vhd" -Lab $lab

        Gets a specific vhd "myVhd.vhd" from the lab "MyLab1".

        .EXAMPLE 
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab1"
        Get-AzureDtlVhd -VhdAbsoluteUri "https://msdtlvmxxxxxx.blob.core.windows.net/uploads/myVhd.vhd" -Lab $lab

        Gets a specific vhd from the lab "MyLab1".

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab1"
        Get-AzureDtlVhd -Lab $lab

        Gets all vhds from the lab "MyLab1".

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="ListAllInLab")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="ListByVhdName")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the vhd 
        $VhdName,

        [Parameter(Mandatory=$true, ParameterSetName="ListByVhdUri")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The absolute uri of the vhd
        $VhdAbsoluteUri,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInLab")] 
        [Parameter(Mandatory=$true, ParameterSetName="ListByVhdName")] 
        [Parameter(Mandatory=$true, ParameterSetName="ListByVhdUri")] 
        [ValidateNotNull()]
        # An existing lab (please use the Get-AzureDtlLab cmdlet to get this lab object).
        $Lab
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        # Get the default storage account associated with the lab.
        Write-Verbose $("Extracting the context for the default storage account for lab '" + $Lab.Name + "'")
        $labStorageAccountContext = GetDefaultStorageAccountContextFromLab_Private -Lab $Lab
        Write-Verbose $("Successfully extracted the context for the default storage account for lab '" + $Lab.Name + "'")

        # Extract the 'uploads' container (which houses the vhds).
        Write-Verbose $("Extracting the 'uploads' container")
        $uploadsContainer = Get-AzureStorageContainer -Name "uploads" -Context $labStorageAccountContext

        if ($null -eq $uploadsContainer)
        {
            throw $("Unable to extract the 'uploads' container from the default storage account for lab '" + $Lab.Name + "'")
        }
        
        #
        $output = $null

        switch ($PSCmdlet.ParameterSetName)
        {
            "ListByVhdName"
            {
                if ($VhdName -notlike "*.vhd")
                {
                    $VhdName = $($VhdName + ".vhd")
                }

                $output = Get-AzureStorageBlob -Container $uploadsContainer.Name -Blob $VhdName -Context $labStorageAccountContext
            }

            "ListByVhdUri"
            {
                $output = Get-AzureStorageBlob -Container $uploadsContainer.Name -Context $labStorageAccountContext | Where-Object {
                    ($_.ICloudBlob -ne $null) -and 
                    ($_.ICloudBlob.Uri -ne $null) -and
                    ($_.ICloudBlob.Uri.AbsoluteUri -ne $null) -and
                    ($_.ICloudBlob.Uri.AbsoluteUri -eq $VhdAbsoluteUri) 
                }
            }

            "ListAllInLab"
            {
                $output = Get-AzureStorageBlob -Container $uploadsContainer.Name -Context $labStorageAccountContext
            }
        }

        # now let us display the output
        $output | Write-Output
    }
}

##################################################################################################

function Get-AzureDtlVirtualMachine
{
    <#
        .SYNOPSIS
        Gets virtual machines under the current subscription.

        .DESCRIPTION
        The Get-AzureDtlVirtualMachine cmdlet does the following: 
        - Gets a specific VM, if the -VMId parameter is specified.
        - Gets all VMs with matching name, if the -VMName parameter is specified.
        - Gets all VMs in a lab, if the -LabName parameter is specified.
        - Gets all VMs in a resource group, if the -VMResourceGroup parameter is specified.
        - Gets all VMs in a location, if the -VMLocation parameter is specified.
        - Gets all VMs within current subscription, if no parameters are specified. 

        .EXAMPLE
        Get-AzureDtlVirtualMachine -VMId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/environments/MyVM"
        Gets a specific VM, identified by the specified resource-id.

        .EXAMPLE
        Get-AzureDtlVirtualMachine -VMName "MyVM1"
        Gets all VMs with the name "MyVM1".

        .EXAMPLE
        Get-AzureDtlVirtualMachine -LabName "MyLab"
        Gets all VMs within the lab "MyLab".

        .EXAMPLE
        Get-AzureDtlVirtualMachine -VMResourceGroupName "MyLabRG"
        Gets all VMs in the "MyLabRG" resource group.

        .EXAMPLE
        Get-AzureDtlVirtualMachine -VMLocation "westus"
        Gets all VMs in the "westus" location.

        .EXAMPLE
        Get-AzureDtlVirtualMachine
        Gets all VMs within current subscription (use the Select-AzureRmSubscription cmdlet to change the current subscription).

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="ListAll")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="ListByVMId")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The ResourceId of the VM (e.g. "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/environments/MyVM").
        $VMId,

        [Parameter(Mandatory=$true, ParameterSetName="ListByVMName")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the VM.
        $VMName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInLab")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # Name of the lab.
        $LabName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInResourceGroup")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the VM's resource group.
        $VMResourceGroupName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInLocation")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The location of the VM.
        $VMLocation,

        [Parameter(Mandatory=$false, ParameterSetName="ListByVMId")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListByVMName")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListAllInLab")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListAllInResourceGroup")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListAllInLocation")] 
        [Parameter(Mandatory=$false, ParameterSetName="ListAll")] 
        [switch]
        # Optional. If specified, fetches the properties of the virtual machine(s).
        $ShowProperties
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        $output = $null

        switch($PSCmdlet.ParameterSetName)
        {
            "ListByVMId"
            {
                $output = Get-AzureRmResource | Where-Object { 
                    $_.ResourceType -eq $EnvironmentResourceType -and 
                    $_.ResourceId -eq $VMId 
                }
            }
                    
            "ListByVMName"
            {
                $output = Get-AzureRmResource | Where-Object { 
                    $_.ResourceType -eq $EnvironmentResourceType -and 
                    $_.ResourceName -eq $VMName 
                }                
            }

            "ListAllInLab"
            {
                $fetchedLabObj = Get-AzureDtlLab -LabName $LabName 

                if ($null -ne $fetchedLabObj -and $fetchedLabObj.Count -ne 0)
                {
                    if ($fetchedLabObj.Count > 1)
                    {
                        throw $("Multiple labs found with name '" + $LabName + "'")
                    }
                    else
                    {
                        write-Verbose $("Found lab : " + $fetchedLabObj.ResourceName) 
                        write-Verbose $("LabId : " + $fetchedLabObj.ResourceId) 

                        # Note: The -ErrorAction 'SilentlyContinue' ensures that we suppress irrelevant
                        # errors originating while expanding properties (especially in internal test and
                        # pre-production subscriptions).
                        $output = Get-AzureRmResource -ExpandProperties -ErrorAction "SilentlyContinue" | Where-Object { 
                            $_.ResourceType -eq $EnvironmentResourceType -and
                            $_.Properties.LabId -eq $fetchedLabObj.ResourceId
                        }
                    }
                }
            }

            "ListAllInResourceGroup"
            {
                $output = Get-AzureRmResource | Where-Object { 
                    $_.ResourceType -eq $EnvironmentResourceType -and 
                    $_.ResourceGroupName -eq $VMResourceGroupName 
                }             
            }

            "ListAllInLocation"
            {
                $output = Get-AzureRmResource | Where-Object { 
                    $_.ResourceType -eq $EnvironmentResourceType -and 
                    $_.Location -eq $VMLocation 
                }
            }

            "ListAll" 
            {
                $output = Get-AzureRmResource | Where-Object { 
                    $_.ResourceType -eq $EnvironmentResourceType 
                }
            }
        }

        # now let us display the output
        if ($PSBoundParameters.ContainsKey("ShowProperties"))
        {
            foreach ($item in $output)
            {
                GetResourceWithProperties_Private -Resource $item | Write-Output
            }
        }
        else
        {
            $output | Write-Output
        }
    }
}

##################################################################################################

function New-AzureDtlLab
{
    <#
        .SYNOPSIS
        Creates a new lab.

        .DESCRIPTION
        The New-AzureDtlLab cmdlet creates a new lab in the specified location.

        .EXAMPLE
        New-AzureDtlLab -LabName "MyLab1" -LabLocation "West US"
        Creates a new lab "MyLab1" in the location "West US".

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)] 
        [ValidateNotNullOrEmpty()]
        [string]
        # Name of lab to be created.
        $LabName,

        [Parameter(Mandatory=$true)] 
        [ValidateNotNullOrEmpty()]
        [string]
        # Location where the lab will be created.
        $LabLocation
    )

    PROCESS 
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        # Unique name for the deployment
        $deploymentName = [Guid]::NewGuid().ToString()

        # Folder location of VM creation script, the template file and template parameters file.
        $LabCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "azuredeploy.json"

        # Pre-condition check to ensure the RM template file exists.
        if ($false -eq (Test-Path -Path $LabCreationTemplateFile))
        {
            throw $("The RM template file could not be located at : '" + $LabCreationTemplateFile + "'")
        }
        else
        {
            Write-Verbose $("The RM template file was located at : '" + $LabCreationTemplateFile + "'")
        }

        # Check if there are any existing labs with same name in the current subscription
        $existingLabs = Get-AzureRmResource | Where-Object { 
            $_.ResourceType -eq $LabResourceType -and 
            $_.ResourceName -eq $LabName -and 
            $_.SubscriptionId -eq (Get-AzureRmContext).Subscription.SubscriptionId
        }

        # If none exist, then create a new one
        if ($null -eq $existingLabs -or 0 -eq $existingLabs.Count)
        {
            # Create a new resource group with a unique name (using the lab name as a seed/prefix).
            Write-Verbose $("Creating new resoure group with seed/prefix '" + $LabName + "' at location '" + $LabLocation + "'")
            $newResourceGroup = CreateNewResourceGroup_Private -ResourceGroupSeedPrefixName $LabName -Location $LabLocation
            Write-Verbose $("Successfully created new resoure group '" + $newResourceGroup.ResourceGroupName + "' at location '" + $newResourceGroup.Location + "'")
    
            # Create the lab in this resource group by deploying the RM template
            Write-Verbose $("Creating new lab '" + $LabName + "'")
            $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $newResourceGroup.ResourceGroupName  -TemplateFile $LabCreationTemplateFile -newLabName $LabName 

            if (($null -ne $rgDeployment) -and ($null -ne $rgDeployment.Outputs['labId']) -and ($null -ne $rgDeployment.Outputs['labId'].Value))
            {
                $labId = $rgDeployment.Outputs['labId'].Value

                Write-Verbose $("LabId : '" + $labId + "'")

                Get-AzureRmResource -ResourceId $labId | Write-Output
            }
        }

        # else display an error
        else
        {
            throw $("One or more labs with name '" + $LabName + "' already exist in the current subscription '" + (Get-AzureRmContext).Subscription.SubscriptionId + "'.")
        }
    }
}

##################################################################################################

function New-AzureDtlVMTemplate
{
    <#
        .SYNOPSIS
        Creates a new (or updates an existing) virtual machine template.

        .DESCRIPTION
        The New-AzureDtlVMTemplate cmdlet creates a new VM template from an existing VM.
        - The new VM template is created in the same lab as the VM.
        - If a VM template with the same name already exists in the lab, then it simply updates it.

        .EXAMPLE
        $lab = $null

        $vm = Get-AzureDtlVirtualMachine -VMName "MyVM1"
        New-AzureDtlVMTemplate -VM $vm -VMTemplateName "MyVMTemplate1" -VMTemplateDescription "MyDescription"

        Creates a new VM Template "MyVMTemplate1" from the VM "MyVM1".

        .INPUTS
        None.
    #>
    [CmdletBinding()]
    Param(
        [ValidateNotNull()]
        # An existing VM from which the new VM template will be created (please use the Get-AzureDtlVirtualMachine cmdlet to get this VM object).
        $VM,

        [ValidateNotNullOrEmpty()]
        [string]
        # Name of the new VM template to create.
        $VMTemplateName,

        [ValidateNotNull()]
        [string]
        # Details about the new VM template being created.
        $VMTemplateDescription = ""
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        # Get the same VM object, but with properties attached.
        $VM = GetResourceWithProperties_Private -Resource $VM

        # Pre-condition checks to ensure that VM is in a valid state.
        if (($null -ne $VM) -and ($null -ne $VM.Properties) -and ($null -ne $VM.Properties.ProvisioningState))
        {
            if ("succeeded" -ne $VM.Properties.ProvisioningState)
            {
                throw $("The provisioning state of the VM '" + $VM.ResourceName + "' is '" + $VM.Properties.ProvisioningState + "'. Hence unable to continue.")
            }
        }
        else
        {
            throw $("The provisioning state of the VM '" + $VM.ResourceName + "' could not be determined. Hence unable to continue.")
        }

        # Pre-condition checks to ensure that we're able to extract the Resource Id of the compute VM.
        if (($null -eq $VM) -or ($null -eq $VM.Properties) -or ($null -eq $VM.Properties.Vms) -or ($null -eq $VM.Properties.Vms[0]) -or ($null -eq $VM.Properties.Vms[0].ComputeId) )
        {
            throw $("Unable to determine the Resource Id of the compute VM '" + $VM.ResourceName + "'.")
        }

        # Unique name for the deployment
        $deploymentName = [Guid]::NewGuid().ToString()

        # Folder location of VM creation script, the template file and template parameters file.
        $VMTemplateCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "..\201-dtl-create-vmtemplate\azuredeploy.json" -Resolve

        # Pre-condition check to ensure the RM template file exists.
        if ($false -eq (Test-Path -Path $VMTemplateCreationTemplateFile))
        {
            throw $("The RM template file could not be located at : '" + $VMTemplateCreationTemplateFile + "'")
        }
        else
        {
            Write-Verbose $("The RM template file was located at : '" + $VMTemplateCreationTemplateFile + "'")
        }

        # Get the lab that contains the source VM
        $lab = GetLabFromVM_Private -VM $VM

        # encode the VM template name
        $VMTemplateNameEncoded = $VMTemplateName.Replace(" ", "%20")

        # Create the VM Template in the lab's resource group by deploying the RM template
        Write-Verbose $("Creating VM Template '" + $VMTemplateName + "' in lab '" + $lab.ResourceName + "'")
        $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $lab.ResourceGroupName -TemplateFile $VMTemplateCreationTemplateFile -existingLabName $lab.ResourceName -existingVMResourceId $VM.Properties.Vms[0].ComputeId -templateName $VMTemplateNameEncoded -templateDescription $VMTemplateDescription

        if (($null -ne $rgDeployment) -and ($null -ne $rgDeployment.Outputs['vmTemplateId']) -and ($null -ne $rgDeployment.Outputs['vmTemplateId'].Value))
        {
            $vmTemplateId = $rgDeployment.Outputs['vmTemplateId'].Value

            Write-Verbose $("VMTemplateId : '" + $vmTemplateId + "'")

            Get-AzureRmResource -ResourceId $vmTemplateId -ApiVersion $RequiredApiVersion | Write-Output
        }
    }
}

##################################################################################################

function Add-AzureDtlVhd
{
    <#
        .SYNOPSIS
        Uploads a new vhd into the specified lab.

        .DESCRIPTION
        The Add-AzureDtlVhd cmdlet uploads a vhd into a lab. The source vhd can reside on:
        - local drives (e.g. c:\somefolder\somefile.ext)
        - UNC shares (e.g. \\someshare\somefolder\somefile.ext).
        - Network mapped drives (e.g. net use z: \\someshare\somefolder && z:\somefile.ext). 
        - Blobs in Azure storage containers.
        Please note that the vhd file must meet the following specific requirements (dictated by Azure):
        - Must be a Gen1 vhd file (and NOT a Gen2 vhdx file).
        - Fixed sized vhd (and NOT dynamically expanding vhd). 
        - Size must be less than 1023 GB. 
        - The vhd must be uploaded as a page blob (and NOT as a block blob).

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab"
        $vhdlocation = "\\MyShare\MyFolder\MyVHD1.vhd"
        $friendlyName = "AnExampleVHD.vhd"

        Add-AzureDtlVhd -VhdFullPath $vhdlocation -Lab $lab -VhdFriendlyName $friendlyName 

        Uploads a vhd file "MyVHD1" from specified network share ("\\MyShare\MyFolder") into the lab "MyLab". 
        - Once uploaded, the vhd is renamed to "AnExampleVHD.vhd". 

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab"
        $friendlyName = "AnExampleVHD.vhd"

        Add-AzureDtlVhd -SrcVhdBlobName "MyVHD1.vhd" -SrcVhdContainerName "MyContainer1" -SrcVhdStorageAccountName "MyStorageAccount1" -SrcVhdStorageAccountKey "xxxxxxx" -Lab $lab -VhdFriendlyName $friendlyName

        Uploads a vhd file "MyVHD1" from the storage account "MyStorageAccount1" into the lab "MyLab".
        - Once uploaded, the vhd is renamed to "AnExampleVHD.vhd". 

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="AddByFileFullPath")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="AddByFileFullPath")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # Full path to the vhd file (that'll be uploaded to the lab).
        # Note: Currently we only support vhds that are available from:
        # - local drives (e.g. c:\somefolder\somefile.ext)
        # - UNC shares (e.g. \\someshare\somefolder\somefile.ext).
        # - Network mapped drives (e.g. net use z: \\someshare\somefolder && z:\somefile.ext). 
        $VhdFullPath,

        [Parameter(Mandatory=$true, ParameterSetName="AddByBlobDetails")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the blob representing the vhd file (that'll be uploaded to the lab).
        $SrcVhdBlobName,

        [Parameter(Mandatory=$true, ParameterSetName="AddByBlobDetails")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the container representing the vhd file (that'll be uploaded to the lab).
        $SrcVhdContainerName,

        [Parameter(Mandatory=$true, ParameterSetName="AddByBlobDetails")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the storage account assoiciated with the vhd file (that'll be uploaded to the lab).
        $SrcVhdStorageAccountName,

        [Parameter(Mandatory=$true, ParameterSetName="AddByBlobDetails")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The key of the storage account assoiciated with the vhd file (that'll be uploaded to the lab).
        $SrcVhdStorageAccountKey,

        [Parameter(Mandatory=$true, ParameterSetName="AddByFileFullPath")] 
        [Parameter(Mandatory=$true, ParameterSetName="AddByFileUri")] 
        [Parameter(Mandatory=$true, ParameterSetName="AddByBlobDetails")] 
        [ValidateNotNull()]
        # An existing lab to which the vhd will be uploaded (please use the Get-AzureDtlLab cmdlet to get this lab object).
        $Lab,

        # [Optional] The name that will be assigned to vhd once uploded to the lab.
        # The name should be in a "<filename>.vhd" format (E.g. "WinServer2012-VS2015.Vhd"). 
        [string]
        $VhdFriendlyName

        <# @TODO: The following parameters are currently not used. These will be consumed in a future update.

        [Parameter(Mandatory=$true, ParameterSetName="AddByFileUri")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # Absolute uri to the vhd file (that'll be uploaded to the lab).
        $VhdAbsoluteUri,

        # [Optional] If this switch is specified, then any vhds copied to the staging area (if any) will NOT be deleted.
        # Note: The default behavior is to delete all vhds from the staging area.
        # @TODO: Currently not used.
        [switch]
        $KeepStagingVhd = $false,

        # [Optional] If this switch is specified, then any vhds copied to the staging area (if any) will NOT be deleted.
        # Note: The default behavior is to NOT overwrite any existing vhds in the lab.
        # @TODO: Currently not used.
        [switch]
        $OverwriteExistingVhd = $false

        #>
    )

    PROCESS 
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        # If the user has specified a friendly name for the vhd, ensure that it is appended with ".vhd" extension. 
        if (($false -eq [string]::IsNullOrEmpty($VhdFriendlyName)) -and ($VhdFriendlyName -notlike "*.vhd"))
        {
            $VhdFriendlyName = $($VhdFriendlyName + ".vhd")
        }
        
        # Copy the vhd file into the staging area if needed
        switch($PSCmdlet.ParameterSetName)
        {
            "AddByFileFullPath"
            {
                # Check if the specified vhd actually exists
                if ($false -eq (Test-Path -Path $VhdFullPath))
                {
                    throw $("Specified vhd is not accessible: " + $VhdFullPath)
                }

                # Copy the vhd into the local staging area if needed
                Write-Verbose $("Copying the vhd file '" + $VhdFullPath + "' to a local staging area.")
                $vhdLocalPath = CopyVhdToStagingIfNeeded_Private -VhdFilePathOrUri $VhdFullPath
                Write-Verbose $("Successfully copied the vhd file to local staging area '" + $vhdLocalPath + "'.")
            }

            "AddByBlobDetails"
            {
                # Copy the vhd into the staging area        
                Write-Verbose $("Copying the vhd file '" + $SrcVhdBlobName + "' to a local staging area.")
                $vhdLocalPath = CopyVhdToStaging_Private -SrcVhdBlobName $SrcVhdBlobName -SrcVhdContainerName $SrcVhdContainerName -SrcVhdStorageAccountName $SrcVhdStorageAccountName -SrcVhdStorageAccountKey $SrcVhdStorageAccountKey
                Write-Verbose $("Successfully copied the vhd file to local staging area '" + $vhdLocalPath + "'.")
            }

            <# @TODO: The following parameter set is currently not being used. It'll be used in a future update.
            "AddByFileUri"
            {
            }
            #>
        }

        # Get the default storage account associated with the lab.
        Write-Verbose $("Extracting the context for the default storage account for lab '" + $Lab.Name + "'")
        $labStorageAccountContext = GetDefaultStorageAccountContextFromLab_Private -Lab $Lab
        Write-Verbose $("Extracted the context for the default storage account for lab '" + $Lab.Name + "'")

        # Extract the 'uploads' container (which houses the vhds).
        Write-Verbose $("Extracting the 'uploads' container")
        $uploadsContainer = Get-AzureStorageContainer -Name "uploads" -Context $labStorageAccountContext

        if ($null -eq $uploadsContainer)
        {
            throw $("Unable to extract the 'uploads' container from the default storage account for lab '" + $Lab.Name + "'")
        }

        # Compute the destination path. 
        $uploadsContainerUri = $uploadsContainer.CloudBlobContainer.Uri.AbsoluteUri
        $vhdDestinationPath = $($uploadsContainerUri + "/" + $(Split-Path -Path $vhdLocalPath -Leaf)) 

        # If the user has specified a friendly name for the vhd, let us use it. 
        if ($false -eq [string]::IsNullOrEmpty($VhdFriendlyName))
        {
            $vhdDestinationPath = $($uploadsContainerUri + "/" + $VhdFriendlyName) 
        }

        # Now upload the vhd to lab's container
        Write-Warning "Starting upload of vhd to lab (Note: This can take a while)..."
        Write-Verbose "Starting upload of vhd to lab (Note: This can take a while)..."
        Write-Verbose $("Source: " + $vhdLocalPath)
        Write-Verbose $("Destination: " + $vhdDestinationPath)
        
        Add-AzureRmVhd -Destination $vhdDestinationPath -LocalFilePath $vhdLocalPath -ResourceGroupName $lab.ResourceGroupName -NumberOfUploaderThreads $env:NUMBER_OF_PROCESSORS -OverWrite | Out-Null
        Write-Verbose "Success."
    }
}

##################################################################################################

function New-AzureDtlVirtualMachine
{
    <#
        .SYNOPSIS
        Creates a new virtual machine.

        .DESCRIPTION
        The New-AzureDtlVirtualMachine cmdlet creates a new VM in a lab (and optionally creates a user account on the VM).

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab"
        $vmtemplate = Get-AzureDtlVMTemplate -Lab $lab -VMTemplateName "MyVMTemplate"
        New-AzureDtlVirtualMachine -VMName "MyVM" -VMSize "Standard_A4" -Lab $lab -VMTemplate $vmtemplate

        Creates a new VM "MyVM" from the VM template "MyVMTemplate" in the lab "MyLab".
        - No new user account is created during the VM creation.
        - We assume that the original VM template already contains a built-in user account.
        - We assume that this built-in account can be used to log into the VM after creation.

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab"
        $vmtemplate = Get-AzureDtlVMTemplate -Lab $lab -VMTemplateName "MyVMTemplate"
        $secPwd = ConvertTo-SecureString -String "MyPwd" -AsPlainText -Force
        New-AzureDtlVirtualMachine -VMName "MyVM" -VMSize "Standard_A4" -Lab $lab -VMTemplate $vmtemplate -UserName "MyAdmin" -Password $secPwd

        Creates a new VM "MyVM" from the VM template "MyVMTemplate" in the lab "MyLab".
        - A new user account is created using the username/password combination specified.
        - This user account is added to the local administrators group. 

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab"
        $vmtemplate = Get-AzureDtlVMTemplate -Lab $lab -VMTemplateName "MyVMTemplate"
        $sshKey = ConvertTo-SecureString -String "MyKey" -AsPlainText -Force
        New-AzureDtlVirtualMachine -VMName "MyVM" -VMSize "Standard_A4" -Lab $lab -VMTemplate $vmtemplate -UserName "MyAdmin" -SSHKey $sshKey

        Creates a new VM "MyVM" from the VM template "MyVMTemplate" in the lab "MyLab".
        - A new user account is created using the username/SSH-key combination specified.

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="BuiltInUser")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="BuiltInUser")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of VM to be created.
        $VMName,

        [Parameter(Mandatory=$true, ParameterSetName="BuiltInUser")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The size of VM to be created ("Standard_A0", "Standard_D1_v2", "Standard_D2" etc).
        $VMSize,

        [Parameter(Mandatory=$true, ParameterSetName="BuiltInUser")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNull()]
        # An existing lab in which the VM will be created (please use the Get-AzureDtlLab cmdlet to get this lab object).
        $Lab,

        [Parameter(Mandatory=$true, ParameterSetName="BuiltInUser")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNull()]
        # An existing VM template which will be used to create the new VM (please use the Get-AzureDtlVmTemplate cmdlet to get this VMTemplate object).
        # Note: This VM template must exist in the lab identified via the '-LabName' parameter.
        $VMTemplate,

        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The user name that will be created on the new VM.
        $UserName,

        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [ValidateNotNullOrEmpty()]
        [Security.SecureString]
        # The password for the user to be created.
        $Password,

        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNullOrEmpty()]
        [Security.SecureString]
        # The public SSH key for user to be created.
        $SSHKey
    )

    PROCESS 
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        # Get the same VM template object, but with properties attached.
        $VMTemplate = GetResourceWithProperties_Private -Resource $VMTemplate

        # Pre-condition checks for azure gallery images.
        if ("Gallery" -eq $VMTemplate.Properties.ImageType)
        {
            if ($false -eq (($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("Password")) -or ($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("SSHKey"))))
            {
                throw $("The specified VM template '" + $VMTemplate.Name + "' uses an Azure gallery image. Please specify either the -UserName and -Password parameters or the -UserName and -SSHKey parameters to use this VM template.")
            }
        }
        else
        {
            # Pre-condition checks for linux vhds.
            if ("linux" -eq $VMTemplate.Properties.OsType)
            {
                if ($false -eq (($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("Password")) -or ($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("SSHKey"))))
                {
                    throw $("The specified VM template '" + $VMTemplate.Name + "' uses a linux vhd. Please specify either the -UserName and -Password parameters or the -UserName and -SSHKey parameters to use this VM template.")
                }
            }

            # Pre-condition checks for windows vhds.
            else 
            {
                # Pre-condition checks for sysprepped Windows vhds.
                if ($true -eq $VMTemplate.Properties.SysPrep)
                {
                    if ($false -eq ($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("Password")))
                    {
                        throw $("The specified VM template '" + $VMTemplate.Name + "' uses a sysprepped vhd. Please specify both the -UserName and -Password parameters to use this VM template.")
                    }
                }

                # Pre-condition checks for non-sysprepped Windows vhds.
                # Note: For non-sysprepped windows vhds we ignore the username and password and instead use the built-in account.
                else
                {
                    if ($true -eq ($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("Password")))
                    {
                        Write-Warning $("The specified VM template '" + $VMTemplate.Name + "' uses a non-sysprepped vhd with a built-in account. The specified userame and password will not be used.")
                    }                    
                }
            }
        }


        # Folder location of VM creation script, the template file and template parameters file.
        $VMCreationTemplateFile = $null

        switch($PSCmdlet.ParameterSetName)
        {
            "BuiltInUser"
            {
                $VMCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "..\101-dtl-create-vm-builtin-user\azuredeploy.json" -Resolve
            }

            "UsernamePwd"
            {
                $VMCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "..\101-dtl-create-vm-username-pwd\azuredeploy.json" -Resolve
            }

            "UsernameSSHKey"
            {
                $VMCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "..\101-dtl-create-vm-username-ssh\azuredeploy.json" -Resolve
            }
        }

        # pre-condition check to ensure that the template file actually exists.
        if ($false -eq (Test-Path -Path $VMCreationTemplateFile))
        {
            Write-Error $("The RM template file could not be located at : '" + $VMCreationTemplateFile + "'")
        }
        else
        {
            Write-Verbose $("The RM template file was located at : '" + $VMCreationTemplateFile + "'")
        }


        # Create a new resource group with a unique name (using the VM name as a seed/prefix).
        Write-Verbose $("Creating new resoure group with seed/prefix '" + $VMName + "' at location '" + $Lab.Location + "'")
        $newResourceGroup = CreateNewResourceGroup_Private -ResourceGroupSeedPrefixName $VMName -Location $Lab.Location
        Write-Verbose $("Created new resource group '" + $newResourceGroup.ResourceGroupName + "' at location '" + $newResourceGroup.Location + "'")

        # Create the virtual machine in this lab by deploying the RM template
        Write-Verbose $("Creating new virtual machine '" + $VMName + "'")
        Write-Warning $("Creating new virtual machine '" + $VMName + "'. This may take a couple of minutes.")

        $rgDeployment = $null

        # Unique name for the deployment
        $deploymentName = [Guid]::NewGuid().ToString()

        switch($PSCmdlet.ParameterSetName)
        {
            "BuiltInUser"
            {
                $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $newResourceGroup.ResourceGroupName -TemplateFile $VMCreationTemplateFile -newVMName $VMName -existingLabName $Lab.ResourceName -existingLabResourceGroupName $Lab.ResourceGroupName -newVMSize $VMSize -existingVMTemplateName $VMTemplate.Name
            }

            "UsernamePwd"
            {
                $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $newResourceGroup.ResourceGroupName -TemplateFile $VMCreationTemplateFile -newVMName $VMName -existingLabName $Lab.ResourceName -existingLabResourceGroupName $Lab.ResourceGroupName -newVMSize $VMSize -existingVMTemplateName $VMTemplate.Name -userName $UserName -password $Password
            }

            "UsernameSSHKey"
            {
                $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $newResourceGroup.ResourceGroupName -TemplateFile $VMCreationTemplateFile -newVMName $VMName -existingLabName $Lab.ResourceName -existingLabResourceGroupName $Lab.ResourceGroupName -newVMSize $VMSize -existingVMTemplateName $VMTemplate.Name -userName $UserName -sshKey $SSHKey  
            }
        }

        if (($null -ne $rgDeployment) -and ($null -ne $rgDeployment.Outputs['vmId']) -and ($null -ne $rgDeployment.Outputs['vmId'].Value))
        {
            Write-Verbose $("vm id : '" + $rgDeployment.Outputs['vmId'].Value + "'")

            Get-AzureRmResource -ResourceId $rgDeployment.Outputs['vmId'].Value | Write-Output
        }
    }
}

##################################################################################################

function Remove-AzureDtlVirtualMachine
{
    <#
        .SYNOPSIS
        Deletes specified virtual machines.

        .DESCRIPTION
        The Remove-AzureDtlVirtualMachine cmdlet does the following: 
        - Deletes a specific VM, if the -VMId parameter is specified.
        - Deletes all VMs with matching name, if the -VMName parameter is specified.
        - Deletes all VMs in a lab, if the -LabName parameter is specified.
        - Deletes all VMs in a resource group, if the -VMResourceGroup parameter is specified.
        - Deletes all VMs in a location, if the -VMLocation parameter is specified.
        - Deletes all VMs within current subscription, if no parameters are specified. 

        Warning: 
        - If multiple VMs match the specified conditions, all of them will be deleted. 
        - Please use the '-WhatIf' parameter to preview the VMs being deleted (without actually deleting them).
        - Please use the '-Confirm' parameter to pop up a confirmation dialog for each VM to be deleted.

        .EXAMPLE
        Remove-AzureDtlVirtualMachine -VMId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/environments/MyVM"
        Deletes a specific VM, identified by the specified resource-id.

        .EXAMPLE
        Remove-AzureDtlVirtualMachine -VMName "MyVM1"
        Deletes all VMs with the name "MyVM1".

        .EXAMPLE
        Remove-AzureDtlVirtualMachine -LabName "MyLab"
        Deletes all VMs within the lab "MyLab".

        .EXAMPLE
        Remove-AzureDtlVirtualMachine -VMResourceGroupName "MyLabRG"
        Deletes all VMs in the "MyLabRG" resource group.

        .EXAMPLE
        Remove-AzureDtlVirtualMachine -VMLocation "westus"
        Deletes all VMs in the "westus" location.

        .EXAMPLE
        Remove-AzureDtlVirtualMachine
        Deletes all VMs within current subscription (use the Select-AzureRmSubscription cmdlet to change the current subscription).

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(
        SupportsShouldProcess=$true,
        DefaultParameterSetName="DeleteAll")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="DeleteByVMId")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The ResourceId of the VM (e.g. "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/environments/MyVM").
        $VMId,

        [Parameter(Mandatory=$true, ParameterSetName="DeleteByVMName")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the VM.
        $VMName,

        [Parameter(Mandatory=$true, ParameterSetName="DeleteAllInLab")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # Name of the lab.
        $LabName,

        [Parameter(Mandatory=$true, ParameterSetName="DeleteAllInResourceGroup")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the VM's resource group.
        $VMResourceGroupName,

        [Parameter(Mandatory=$true, ParameterSetName="DeleteAllInLocation")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The location of the VM.
        $VMLocation
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        $vms = $null

        # First step is to fetch the specified VMs.
        switch($PSCmdlet.ParameterSetName)
        {
            "DeleteByVMId"
            {
                $vms = Get-AzureDtlVirtualMachine -VMId $VMId
            }
                    
            "DeleteByVMName"
            {
                $vms = Get-AzureDtlVirtualMachine -VMName $VMName 
            }

            "DeleteAllInLab"
            {
                $vms = Get-AzureDtlVirtualMachine -LabName $LabName
            }

            "DeleteAllInResourceGroup"
            {
                $vms = Get-AzureDtlVirtualMachine -VMResourceGroupName $VMResourceGroupName 
            }

            "DeleteAllInLocation"
            {
                $vms = Get-AzureDtlVirtualMachine -VMLocation $VMLocation
            }

            "DeleteAll" 
            {
                $vms = Get-AzureDtlVirtualMachine
            }
        }

        # Next, for each VM... 
        foreach ($vm in $vms)
        {
            # Get the same VM object, but with properties attached.
            $vm = GetResourceWithProperties_Private -Resource $vm

            # Pop the confirmation dialog.
            if ($PSCmdlet.ShouldProcess($vm.ResourceName, "delete VM"))
            {
                Write-Warning $("Deleting VM '" + $vm.ResourceName + "' (Id = " + $vm.ResourceId + ") ...")
                Write-Verbose $("Deleting VM '" + $vm.ResourceName + "' (Id = " + $vm.ResourceId + ") ...")

                # Nuke the VM.
                $result = Remove-AzureRmResource -ResourceId $vm.ResourceId -Force

                if ($true -eq $result)
                {
                    Write-Verbose $("Successfully deleted VM '" + $vm.ResourceName + "' (Id = " + $vm.ResourceId + ") ...")
                }
            }
        }
    }
}

##################################################################################################
