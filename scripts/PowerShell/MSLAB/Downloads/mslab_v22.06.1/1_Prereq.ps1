# Verify Running as Admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
If (-not $isAdmin) {
    Write-Host "-- Restarting as Administrator" -ForegroundColor Cyan ; Start-Sleep -Seconds 1

    if($PSVersionTable.PSEdition -eq "Core") {
        Start-Process pwsh.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs 
    } else {
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs 
    }
    
    exit
}

# Skipping 10 lines because if running when all prereqs met, statusbar covers powershell output
1..10 | ForEach-Object { Write-Host "" }

#region Functions
#region Output logging
function WriteInfo($message) {
    Write-Host $message
}

function WriteInfoHighlighted($message) {
Write-Host $message -ForegroundColor Cyan
}

function WriteSuccess($message) {
Write-Host $message -ForegroundColor Green
}

function WriteError($message) {
Write-Host $message -ForegroundColor Red
}

function WriteErrorAndExit($message) {
    Write-Host $message -ForegroundColor Red
    Write-Host "Press enter to continue ..."
    Stop-Transcript
    Read-Host | Out-Null
    Exit
}
#endregion

#region Telemetry
Function Merge-Hashtables {
    $Output = @{}
    ForEach ($Hashtable in ($Input + $Args)) {
        If ($Hashtable -is [Hashtable]) {
            ForEach ($Key in $Hashtable.Keys) {$Output.$Key = $Hashtable.$Key}
        }
    }
    $Output
}
function Get-StringHash {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline, Mandatory = $true)]
        [string]$String,
        $Hash = "SHA1"
    )
    
    process {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($String)
        $algorithm = [System.Security.Cryptography.HashAlgorithm]::Create($Hash)
        $StringBuilder = New-Object System.Text.StringBuilder 
      
        $algorithm.ComputeHash($bytes) | 
        ForEach-Object { 
            $null = $StringBuilder.Append($_.ToString("x2")) 
        } 
      
        $StringBuilder.ToString() 
    }
}

function Get-VolumePhysicalDisk {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Volume
    )

    process {
        if(-not $Volume.EndsWith(":")) {
            $Volume += ":"
        }

        $physicalDisks = Get-cimInstance "win32_diskdrive"
        foreach($disk in $physicalDisks) {
            $partitions = Get-cimInstance -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($disk.DeviceID.replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition"
            foreach($partition in $partitions) {
                $partitionVolumes = Get-cimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($partition.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition"
                foreach($partitionVolume in $partitionVolumes) {
                    if($partitionVolume.Name -eq $Volume) {
                        $physicalDisk = Get-PhysicalDisk | Where-Object DeviceID -eq $disk.Index
                        return $physicalDisk
                    }
                }
            }
        }
    }
}

function Get-TelemetryLevel {
    param(
        [switch]$OptOut
    )
    process {
        $acceptedTelemetryLevels = "None", "Basic", "Full"

        # LabConfig value has a priority
        if($LabConfig.TelemetryLevel -and $LabConfig.TelemetryLevel -in $acceptedTelemetryLevels) {
            return $LabConfig.TelemetryLevel
        }

        # Environment variable as a fallback
        if($env:WSLAB_TELEMETRY_LEVEL -and $env:WSLAB_TELEMETRY_LEVEL -in $acceptedTelemetryLevels) {
            return $env:WSLAB_TELEMETRY_LEVEL
        }

        # If nothing is explicitely configured and OptOut flag enabled, explicitely disable telemetry
        if($OptOut) {
            return "None"
        }

        # as a last option return nothing to allow asking the user
    }
}

function Get-TelemetryLevelSource {
    param(
        [switch]$OptOut
    )
    process {
        $acceptedTelemetryLevels = "None", "Basic", "Full"

        # Is it set interactively?
        if($LabConfig.ContainsKey("TelemetryLevelSource")) {
            return $LabConfig.TelemetryLevelSource
        }

        # LabConfig value has a priority
        if($LabConfig.TelemetryLevel -and $LabConfig.TelemetryLevel -in $acceptedTelemetryLevels) {
            return "LabConfig"
        }

        # Environment variable as a fallback
        if($env:WSLAB_TELEMETRY_LEVEL -and $env:WSLAB_TELEMETRY_LEVEL -in $acceptedTelemetryLevels) {
            return "Environment"
        }
    }
}

function Get-PcSystemType {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Id
    )
    process {
        $type = switch($Id) {
            1 { "Desktop" }
            2 { "Laptop" }
            3 { "Workstation" }
            4 { "Server" }
            7 { "Server" }
            5 { "Server" }
            default { $Id }
        }

        $type
    }
}

$aiPropertyCache = @{}

function New-TelemetryEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Event,
        $Properties,
        $Metrics,
        $NickName
    )

    process {
        if(-not $TelemetryInstrumentationKey) {
            WriteInfo "Instrumentation key is required to send telemetry data."
            return
        }
        
        $level = Get-TelemetryLevel
        $levelSource = Get-TelemetryLevelSource

        $r = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        $build = "$($r.CurrentMajorVersionNumber).$($r.CurrentMinorVersionNumber).$($r.CurrentBuildNumber).$($r.UBR)"
        $osVersion = "$($r.ProductName) ($build)"
        $hw = Get-CimInstance -ClassName Win32_ComputerSystem
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $machineHash = (((Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Cryptography).MachineGuid) | Get-StringHash)

        if(-not $NickName) {
            $NickName = "?"
        }

        $osType = switch ($os.ProductType) {
            1 { "Workstation" }
            default { "Server" }
        }

        $extraMetrics = @{}
        $extraProperties = @{
            'telemetry.level' = $level
            'telemetry.levelSource' = $levelSource
            'telemetry.nick' = $NickName
            'powershell.edition' = $PSVersionTable.PSEdition
            'powershell.version' = $PSVersionTable.PSVersion.ToString()
            'host.isAzure' = (Get-CimInstance win32_systemenclosure).SMBIOSAssetTag -eq "7783-7084-3265-9085-8269-3286-77"
            'host.os.type' = $osType
            'host.os.build' = $r.CurrentBuildNumber
            'hw.type' = Get-PcSystemType -Id $hw.PCSystemType
        }
        if($level -eq "Full") {
            # OS
            $extraProperties.'device.locale' = (Get-WinsystemLocale).Name

            # RAM
            $extraMetrics.'memory.total' = [Math]::Round(($hw.TotalPhysicalMemory)/1024KB, 0)
            
            # CPU
            $extraMetrics.'cpu.logical.count' = $hw.NumberOfLogicalProcessors
            $extraMetrics.'cpu.sockets.count' = $hw.NumberOfProcessors

            if(-not $aiPropertyCache.ContainsKey("cpu.model")) {
                $aiPropertyCache["cpu.model"] = (Get-CimInstance "Win32_Processor" | Select-Object -First 1).Name
            }
            $extraProperties.'cpu.model' = $aiPropertyCache["cpu.model"]

            # Disk
            $driveLetter = $ScriptRoot -Split ":" | Select-Object -First 1
            $volume = Get-Volume -DriveLetter $driveLetter
            $disk = Get-VolumePhysicalDisk -Volume $driveLetter
            $extraMetrics.'volume.size' = [Math]::Round($volume.Size / 1024MB)
            $extraProperties.'volume.fs' = $volume.FileSystemType
            $extraProperties.'disk.type' = $disk.MediaType
            $extraProperties.'disk.busType' = $disk.BusType
        }

        $payload = @{
            name = "Microsoft.ApplicationInsights.Event"
            time = $([System.dateTime]::UtcNow.ToString("o")) 
            iKey = $TelemetryInstrumentationKey
            tags = @{ 
                "ai.internal.sdkVersion" = 'mslab-telemetry:1.0.2'
                "ai.application.ver" = $mslabVersion
                "ai.cloud.role" = Split-Path -Path $PSCommandPath -Leaf
                "ai.session.id" = $TelemetrySessionId
                "ai.user.id" = $machineHash
                "ai.device.id" = $machineHash
                "ai.device.type" = $extraProperties["hw.type"]
                "ai.device.locale" = "" # not propagated anymore
                "ai.device.os" = ""
                "ai.device.osVersion" = ""
                "ai.device.oemName" = ""
                "ai.device.model" = ""
            }
            data = @{
                baseType = "EventData"
                baseData = @{
                    ver = 2 
                    name = $Event
                    properties = ($Properties, $extraProperties | Merge-Hashtables)
                    measurements = ($Metrics, $extraMetrics | Merge-Hashtables)
                }
            }
        }

        if($level -eq "Full") {
            $payload.tags.'ai.device.os' = $osVersion
            $payload.tags.'ai.device.osVersion' = $build
        }
    
        $payload
    }
}

function Send-TelemetryObject {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Data
    )

    process {
        $json = "{0}" -f (($Data) | ConvertTo-Json -Depth 10 -Compress)

        if($LabConfig.ContainsKey('TelemetryDebugLog')) {
            Add-Content -Path "$ScriptRoot\Telemetry.log" -Value ((Get-Date -Format "s") + "`n" + $json)
        }

        try {
            $response = Invoke-RestMethod -Uri 'https://dc.services.visualstudio.com/v2/track' -Method Post -UseBasicParsing -Body $json -TimeoutSec 20
        } catch { 
            WriteInfo "`tSending telemetry failed with an error: $($_.Exception.Message)"
            $response = $_.Exception.Message
        }

        if($LabConfig.ContainsKey('TelemetryDebugLog')) {
            Add-Content -Path "$ScriptRoot\Telemetry.log" -Value $response
            Add-Content -Path "$ScriptRoot\Telemetry.log" -Value "`n------------------------------`n"
        }
    }
}

function Send-TelemetryEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Event,

        $Properties,
        $Metrics,
        $NickName
    )

    process {
        $telemetryEvent = New-TelemetryEvent -Event $Event -Properties $Properties -Metrics $Metrics -NickName $NickName
        Send-TelemetryObject -Data $telemetryEvent
    }
}

function Send-TelemetryEvents {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Events
    )

    process {
        Send-TelemetryObject -Data $Events
    }
}

function Read-TelemetryLevel {
    process {
        # Ask user for consent
        WriteInfoHighlighted "`nLab telemetry"
        WriteInfo "By providing a telemetry information you will help us to improve WSLab scripts. There are two levels of a telemetry information and we are not collecting any personally identifiable information (PII)."
        WriteInfo "Details about telemetry levels and the content of telemetry messages can be found in documentation https://aka.ms/wslab/telemetry"
        WriteInfo "Available telemetry levels are:"
        WriteInfo " * None  -- No information will be sent"
        WriteInfo " * Basic -- Information about lab will be sent (e.g. script execution time, number of VMs, guest OSes)"
        WriteInfo " * Full  -- Information about lab and the host machine (e.g. type of disk)"
        WriteInfo "Would you be OK with providing an information about your WSLab usage?"
        WriteInfo "`nTip: You can also configure telemetry settings explicitly in LabConfig.ps1 file or by setting an environmental variable and suppress this prompt."

        $options = [System.Management.Automation.Host.ChoiceDescription[]] @(
          <# 0 #> New-Object System.Management.Automation.Host.ChoiceDescription "&None", "No information will be sent"
          <# 1 #> New-Object System.Management.Automation.Host.ChoiceDescription "&Basic", "Lab info will be sent (e.g. script execution time, number of VMs)"
          <# 2 #> New-Object System.Management.Automation.Host.ChoiceDescription "&Full", "More details about the host machine and deployed VMs (e.g. guest OS)"
        )
        $response = $host.UI.PromptForChoice("WSLab telemetry level", "Please choose a telemetry level for this WSLab instance. For more details please see WSLab documentation.", $options, 1 <#default option#>)

        $telemetryLevel = $null
        switch($response) {
            0 {
                $telemetryLevel = 'None'
                WriteInfo "`nNo telemetry information will be sent."
            }
            1 {
                $telemetryLevel = 'Basic'
                WriteInfo "`nTelemetry has been set to Basic level, thank you for your valuable feedback."
            }
            2 {
                $telemetryLevel = 'Full'
                WriteInfo "`nTelemetry has been set to Full level, thank you for your valuable feedback."
            }
        }

        $telemetryLevel
    }
}

# Instance values
$ScriptRoot = $PSScriptRoot
$mslabVersion = "v22.06.1"
$TelemetryEnabledLevels = "Basic", "Full"
$TelemetryInstrumentationKey = "9ebf64de-01f8-4f60-9942-079262e3f6e0"
$TelemetrySessionId = $ScriptRoot + $env:COMPUTERNAME + ((Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Cryptography).MachineGuid) | Get-StringHash
#endregion

function  Get-WindowsBuildNumber { 
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return [int]($os.BuildNumber) 
} 
#endregion

#region Initialization

# grab Time and start Transcript
    Start-Transcript -Path "$PSScriptRoot\Prereq.log"
    $StartDateTime = Get-Date
    WriteInfo "Script started at $StartDateTime"
    WriteInfo "`nMSLab Version $mslabVersion"

#Load LabConfig....
    . "$PSScriptRoot\LabConfig.ps1"

# Telemetry Event
    if((Get-TelemetryLevel) -in $TelemetryEnabledLevels) {
        WriteInfo "Telemetry is set to $(Get-TelemetryLevel) level from $(Get-TelemetryLevelSource)"
        Send-TelemetryEvent -Event "Prereq.Start" -NickName $LabConfig.TelemetryNickName | Out-Null
    }

#define some variables if it does not exist in labconfig
    If (!$LabConfig.DomainNetbiosName){
        $LabConfig.DomainNetbiosName="Corp"
    }

    If (!$LabConfig.DomainName){
        $LabConfig.DomainName="Corp.contoso.com"
    }

#set TLS 1.2 for github downloads
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#endregion

#region OS checks and folder build

# Check if not running in root folder
    if (($psscriptroot).Length -eq 3) {
        WriteErrorAndExit "`t MSLab canot run in root folder. Please put MSLab scripts into a folder. Exiting"
    }

# Checking for Compatible OS
    WriteInfoHighlighted "Checking if OS is Windows 10 1511 (10586)/Server 2016 or newer"

    $BuildNumber=Get-WindowsBuildNumber
    if ($BuildNumber -ge 10586){
        WriteSuccess "`t OS is Windows 10 1511 (10586)/Server 2016 or newer"
    }else{
        WriteErrorAndExit "`t Windows version  $BuildNumber detected. Version 10586 and newer is needed. Exiting"
    }

# Checking Folder Structure
    "ParentDisks","Temp","Temp\DSC","Temp\ToolsVHD\DiskSpd","Temp\ToolsVHD\SCVMM\ADK","Temp\ToolsVHD\SCVMM\ADKWinPE","Temp\ToolsVHD\SCVMM\SQL","Temp\ToolsVHD\SCVMM\SCVMM","Temp\ToolsVHD\SCVMM\UpdateRollup" | ForEach-Object {
        if (!( Test-Path "$PSScriptRoot\$_" )) { New-Item -Type Directory -Path "$PSScriptRoot\$_" } }

    "Temp\ToolsVHD\SCVMM\ADK\Copy_ADK_with_adksetup.exe_here.txt","Temp\ToolsVHD\SCVMM\ADKWinPE\Copy_ADKWinPE_with_adkwinpesetup.exe_here.txt","Temp\ToolsVHD\SCVMM\SQL\Copy_SQL2017_or_SQL2019_with_setup.exe_here.txt","Temp\ToolsVHD\SCVMM\SCVMM\Copy_SCVMM_with_setup.exe_here.txt","Temp\ToolsVHD\SCVMM\UpdateRollup\Copy_SCVMM_Update_Rollup_MSPs_here.txt" | ForEach-Object {
        if (!( Test-Path "$PSScriptRoot\$_" )) { New-Item -Type File -Path "$PSScriptRoot\$_" } }
#endregion

#region Download Scripts

#add scripts for VMM
    $Filenames="1_SQL_Install","2_ADK_Install","3_SCVMM_Install"
    foreach ($Filename in $filenames){
        $Path="$PSScriptRoot\Temp\ToolsVHD\SCVMM\$Filename.ps1"
        If (Test-Path -Path $Path){
            WriteSuccess "`t $Filename is present, skipping download"
        }else{
            $FileContent=$null
            $FileContent = (Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/Microsoft/MSLab/master/Tools/$Filename.ps1").Content
            if ($FileContent){
                $script = New-Item $Path -type File -Force
                $FileContent=$FileContent -replace "PasswordGoesHere",$LabConfig.AdminPassword #only applies to 1_SQL_Install and 3_SCVMM_Install.ps1
                $FileContent=$FileContent -replace "DomainNameGoesHere",$LabConfig.DomainNetbiosName #only applies to 1_SQL_Install and 3_SCVMM_Install.ps1
                Set-Content -path $script -value $FileContent
            }else{
                WriteErrorAndExit "Unable to download $Filename."
            }
        }
    }

# add createparentdisks, DownloadLatestCU and PatchParentDisks scripts to Parent Disks folder
    $FileNames = "CreateParentDisk", "DownloadLatestCUs", "PatchParentDisks", "CreateVMFleetDisk"
    if($LabConfig.Linux) {
        $FileNames += "CreateLinuxParentDisk"
    }
    foreach ($filename in $filenames) {
        $Path="$PSScriptRoot\ParentDisks\$FileName.ps1"
        If (Test-Path -Path $Path) {
            WriteSuccess "`t $Filename is present, skipping download"
        } else {
            $FileContent = $null
            $FileContent = (Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/Microsoft/MSLab/master/Tools/$FileName.ps1").Content
            if ($FileContent) {
                $script = New-Item "$PSScriptRoot\ParentDisks\$FileName.ps1" -type File -Force
                Set-Content -path $script -value $FileContent
            } else {
                WriteErrorAndExit "Unable to download $Filename."
            }
        }
    }

# Download convert-windowsimage into Temp
WriteInfoHighlighted "Testing Convert-windowsimage presence"
If ( Test-Path -Path "$PSScriptRoot\Temp\Convert-WindowsImage.ps1" ) {
    WriteSuccess "`t Convert-windowsimage.ps1 is present, skipping download"
}else{ 
    WriteInfo "`t Downloading Convert-WindowsImage"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/microsoft/MSLab/master/Tools/Convert-WindowsImage.ps1" -OutFile "$PSScriptRoot\Temp\Convert-WindowsImage.ps1"
    } catch {
        WriteError "`t Failed to download Convert-WindowsImage.ps1!"
    }
}
#endregion

#region some tools to download
# Downloading diskspd if its not in ToolsVHD folder
    WriteInfoHighlighted "Testing diskspd presence"
    If ( Test-Path -Path "$PSScriptRoot\Temp\ToolsVHD\DiskSpd\diskspd.exe" ) {
        WriteSuccess "`t Diskspd is present, skipping download"
    }else{ 
        WriteInfo "`t Diskspd not there - Downloading diskspd"
        try {
            <# aka.ms/diskspd changed. Commented
            $webcontent  = Invoke-WebRequest -Uri "https://aka.ms/diskspd" -UseBasicParsing
            if($PSVersionTable.PSEdition -eq "Core") {
                $link = $webcontent.Links | Where-Object data-url -Match "/Diskspd.*zip$"
                $downloadUrl = "{0}://{1}{2}" -f $webcontent.BaseResponse.RequestMessage.RequestUri.Scheme, $webcontent.BaseResponse.RequestMessage.RequestUri.Host, $link.'data-url'
            } else {
                $downloadurl = $webcontent.BaseResponse.ResponseUri.AbsoluteUri.Substring(0,$webcontent.BaseResponse.ResponseUri.AbsoluteUri.LastIndexOf('/'))+($webcontent.Links | where-object { $_.'data-url' -match '/Diskspd.*zip$' }|Select-Object -ExpandProperty "data-url")
            }
            #>
            $downloadurl="https://github.com/microsoft/diskspd/releases/download/v2.0.21a/DiskSpd.zip"
            Invoke-WebRequest -Uri $downloadurl -OutFile "$PSScriptRoot\Temp\ToolsVHD\DiskSpd\diskspd.zip"
        }catch{
            WriteError "`t Failed to download Diskspd!"
        }
        # Unnzipping and extracting just diskspd.exe x64
            Microsoft.PowerShell.Archive\Expand-Archive "$PSScriptRoot\Temp\ToolsVHD\DiskSpd\diskspd.zip" -DestinationPath "$PSScriptRoot\Temp\ToolsVHD\DiskSpd\Unzip"
            Copy-Item -Path (Get-ChildItem -Path "$PSScriptRoot\Temp\ToolsVHD\diskspd\" -Recurse | Where-Object {$_.Directory -like '*amd64*' -and $_.name -eq 'diskspd.exe' }).fullname -Destination "$PSScriptRoot\Temp\ToolsVHD\DiskSpd\"
            Remove-Item -Path "$PSScriptRoot\Temp\ToolsVHD\DiskSpd\diskspd.zip"
            Remove-Item -Path "$PSScriptRoot\Temp\ToolsVHD\DiskSpd\Unzip" -Recurse -Force
    }

#endregion

#region Downloading required Posh Modules
# Downloading modules into Temp folder if needed.

    $modules=("xActiveDirectory","3.0.0.0"),("xDHCpServer","2.0.0.0"),("xDNSServer","1.15.0.0"),("NetworkingDSC","7.4.0.0"),("xPSDesiredStateConfiguration","8.10.0.0")
    foreach ($module in $modules){
        WriteInfoHighlighted "Testing if modules are present" 
        $modulename=$module[0]
        $moduleversion=$module[1]
        if (!(Test-Path "$PSScriptRoot\Temp\DSC\$modulename\$Moduleversion")){
            WriteInfo "`t Module $module not found... Downloading"
            #Install NuGET package provider   
            if ((Get-PackageProvider -Name NuGet) -eq $null){   
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Confirm:$false -Force
            }
            Find-DscResource -moduleName $modulename -RequiredVersion $moduleversion | Save-Module -Path "$PSScriptRoot\Temp\DSC"
        }else{
            WriteSuccess "`t Module $modulename version found... skipping download"
        }
    }

# Installing DSC modules if needed
    foreach ($module in $modules) {
        WriteInfoHighlighted "Testing DSC Module $module Presence"
        # Check if Module is installed
        if ((Get-DscResource -Module $Module[0] | where-object {$_.version -eq $module[1]}) -eq $Null) {
            # module is not installed - install it
            WriteInfo "`t Module $module will be installed"
            $modulename=$module[0]
            $moduleversion=$module[1]
            Copy-item -Path "$PSScriptRoot\Temp\DSC\$modulename" -Destination "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Force
            WriteSuccess "`t Module was installed."
            Get-DscResource -Module $modulename
        } else {
            # module is already installed
            WriteSuccess "`t Module $Module is already installed"
        }
    }

#endregion

#region Linux prereqs
if($LabConfig.Linux -eq $true) {
    WriteInfoHighlighted "Testing Linux prerequisites"
    WriteInfo "`t Test Packer availability"

    # Packer
    if (Get-Command "packer.exe" -ErrorAction SilentlyContinue) 
    { 
        WriteSuccess "`t Packer is in PATH."
    } else {
        WriteInfo "`t`t Downloading latest Packer binary"

        WriteInfo "`t`t Creating packer directory"
        $linuxToolsDirPath = "$PSScriptRoot\LAB\bin" 
        New-Item $linuxToolsDirPath -ItemType Directory -Force | Out-Null
        
        if(-not (Test-Path (Join-Path $linuxToolsDirPath "packer.exe"))) {
            $packerReleaseInfo = Invoke-RestMethod -Uri "https://checkpoint-api.hashicorp.com/v1/check/packer"
            $downloadUrl = "https://releases.hashicorp.com/packer/$($packerReleaseInfo.current_version)/packer_$($packerReleaseInfo.current_version)_windows_amd64.zip" 
            Start-BitsTransfer -Source $downloadUrl -Destination (Join-Path $linuxToolsDirPath "packer.zip") 
            Expand-Archive -Path (Join-Path $linuxToolsDirPath "packer.zip")  -DestinationPath $linuxToolsDirPath -Force
            Remove-Item -Path (Join-Path $linuxToolsDirPath "packer.zip") 
        }
    
        WriteInfo "`t`t Creating Packer firewall rule"
        $id = $PSScriptRoot -replace '[^a-zA-Z0-9]'
        $fwRule = Get-NetFirewallRule -Name "mslab-packer-$id" -ErrorAction SilentlyContinue
        if(-not $fwRule) {
            New-NetFirewallRule -Name "mslab-packer-$id" -DisplayName "Allow MSLab Packer ($($PSScriptRoot))" -Action Allow -Program (Join-Path $linuxToolsDirPath "packer.exe") -Profile Any -ErrorAction SilentlyContinue
        }
    }

    # Packer templates
    WriteInfo "`t`t Downloading Packer templates"
    $packerTemplatesDirectory = "$PSScriptRoot\ParentDisks\PackerTemplates\"
    if (-not (Test-Path $packerTemplatesDirectory)) {
        New-Item -Type Directory -Path $packerTemplatesDirectory 
    }

    $templatesBase = "https://github.com/microsoft/mslab-templates/releases/latest/download/"
    $templatesFile = "$($packerTemplatesDirectory)\templates.json"

    Invoke-WebRequest -Uri "$($templatesBase)/templates.json" -OutFile $templatesFile
    if(-not (Test-Path -Path $templatesFile)) {
        WriteErrorAndExit "Download of packer templates failed"
    }

    $templatesInfo = Get-Content -Path $templatesFile | ConvertFrom-Json
    foreach($template in $templatesInfo.templates) {
        $templateZipFile = Join-Path $packerTemplatesDirectory $template.package
        Invoke-WebRequest -Uri "$($templatesBase)/$($template.package)" -OutFile $templateZipFile
        Expand-Archive -Path $templateZipFile -DestinationPath (Join-Path $packerTemplatesDirectory $template.directory)
        Remove-Item -Path $templateZipFile
    }

    # OpenSSH
    $capability = Get-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0"
    if($capability.State -ne "Installed") {
        WriteInfoHighlighted "`t Enabling OpensSH Client"
        Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0"
        Set-Service ssh-agent -StartupType Automatic
        Start-Service ssh-agent
    }

    # SSH Key
    WriteInfoHighlighted "`t SSH key"
    if($LabConfig.SshKeyPath) {
        if(-not (Test-Path $LabConfig.SshKeyPath)) {
            WriteError "`t Cannot find specified SSH key $($LabConfig.SshKeyPath)."
        }

        $private = ssh-keygen.exe -y -e -f $LabConfig.SshKeyPath
        $public = ssh-keygen.exe -y -e -f "$($LabConfig.SshKeyPath).pub"
        $comparison = Compare-Object -ReferenceObject $private -DifferenceObject $public
        if($comparison) {
            WriteError "`t SSH Keypair $($LabConfig.SshKeyPath) does not match."
        }
    } 
    else 
    {
        WriteInfo "`t`t Generating new SSH key pair"
        $sshKeyDir = "$PSScriptRoot\LAB\.ssh" 
        $key = "$sshKeyDir\lab_rsa"
        New-Item -ItemType Directory $sshKeyDir -ErrorAction SilentlyContinue | Out-Null
        ssh-keygen.exe -t rsa -b 4096 -C "$($LabConfig.DomainAdminName)" -f $key -q -N '""'
    }
}
#endregion

# Telemetry Event
if((Get-TelemetryLevel) -in $TelemetryEnabledLevels) {
    $metrics = @{
        'script.duration' = ((Get-Date) - $StartDateTime).TotalSeconds
    }
 
    Send-TelemetryEvent -Event "Prereq.End" -Metrics $metrics -NickName $LabConfig.TelemetryNickName | Out-Null
}

# finishing 
WriteInfo "Script finished at $(Get-date) and took $(((get-date) - $StartDateTime).TotalMinutes) Minutes"
Stop-Transcript
WriteSuccess "Press enter to continue..."
Read-Host | Out-Null
