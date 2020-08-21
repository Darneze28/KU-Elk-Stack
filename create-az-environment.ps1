Connect-AzAccount
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

############################
### Define These Variables
############################
$resourceGroupName = 'ClassResourceGroup'
$location = 'EastUS'
$location2 = 'WestUS2'
$vm1 = 'Jump-Box-Provisioner'
$vm2 = 'DVWA-VM1'
$vm3 = 'DVWA-VM2'
$vm4 = 'Elk-Server'
$lbname = "LoadBalancer"
$protocol = 'TCP'
$healthcheckprotocol = 'http'
$insideport = 80
$outsideport = 80
$healthcheckpath = "/"
$adminuser  = 'AzureAdmin'

####################
## Global Config
####################
$me = get-azcontext | select -ExpandProperty Account | select -ExpandProperty Id
$homeip = Invoke-RestMethod jsonip.com | select -ExpandProperty ip
# Add evaluation to change homeip if the result we return is a IPv6 address.
if ($homeip.contains(':')){
  $homeip = "0.0.0.0/0"
}else{
  $homeip = "$homeip/32"
}
# Hotfix for mac
$profile = $null
$profile = $env:USERPROFILE
if (!($profile)) { $profile = $home }
# Create an SSH Key in azure acceptable format
if (!(test-path "$profile\.ssh\id_rsa.pub")){
  ssh-keygen -C $me -t rsa -b 4096 -f $profile\.ssh\id_rsa -N '""'
}

#####################################
## Functions to build environment
#####################################

Function Create-AzEnvironment($resourceGroupName, $Location, $location2) {
  $vnetName = 'my-virtual-network'
  $vnetName2 = 'Elk-network'
  $CIDRRange = '10.0.0.0/16'
  $CIDRRange2 = '10.1.0.0/16'
  $subnetname = 'default'
  $subnetname2 = 'basic'
  $subnet1 = '10.0.0.0/24'
  $subnet2 = '10.1.0.0/24'
  
  # Resource Group
  $rg = New-AzResourceGroup -Name $resourceGroupName `
    -Location $location

  # Subnet
  $Subnet = New-AzVirtualNetworkSubnetConfig `
    -Name $subnetname `
    -AddressPrefix $subnet1

  $Subnets = New-AzVirtualNetworkSubnetConfig `
    -Name $subnetname2 `
    -AddressPrefix $subnet2

  # Virtual Network
  $virtualNetwork = New-AzVirtualNetwork `
    -ResourceGroupName $resourceGroupName `
    -Location $location `
    -Name $vnetname `
    -AddressPrefix $CIDRRange `
    -Subnet $subnet

  # Virtual Network 2
  $virtualNetwork2 = New-AzVirtualNetwork `
    -ResourceGroupName $resourceGroupName `
    -Location $location2 `
    -Name $vnetName2 `
    -AddressPrefix $CIDRRange2 `
    -Subnet $Subnets
 
  #Initiate Peer
  $virtualNetwork = Get-AzVirtualNetwork `
    -ResourceGroupName $resourceGroupName `
    -Name $vnetname 

  $virtualNetwork2 = Get-AzVirtualNetwork `
    -resourcegroupname $resourceGroupName `
    -Name $vnetName2 

  # Peer VNet1 to VNet2
  $vpeer1 = Add-AzVirtualNetworkPeering `
    -Name 'Red-to-Elk' `
    -VirtualNetwork $virtualNetwork `
    -RemoteVirtualNetworkId $virtualNetwork2.Id 

  # Peer VNet2 to VNet1.
  $vpeer2 = Add-AzVirtualNetworkPeering  `
    -Name 'Elk-to-Red' `
    -VirtualNetwork $virtualNetwork2 `
    -RemoteVirtualNetworkId $virtualNetwork.Id 

  return @($virtualNetwork, $virtualNetwork2)
}

Function Create-CustomVM ($VMName, $location, $resourceGroupName, $availabilitySetName, $VirtualNetwork, $adminuser){

  $securityGroupName = "$VMName-security-group"
  $NICName = "$VMName-NIC"
  $computerName = $VMName
  $PublicIPAddressName = "$VMName-public-ip"
  $vmsize = 'Standard_B1ms'
 
  if ($vmname -eq 'Elk-Server'){
    $vmsize = 'Standard_B2s' 
  }

  $vmpublisher = 'Canonical'
  $vmoffer = 'UbuntuServer'
  $vmskus = '18.04-LTS'
  $AdminPassword = ConvertTo-SecureString "p4ssw0rd*" -AsPlainText -Force
  $Credential = New-Object System.Management.Automation.PSCredential ($AdminUser, $AdminPassword);

  # Security Group Config
  $rule1 = New-AzNetworkSecurityRuleConfig -Name "ssh-rule" `
    -Description "Allow SSH from Home IP" `
    -Access Allow `
    -Protocol Tcp `
    -Direction Inbound `
    -Priority 100 `
    -SourceAddressPrefix "$homeip" `
    -SourcePortRange * `
    -DestinationAddressPrefix * `
    -DestinationPortRange 22

  #Security Group
  $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName `
    -Location $Location `
    -Name $securityGroupName `
    -SecurityRules $rule1

  # Network Interface
  $NIC = New-AzNetworkInterface -Name $NICName `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -SubnetId $virtualNetwork.Subnets[0].Id

  # Public IP Address
  $PIP = New-AzPublicIpAddress -Name $PublicIPAddressName `
    -ResourceGroupName $resourceGroupName `
    -AllocationMethod Dynamic `
    -Location $Location

  # Attach Public IP to NIC
  $nic | Set-AzNetworkInterfaceIpConfig -Name $($nic.IpConfigurations.name) `
    -PublicIPAddress $pip `
    -Subnet $Subnets | Out-Null
  $nic | Set-AzNetworkInterface | out-null


  if ($availabilitySetName -ne $null){
    $availabilityset = Get-AzAvailabilitySet -name $availabilitySetName
    if (!($availabilityset)){
      $availabilityset = New-AzAvailabilitySet -Name "$availabilitySetName" `
        -ResourceGroupName $resourceGroupName `
        -Location $Location `
        -PlatformFaultDomainCount 2 `
        -PlatformUpdateDomainCount 2 `
        -Sku Aligned
    }

    # Virtual Machine Config
    $VirtualMachine = New-AzVMConfig -VMName $VMName `
      -VMSize $vmsize `
      -AvailabilitySetId $availabilityset.id
  }
  else {
    # Virtual Machine Config
    $VirtualMachine = New-AzVMConfig -VMName $VMName `
      -VMSize $vmsize
    
    
  }



  # Operating System Config
  $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine `
    -Linux -ComputerName $computerName `
    -Credential $Credential `
    -DisablePasswordAuthentication 

  # Attach Network Interface
  $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine `
    -Id $nic.Id 

  # Set Source Image
  $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine `
    -PublisherName $vmpublisher `
    -Offer $vmoffer `
    -Skus $vmskus `
    -Version latest 

  # Turn off Boot Diagnostics 
  $VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine `
    -Disable

  # Retrieve SSH Key data
  $sshPublicKey = Get-Content "$profile\.ssh\id_rsa.pub"

  # Add it to virtual machine config settings
  $VirtualMachine = Add-AzVMSshPublicKey -VM $VirtualMachine `
    -KeyData $sshpublickey `
    -Path "/home/$AdminUser/.ssh/authorized_keys"

  # Create Virtual Machine
  $vm = New-AzVM -ResourceGroupName $ResourceGroupName `
    -Location $location `
    -VM $VirtualMachine `
    -Verbose `
    -AsJob

  if ($availabilitySetName -ne $null) {
    return @{username = $AdminUser ; availabilityset = $availabilityset }
  }
  else {
    return @{username = $AdminUser }
  }
}
# Custom Function to run Remote Bash Commands
Function Run-AZRemoteBash($Script, $VMName, $ResourceGroupName, [switch]$AsJob){
  $myscript = @"
$script
"@
  set-content -Path "./temp-file.sh" -Value $myscript
  $scriptpath = Get-Item -Path "./temp-file.sh"
  if($AsJob){
    Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName `
      -VMName $vmName `
      -CommandId 'RunShellScript' `
      -ScriptPath "$($scriptpath.FullName)" `
      -AsJob
  }else{
    Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName `
      -VMName $vmName `
      -CommandId 'RunShellScript' `
      -ScriptPath "$($scriptpath.FullName)"
  }
  remove-item "./temp-file.sh"
}

Function Create-CustomLoadbalancer ($Name, $Protocol, $HealthCheckProtocol, $InsidePort, $OutsidePort, $HealthCheckPath, $ResourceGroupName, $Location) {
  $lbpublicip = New-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name "$Name-PublicIp" -Location $location -AllocationMethod "Dynamic"
  $frontend = New-AzLoadBalancerFrontendIpConfig -Name "$Name-FrontEnd" -PublicIpAddress $lbpublicip
  $backendAddressPool = New-AzLoadBalancerBackendAddressPoolConfig -Name "$Name-backendpool"
  $probe = New-AzLoadBalancerProbeConfig -Name "$Name-Probe" -Protocol $healthcheckprotocol -Port $insideport -IntervalInSeconds 15 -ProbeCount 2 -RequestPath $healthcheckpath
  # $inboundNatRule1 = New-AzLoadBalancerInboundNatRuleConfig -Name "$Name-NATRule" -FrontendIpConfiguration $frontend -Protocol $protocol -FrontendPort $outsideport -BackendPort $outsideport -IdleTimeoutInMinutes 15 -EnableFloatingIP
  $lbrule = New-AzLoadBalancerRuleConfig -Name "$Name-rule" -FrontendIpConfiguration $frontend -BackendAddressPool $backendAddressPool -Probe $probe -Protocol $protocol -FrontendPort $outsideport -BackendPort $insideport -IdleTimeoutInMinutes 15 -EnableFloatingIP -LoadDistribution SourceIPProtocol
  $lb = New-AzLoadBalancer -Name $Name -ResourceGroupName $resourceGroupName -Location $location -FrontendIpConfiguration $frontend -BackendAddressPool $backendAddressPool -Probe $probe -InboundNatRule $inboundNatRule1 -LoadBalancingRule $lbrule
  return $(Get-AzLoadBalancer -Name $Name -ResourceGroupName $resourceGroupName)
}

Function Add-NicToLoadBalancer($NetworkInterface, $BackendPoolConfig) {
  $NetworkInterface | Set-AzNetworkInterfaceIpConfig -Name $($NetworkInterface.IpConfigurations.name) -LoadBalancerBackendAddressPool $BackendPoolConfig | Out-Null
  $NetworkInterface | Set-AzNetworkInterface -AsJob | Out-Null
}




########################
## Build Our Stuff
########################
Write-Host 'Building the Network...' -ForegroundColor Yellow
#Build the network
$virtualnetworks = Create-AzEnvironment -resourceGroupName $resourceGroupName -location $location -location2 $location2
Write-Host 'Network Build Complete.' -ForegroundColor Green
$virtualnetwork = $virtualnetworks[0]
$virtualNetwork2 = $virtualnetworks[1]

Write-Host 'Starting VM Build Jobs...' -ForegroundColor Yellow
# Building the VMs
$results = @{}
$results[$vm1] = Create-CustomVM -VMName $vm1 -location $Location -resourceGroupName $resourceGroupName -VirtualNetwork $virtualNetwork -adminuser $adminuser
Write-Host 'Job 1 Started...' -ForegroundColor Yellow
$results[$vm2] = Create-CustomVM -VMName $vm2 -location $Location -resourceGroupName $resourceGroupName -VirtualNetwork $virtualNetwork -adminuser $adminuser -availabilitySetName 'RedTeamAS'
Write-Host 'Job 2 Started...' -ForegroundColor Yellow
$results[$vm3] = Create-CustomVM -VMName $vm3 -location $Location -resourceGroupName $resourceGroupName -VirtualNetwork $virtualNetwork -adminuser $adminuser -availabilitySetName 'RedTeamAS'
Write-Host 'Job 3 Started...' -ForegroundColor Yellow
$results[$vm4] = Create-CustomVM -VMName $vm4 -location $location2 -resourceGroupName $resourceGroupName -VirtualNetwork $virtualNetwork2 -adminuser $adminuser 
Write-Host 'Job 4 Started...' -ForegroundColor Yellow

$vmtable = Get-AzVM
$vmlist = $vmtable.name
$WantedVms = @($vm1, $vm2, $vm3, $vm4)
$check = $WantedVms | Where-Object -FilterScript { $_ -notin $vmlist }
if ($check){
  $check
  break
}


# Wait for completion of vms.
Write-Host "Waiting for VM Builds to Complete..." -ForegroundColor Yellow
$i = 0
while($i -lt 3){
  $i = 0
  $stats = Get-AzVM
  $status1 = $stats | where {$_.name -eq $vm1}
  if($status1.ProvisioningState -eq 'Succeeded'){$i++}
  $status2 = $stats | where {$_.name -eq $vm2}
  if($status2.ProvisioningState -eq 'Succeeded'){$i++}
  $status3 = $stats | where {$_.name -eq $vm3}
  if($status3.ProvisioningState -eq 'Succeeded'){$i++}
  start-sleep 5
}
Write-Host "Finished Building VMs." -ForegroundColor Green

$vm1ip = Get-AzNetworkInterface -Name "$VM1-NIC" -ResourceGroupName $resourceGroupName | Get-AzNetworkInterfaceIpConfig | select -ExpandProperty PrivateIpAddress
$vm2ip = Get-AzNetworkInterface -Name "$VM2-NIC" -ResourceGroupName $resourceGroupName | Get-AzNetworkInterfaceIpConfig | select -ExpandProperty PrivateIpAddress
$vm3ip = Get-AzNetworkInterface -Name "$VM3-NIC" -ResourceGroupName $resourceGroupName | Get-AzNetworkInterfaceIpConfig | select -ExpandProperty PrivateIpAddress
$vm4ip = Get-AzNetworkInterface -Name "$VM4-NIC" -ResourceGroupName $resourceGroupName | Get-AzNetworkInterfaceIpConfig | select -ExpandProperty PrivateIpAddress
######################
## Configure VM1
######################
Write-Host "Configuring VMs and Ansible" -ForegroundColor Yellow
Write-Host "Configuring VM 1" -ForegroundColor Yellow
$installscript = @'
apt-get update && apt install docker.io -y && service docker start && docker pull cyberxsecurity/ansible && exit
'@
Run-AZRemoteBash -Script $installscript `
 -VMName $vm1 `
 -ResourceGroupName $resourceGroupName
Write-Host "VM1 Configuration Complete." -ForegroundColor Green
######################
## Configure Ansible
######################
$sshPrivateKey = Get-Content "$profile\.ssh\id_rsa"
$sshPrivateKey = $sshPrivateKey -replace("`r`n", "`n") | out-string
$sshPublicKey = Get-Content "$profile\.ssh\id_rsa.pub"

$playbook = @"
---
  - name: Config Web VM with Docker
    hosts: webservers
    tasks:
    - name: docker.io
      become: true
      apt:
        name: docker.io
        state: present
        update_cache: yes

    - name: Install pip
      become: true
      apt:
        name: python3-pip
        state: present
        update_cache: yes

    - name: Install Docker python module
      pip:
        name: docker
        state: present
      become: true

    - name: download and launch a docker web container
      become: true
      docker_container:
        name: dvwa
        image: cyberxsecurity/dvwa
        state: started
        published_ports: 80:80
"@


$dockerscript = "ansible-playbook /etc/ansible/dvwa-playbook.yml --user $adminuser -vvv"
$createpersistence = @"
echo "[webservers]" > /home/$AdminUser/hosts && \
echo "$vm2ip" >> /home/$AdminUser/hosts && \
echo "$vm3ip" >> /home/$AdminUser/hosts && \
echo "[default]" > /home/$AdminUser/ansible.cfg && \
echo "remote_user = $AdminUser" >> /home/$AdminUser/ansible.cfg && \
echo "$sshPrivateKey" > /home/$AdminUser/.ssh/id_rsa && \
echo "$sshPublicKey" > /home/$AdminUser/.ssh/id_rsa.pub && \
sudo chmod 600 /home/$AdminUser/.ssh/* && \
sudo chown $($AdminUser + ":" +$AdminUser) /home/$AdminUser/.ssh/* && \
echo "$playbook" > /home/$AdminUser/dvwa-playbook.yml && \
mkdir -p /home/$AdminUser/roles && \
sudo docker container run --rm -it --mount type=bind,source="/home/$AdminUser/",target=/etc/ansible/ --mount type=bind,source="/home/$AdminUser/.ssh/",target=/root/.ssh/ cyberxsecurity/ansible $dockerscript
exit
"@

Run-AZRemoteBash -Script $createpersistence -VMName $vm1 -resourcegroupname $resourcegroupname

Write-Host "Completed VMs and Ansible" -ForegroundColor Green

#########################
## Create LoadBalancer
#########################
Write-Host "Building Loadbalancer..." -ForegroundColor Yellow

$loadbalancer = Create-CustomLoadbalancer `
  -Name $lbname `
  -Protocol $protocol `
  -InsidePort $insideport `
  -OutsidePort $outsideport `
  -HealthCheckProtocol $healthcheckprotocol `
  -HealthCheckPath $healthcheckpath `
  -Location $location `
  -ResourceGroupName $resourceGroupName


##############################
## Attach VMs to LoadBalancer
##############################
$vms = Get-AZVm
$VMsToLoadbalance = $vms | where { $_.name -like 'DVWA-*' }
foreach ($VM in $VMsToLoadbalance){
  $nic = Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces.id
  Add-NicToLoadBalancer -NetworkInterface $nic -BackendPoolConfig $loadbalancer.BackendAddressPools | out-null
}

Write-Host "Loadbalancer Complete." -ForegroundColor Green

Write-Host "Build Complete." -ForegroundColor Green
$results = @{}
$vms | % {
  $results[$_.Name] = @{}
  $results[$_.Name]['publicip'] = $(Get-AzPublicIpAddress -Name "$($_.name)-public-ip" | Select-Object -ExpandProperty IpAddress)
  $results[$_.Name]['username'] = 'AzureAdmin'
}



##############################
## Finish
##############################
Write-Host "##############################`n## Results                       `n##############################" -ForegroundColor Blue
Write-Host "VM1: [$vm1][$vm1ip] - $adminuser@$($results[$vm1]['publicip'])" -ForegroundColor Green
Write-Host "VM2: [$vm2][$vm2ip] - $adminuser@$($results[$vm2]['publicip'])" -ForegroundColor Green
Write-Host "VM3: [$vm3][$vm3ip] - $adminuser@$($results[$vm3]['publicip'])" -ForegroundColor Green
Write-Host "VM4: [$vm4][$vm4ip] - $adminuser@$($results[$vm4]['publicip'])" -ForegroundColor Green