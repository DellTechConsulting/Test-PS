# Define DNS and Sites & Services Settings
$IPv4netID = "192.168.29.0/24"
$siteName = "LAB"
$location = "NewLabCity"

# Define Authoritative Internet Time Servers
$timePeerList = "0.us.pool.ntp.org 1.us.pool.ntp.org"

# Add DNS Reverse Lookup Zones
Add-DNSServerPrimaryZone -NetworkID $IPv4netID -ReplicationScope 'Forest' -DynamicUpdate 'Secure'

# Make Changes to Sites & Services
$defaultSite = Get-ADReplicationSite | Select DistinguishedName
Rename-ADObject $defaultSite.DistinguishedName -NewName $siteName
New-ADReplicationSubnet -Name $IPv4netID -site $siteName -Location $location

# Re-Register DC's DNS Records
Register-DnsClient

# Enable Default Aging/Scavenging Settings for All Zones and this DNS Server
Set-DnsServerScavenging –ScavengingState $True –ScavengingInterval 7:00:00:00 –ApplyOnAllZones
$Zones = Get-DnsServerZone | Where-Object {$_.IsAutoCreated -eq $False -and $_.ZoneName -ne 'TrustAnchors'}
$Zones | Set-DnsServerZoneAging -Aging $True

# Set Time Configuration
w32tm /config /manualpeerlist:$timePeerList /syncfromflags:manual /reliable:yes /update