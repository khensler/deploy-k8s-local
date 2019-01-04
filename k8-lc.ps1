param (
    [string]$server=$null,
    [Parameter(Mandatory = $true)][string]$username,
    [SecureString]$password = $( Read-Host -asSecureString "Input password, please" ),
	[string]$nodes,
	[Parameter(Mandatory = $true)][string]$clusterName,
	[bool]$remove,
	[bool]$master,
	[Parameter(Mandatory = $true)][string]$clonefrom,
	[Parameter(Mandatory = $true)][string]$portGroup
)

function DoClone{
param([string]$cloneName,[string]$clonefrom)
Write-Host "Buidling $cloneName"

$sourceVM = Get-VM "$clonefrom" | Get-View
$cloneFolder = $sourceVM.parent
$cloneSpec = new-object Vmware.Vim.VirtualMachineCloneSpec
$cloneSpec.Snapshot = $sourceVM.Snapshot.CurrentSnapshot
$cloneSpec.Location = new-object Vmware.Vim.VirtualMachineRelocateSpec
$cloneSpec.Location.DiskMoveType = [Vmware.Vim.VirtualMachineRelocateDiskMoveOptions]::createNewChildDiskBacking


$task = $sourceVM.CloneVM_Task( $cloneFolder, $cloneName, $cloneSpec )

$clonetask = Get-View $task
while("running","queued" -contains $clonetask.Info.State){
  sleep 1
  $clonetask.UpdateViewData("Info.State")
}

Write-Host "Clone Done"


$vm = (get-vm $cloneName )

$out = ($vm | Set-Annotation -CustomAttribute "K8-Cluster" -Value $clusterName)

start-vm $vm | out-null
get-vm -name $vm | get-networkadapter | set-networkadapter -networkname (  Get-VirtualPortGroup -Name "$portGroup" -vmhost (get-vm $vm).vmhost.name) -connected $true -Confirm:$false  | out-null

Write-Host "Wait For VMware Tools"
wait-tools -VM (get-vm -name $vm) | out-null


#
do{
$name = (Get-view $vm).guest.hostname | out-null #need to wait here
}while ($name -eq "")

Write-Host "Wait for IP"
$ip = $null
do{
$vm = (get-vm $cloneName)
$ip = $vm.guest.IPAddress[0]
}while($ip -eq $null)
Write-host "$cloneName IP $ip"
Write-Host "Set Hostname"

return $vm
}

function DoInstall{
param([string]$cloneName,[string]$plainpassword,[string]$username,[bool]$master,$vm,[string]$joincmd,[string]$clusterName)
$script = "echo $plainpassword | /usr/bin/sudo -S hostnamectl set-hostname $cloneName &> /tmp/k8s-master.log"
Invoke-VMScript -VM $vm -ScriptType Bash -ScriptText $script -GuestUser $username -GuestPassword $plainpassword |out-null

Write-Host "Build Install Script"
$script = $script + @'
echo "Build Script" >> /tmp/k8s-master.log
echo "apt install docker.io -y" >> /tmp/k8s-master.sh
echo "systemctl enable docker" >> /tmp/k8s-master.sh
echo "curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add" >> /tmp/k8s-master.sh
echo "apt-add-repository \"deb http://apt.kubernetes.io/ kubernetes-xenial main\"" >> /tmp/k8s-master.sh
echo "apt install kubeadm -y" >> /tmp/k8s-master.sh
echo "swapoff -a" >> /tmp/k8s-master.sh
'@
if($master){

$script = $script +"`n"+ @'
echo "kubeadm init --pod-network-cidr=10.244.0.0/16" >> /tmp/k8s-master.sh
echo "chmod a+r /etc/kubernetes/admin.conf" >> /tmp/k8s-master.sh
echo "kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml" >> /tmp/k8s-master.sh
echo "kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/master-" >> /tmp/k8s-master.sh
echo "kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/google/metallb/v0.7.3/manifests/metallb.yaml" >> /tmp/k8s-master.sh
echo "kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/khensler/deploy-k8s-local/master/layer2-config.yaml" >> /tmp/k8s-master.sh
echo "kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml" >> /tmp/k8s-master.sh
echo "kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/khensler/deploy-k8s-local/master/service-loadbalancer.yaml" >> /tmp/k8s-master.sh
'@
$script = $script + "`n"+ 'echo "cp -i /etc/kubernetes/admin.conf /home/'+ $username+'/.kube/config" >> /tmp/k8s-master.sh' +"`n"
$script = $script + "`n"+ 'echo "chown -R '+ $username+":"+ $username+' /home/k8admin/.kube" >> /tmp/k8s-master.sh' +"`n"
}else{
$script = $script + "`necho `"$joincmd`" >> /tmp/k8s-master.sh`n"
}

Invoke-VMScript -VM $vm -ScriptType Bash -ScriptText $script -GuestUser $username -GuestPassword $plainpassword |out-null

Write-Host "Make +x"

$script = "chmod a+x /tmp/k8s-master.sh"

Invoke-VMScript -VM $vm -ScriptType Bash -ScriptText $script -GuestUser $username -GuestPassword $plainpassword |out-null

Write-Host "Execute Intall"

$script = "echo $plainpassword | /usr/bin/sudo -S /tmp/k8s-master.sh &>> /tmp/k8s-master.log"

if ($master){

Invoke-VMScript -VM $vm -ScriptType Bash -ScriptText $script -GuestUser $username -GuestPassword $plainpassword

Write-Host "Get Join Command" 

$script = "cat /tmp/k8s-master.log | grep kubeadm\ join"
 
$output = (Invoke-VMScript -VM $vm -ScriptType Bash -ScriptText $script -GuestUser $username -GuestPassword $plainpassword)


$joincmd = $output.ScriptOutput -replace '(^\s+|\s+$)','' -replace '\s+',' '

Write-Host "Join CMD: $joincmd"


$out = ($vm | Set-Annotation -CustomAttribute "K8-Role" -Value "Master")
$out = ($vm | Set-Annotation -CustomAttribute "K8-Join" -Value $joincmd)

Write-Host "Get config file"
Copy-VMGuestFile -Source /etc/kubernetes/admin.conf -Destination (((Get-Item -Path ".\").FullName)+"\$clusterName.conf") -VM $vm -GuestToLocal -GuestUser $username -GuestPassword $password
Write-Host "Config file at: "(((Get-Item -Path ".\").FullName)+"\$clusterName.conf")
}else{

Invoke-VMScript -VM $vm -ScriptType Bash -ScriptText $script -GuestUser $username -GuestPassword $plainpassword  -RunAsync| out-null
$out = ($vm | Set-Annotation -CustomAttribute "K8-Role" -Value "Node")
}

}

function DoRemove{
param([string]$plainpassword,[string]$username,[string]$clusterName,[string]$nodes,[bool]$master)
$mastervm = (get-vm  | Where{$_.CustomFields.Item("K8-Cluster") -eq $clusterName -and  $_.CustomFields.Item("K8-Role") -eq "Master"})
$vms= (get-vm  | Where{$_.CustomFields.Item("K8-Cluster") -eq $clusterName -and  $_.CustomFields.Item("K8-Role") -eq "Node"})
if($master){
	write-host "Removing all nodes from cluster $clusterName"
	$nodes = $vms.length
}else{
	Write-Host "Removing $nodes nodes from cluster $clusterName"
}
	for($i=0;$i -lt $nodes;$i++){
		$vm = $vms[$vms.length-$i-1]
		Write-Host "Remove node $vm from cluster"
		$script = "kubectl delete node "+$vm
		Invoke-VMScript -VM $mastervm -ScriptType Bash -ScriptText $script -GuestUser $username -GuestPassword $plainpassword -RunAsync |out-null
		Write-Host "Power off and delete $vm"
		$results = ($vms[$vms.length-$i-1] | stop-vm -Confirm:$false)
		$results = ($vms[$vms.length-$i-1] | remove-vm -DeletePermanently -Confirm:$false -RunAsync)
	}
if($master){
	write-host "Removing Master $master"
	$results = ($mastervm	| stop-vm -Confirm:$false)
	$results = ($mastervm | remove-vm -DeletePermanently -Confirm:$false)
	Write-Host "Cluster Deleted"
}
}

$Credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $username, $password
$plainpassword=$Credentials.GetNetworkCredential().Password
Import-Module VMware.PowerCLI



if($server) {connect-viserver $server}

$attrib = (New-CustomAttribute -TargetType "VirtualMachine" -Name "K8-Role" -ErrorAction SilentlyContinue)
$attrib = (New-CustomAttribute -TargetType "VirtualMachine" -Name "K8-Cluster" -ErrorAction SilentlyContinue)
$attrib = (New-CustomAttribute -TargetType "VirtualMachine" -Name "K8-Join" -ErrorAction SilentlyContinue)

$howmany=$nodes
$vms = get-vm | where-object { $_.Name -like "k8s-node-*" }
$names = $vms.name -replace 'k8s-node-(.*)','$1'
$max = $names | measure -maximum

$number = $max.maximum

if($remove){
	
	DoRemove -plainpassword $plainpassword -username $username -clusterName $clusterName -nodes $nodes -master $master
}else{

	Write-Host "Checking for existing cluster $cluserName"
	try {
			$joincmd = (get-vm  | Where{$_.CustomFields.Item("K8-Cluster") -eq $clusterName -and  $_.CustomFields.Item("K8-Role") -eq "Master"}).CustomFields.Item("K8-Join")
			Write-Host "Scaling Cluster $clusterName with $nodes mode nodes"
			$master=$false
		}catch{
			write-host "Cluster $clusterName not found building new cluster"
			$master=$true
		}

	write-host "Building $howmany nodes"

	for ($i = 0; $i -lt $howmany; $i++){
		$number++
		$cloneName = "k8s-node-$number"
		#$clonefrom = "ubuntu-18.0.4-lts"
		$vm = DoClone -cloneName $cloneName -clonefrom $clonefrom -portGroup $portGroup
		$results = DoInstall -cloneName $cloneName -plainpassword $plainpassword -username $username -master $master -vm $vm -joincmd $joincmd -clusterName $clusterName
		$master=$false
		$joincmd = (get-vm  | Where{$_.CustomFields.Item("K8-Cluster") -eq $clusterName -and  $_.CustomFields.Item("K8-Role") -eq "Master"}).CustomFields.Item("K8-Join")
	}
}
