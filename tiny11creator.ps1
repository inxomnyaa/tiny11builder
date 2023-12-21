#Defining preferences variables
Write-Output "Loading configuration from config.json..."
$config = (Get-Content "config.json" -Raw) | ConvertFrom-Json
$wantedImageName = $config.WantedWindowsEdition
$unwantedProvisionedPackages = $config.ProvisionedPackagesToRemove
$unwantedWindowsPackages = $config.WindowsPackagesToRemove
$pathsToDelete = $config.PathsToDelete
$windowsIsoDownloaderReleaseUrl = $config.WindowsIsoDownloaderReleaseUrl
$skipIsoDownload = $config.SkipIsoDownload
$isoInputFolder = $config.Windows11IsoInputFolder
$isoOutputFolder = $config.Tiny11IsoOutputFolder

#Defining system variables
Write-Output "Creating needed variables..."
$rootWorkdir = "c:\tiny11\"
$isoFolder = $rootWorkdir + "iso\"
$installImageFolder = $rootWorkdir + "installimage\"
$bootImageFolder = $rootWorkdir + "bootimage\"
$toolsFolder = $rootWorkdir + "tools\"
$isoPath = "c:\windows11.iso"
$yes = (cmd /c "choice <nul 2>nul")[1]
#The $yes variable gets the "y" from "yes" (or corresponding letter in the language your computer is using).
#It is used to answer automatically to the "takeown" command, because the answer choices are localized which is not handy at all.
# Specify the full path for the output ISO file
$isoOutputPath = Join-Path $isoOutputFolder "tiny11.iso"
# Temporary variable to track if we found & selected / downloaded an iso
$gotIso = $false

mkdir $rootWorkdir | Out-Null
mkdir ($toolsFolder + "WindowsIsoDownloader\") | Out-Null
mkdir $isoOutputFolder -Force | Out-Null

# Try skipping download and scan folder for .iso
if ($skipIsoDownload -eq $true) {
    Write-Output "Skipping iso download... Scanning $((Get-Item -LiteralPath $isoInputFolder).FullName) for .iso files..."
    
    # Get all .iso files in the specified folder
    $isoFiles = Get-ChildItem -Path $isoInputFolder -Filter *.iso

    # Check if there are multiple .iso files
    if ($isoFiles.Count -eq 0) {
        Write-Host "No .iso files found in the specified folder... Downloading using WindowsIsoDownloader instead..."
        $skipIsoDownload = $false
        $gotIso = $false
    }
    elseif ($isoFiles.Count -eq 1) {
        # If only one .iso file is found, copy it to the destination path
        Write-Host "ISO file found, copying $($isoFiles[0].FullName) to $isoPath"
        Copy-Item -Path $isoFiles[0].FullName -Destination $isoPath -Force
        Write-Host "ISO file copied to $isoPath"
        $gotIso = $true
    }
    else {
        # If multiple .iso files are found, prompt the user to select one
        Write-Host "Multiple .iso files found. Please select one:"
    
        for ($i = 0; $i -lt $isoFiles.Count; $i++) {
            Write-Host "$($i + 1): $($isoFiles[$i].Name)"
        }

        $selectedIndex = Read-Host "Enter the number of the .iso file to copy"

        if ($selectedIndex -ge 1 -and $selectedIndex -le $isoFiles.Count) {
            $selectedIso = $isoFiles[$selectedIndex - 1]
            Copy-Item -Path $selectedIso.FullName -Destination $isoPath -Force
            Write-Host "Selected ISO file '$($selectedIso.Name)' copied to $isoPath"
            $gotIso = $true
        }
        else {
            Write-Host "Invalid selection. Please enter a valid number."
        }
    }
}

# If we haven't gotten an iso file yet, try downloading it via WindowsIsoDownloader
if ($gotIso -eq $false) {# -or $skipIsoDownload -eq $true
    Write-Output "Downloading WindowsIsoDownloader release from GitHub..."
    Invoke-WebRequest -Uri $windowsIsoDownloaderReleaseUrl -OutFile WindowsIsoDownloader.zip
    Write-Output "Extracting WindowsIsoDownloader release..."
    Expand-Archive -Path WindowsIsoDownloader.zip -DestinationPath ($toolsFolder + "WindowsIsoDownloader\")
    Remove-Item WindowsIsoDownloader.zip | Out-Null

    #Downloading the Windows 11 ISO using WindowsIsoDownloader
    Write-Output "Downloading Windows 11 iso file from Microsoft using WindowsIsoDownloader..."
    $isoDownloadProcess = (Start-Process ($toolsFolder + "WindowsIsoDownloader\WindowsIsoDownloader.exe") -NoNewWindow -Wait -WorkingDirectory ($toolsFolder + "WindowsIsoDownloader\") -PassThru)
    if($isoDownloadProcess.ExitCode -eq 0){
        $gotIso = $true
    }
}

if ($gotIso -eq $true) {
	#Mount the Windows 11 ISO
	Write-Output "Mounting the original iso..."
	$mountResult = Mount-DiskImage -ImagePath $isoPath
	$isoDriveLetter = ($mountResult | Get-Volume).DriveLetter

	#Creating needed temporary folders
	Write-Output "Creating temporary folders..."
	mkdir $isoFolder | Out-Null
	mkdir $installImageFolder | Out-Null
	mkdir $bootImageFolder | Out-Null

	#Copying the ISO files to the ISO folder
	Write-Output "Copying the content of the original iso to the work folder..."
	Copy-Item -Recurse ($isoDriveLetter + ":\*") $isoFolder | Out-Null

	#Unmounting the original ISO since we don't need it anymore (we have a copy of the content)
	Write-Output "Unmounting the original iso..."
	Dismount-DiskImage -ImagePath $isoPath | Out-Null

	################# Beginning of install.wim patches ##################
	#Getting the wanted image index
	$wantedImageIndex = Get-WindowsImage -ImagePath ($isoFolder + "sources\install.wim") | where-object { $_.ImageName -eq $wantedImageName } | Select-Object -ExpandProperty ImageIndex

	#Mounting the WIM image
	Write-Output "Mounting the install.wim image..."
	Set-ItemProperty -Path ($isoFolder + "sources\install.wim") -Name IsReadOnly -Value $false | Out-Null
	Mount-WindowsImage -ImagePath ($isoFolder + "sources\install.wim") -Path $installImageFolder -Index $wantedImageIndex | Out-Null

	#Detecting Provisioned app packages
	Write-Output "Removing unwanted app packages from the install.wim image..."
	$detectedProvisionedPackages = Get-AppxProvisionedPackage -Path $installImageFolder

	#Removing unwanted Provisioned app packages
	foreach ($detectedProvisionedPackage in $detectedProvisionedPackages) {
		foreach ($unwantedProvisionedPackage in $unwantedProvisionedPackages) {
			if ($detectedProvisionedPackage.PackageName.Contains($unwantedProvisionedPackage)) {
				Remove-AppxProvisionedPackage -Path $installImageFolder -PackageName $detectedProvisionedPackage.PackageName -ErrorAction SilentlyContinue | Out-Null
			}
		}
	}

	#Detecting windows packages
	Write-Output "Removing unwanted windows packages from the install.wim image..."
	$detectedWindowsPackages = Get-WindowsPackage -Path $installImageFolder

	#Removing unwanted windows packages
	foreach ($detectedWindowsPackage in $detectedWindowsPackages) {
		foreach ($unwantedWindowsPackage in $unwantedWindowsPackages) {
			if ($detectedWindowsPackage.PackageName.Contains($unwantedWindowsPackage)) {
				Remove-WindowsPackage -Path $installImageFolder -PackageName $detectedWindowsPackage.PackageName -ErrorAction SilentlyContinue | Out-Null
			}
		}
	}

	Write-Output "Deleting PathsToDelete from the install.wim image..."
	foreach ($pathToDelete in $pathsToDelete) {
		$fullpath = ($installImageFolder + $pathToDelete.Path)

		if ($pathToDelete.IsFolder -eq $true) {
			takeown /f $fullpath /r /d $yes | Out-Null
			icacls $fullpath /grant ("$env:username"+":F") /T /C | Out-Null
			Remove-Item -Force $fullpath -Recurse -ErrorAction SilentlyContinue | Out-Null
		} else {
			takeown /f $fullpath | Out-Null
			icacls $fullpath /grant ("$env:username"+":F") /T /C | Out-Null
			Remove-Item -Force $fullpath -ErrorAction SilentlyContinue | Out-Null
		}
	}

	# Loading the registry from the mounted WIM image
	Write-Output "Patching the registry in the install.wim image..."
	reg load HKLM\installwim_COMPONENTS ($installImageFolder + "Windows\System32\config\COMPONENTS") | Out-Null
	Write-Output "-"
	reg load HKLM\installwim_DEFAULT ($installImageFolder + "Windows\System32\config\default") | Out-Null
	Write-Output "-"
	reg load HKLM\installwim_NTUSER ($installImageFolder + "Users\Default\ntuser.dat") | Out-Null
	Write-Output "-"
	reg load HKLM\installwim_SOFTWARE ($installImageFolder + "Windows\System32\config\SOFTWARE") | Out-Null
	Write-Output "-"
	reg load HKLM\installwim_SYSTEM ($installImageFolder + "Windows\System32\config\SYSTEM") | Out-Null
	Write-Output "-"

	Write-Output "-"
	# Applying registry patches on the system image
	Write-Output "-"
	# tiny11_installwim_patches.reg matches the patches from the original ntdev/tiny11builder
	Write-Output "-"
	# user_installwim_patches.reg is for customized patches
	Write-Output "-"
	regedit /s ./tools/tiny11_installwim_patches.reg | Out-Null
	Write-Output "-"
	$userWimPatches = "./tools/user_installwim_patches.reg"
	Write-Output "-"
	if (Test-Path $userWimPatches) {
	Write-Output "-if"
		regedit /s $userWimPatches | Out-Null
	Write-Output "-"
	} else {
	Write-Output "-else"
		Write-Host "No user patches for install.wim found (Registry file $userWimPatches not found)"
	Write-Output "-"
	}
	Write-Output "-"

	Write-Output "-"
	# Unloading the registry
	Write-Output "-"
	reg unload HKLM\installwim_COMPONENTS | Out-Null
	Write-Output "-"
	reg unload HKLM\installwim_DRIVERS | Out-Null
	Write-Output "-"
	reg unload HKLM\installwim_DEFAULT | Out-Null
	Write-Output "-"
	reg unload HKLM\installwim_NTUSER | Out-Null
	Write-Output "-"
	reg unload HKLM\installwim_SCHEMA | Out-Null
	Write-Output "-"
	reg unload HKLM\installwim_SOFTWARE | Out-Null
	Write-Output "-"
	reg unload HKLM\installwim_SYSTEM | Out-Null
	Write-Output "-"
	
	#Copying the setup config file
	Write-Output "Placing the autounattend.xml file in the install.wim image..."
	[System.IO.File]::Copy((Get-ChildItem .\tools\autounattend.xml).FullName, ($installImageFolder + "Windows\System32\Sysprep\autounattend.xml"), $true) | Out-Null

	#Unmount the install.wim image
	Write-Output "Unmounting the install.wim image..."
	Dismount-WindowsImage -Path $installImageFolder -Save | Out-Null

	#Moving the wanted image index to a new image
	Write-Output "Creating a clean install.wim image without all unnecessary indexes..."
	Export-WindowsImage -SourceImagePath ($isoFolder + "sources\install.wim") -SourceIndex $wantedImageIndex -DestinationImagePath ($isoFolder + "sources\install_patched.wim") -CompressionType max | Out-Null

	#Delete the old install.wim and rename the new one
	Remove-Item ($isoFolder + "sources\install.wim") | Out-Null
	Rename-Item -Path ($isoFolder + "sources\install_patched.wim") -NewName "install.wim" | Out-Null
	################# Ending of install.wim patches ##################

	################# Beginning of boot.wim patches ##################
	Set-ItemProperty -Path ($isoFolder + "sources\boot.wim") -Name IsReadOnly -Value $false | Out-Null
	Write-Output "Mounting the boot.wim image..."
	Mount-WindowsImage -ImagePath ($isoFolder + "sources\boot.wim") -Path $bootImageFolder -Index 2 | Out-Null

	Write-Output "Patching the registry in the boot.wim image..."
	reg load HKLM\bootwim_COMPONENTS ($bootImageFolder + "Windows\System32\config\COMPONENTS") | Out-Null
	reg load HKLM\bootwim_DEFAULT ($bootImageFolder + "Windows\System32\config\default") | Out-Null
	reg load HKLM\bootwim_NTUSER ($bootImageFolder + "Users\Default\ntuser.dat") | Out-Null
	reg load HKLM\bootwim_SOFTWARE ($bootImageFolder + "Windows\System32\config\SOFTWARE") | Out-Null
	reg load HKLM\bootwim_SYSTEM ($bootImageFolder + "Windows\System32\config\SYSTEM") | Out-Null

	# Applying registry patches on the boot image
	regedit /s ./tools/bootwim_patches.reg | Out-Null

	reg unload HKLM\bootwim_COMPONENTS | Out-Null
	reg unload HKLM\bootwim_DRIVERS | Out-Null
	reg unload HKLM\bootwim_DEFAULT | Out-Null
	reg unload HKLM\bootwim_NTUSER | Out-Null
	reg unload HKLM\bootwim_SCHEMA | Out-Null
	reg unload HKLM\bootwim_SOFTWARE | Out-Null
	reg unload HKLM\bootwim_SYSTEM | Out-Null

	#Unmount the boot.wim image
	Write-Output "Unmounting the boot.wim image..."
	Dismount-WindowsImage -Path $bootImageFolder -Save | Out-Null

	#Moving the wanted image index to a new image
	Write-Output "Creating a clean boot.wim image without all unnecessary indexes..."
	Export-WindowsImage -SourceImagePath ($isoFolder + "sources\boot.wim") -SourceIndex 2 -DestinationImagePath ($isoFolder + "sources\boot_patched.wim") -CompressionType max | Out-Null

	#Delete the old boot.wim and rename the new one
	Remove-Item ($isoFolder + "sources\boot.wim") | Out-Null
	Rename-Item -Path ($isoFolder + "sources\boot_patched.wim") -NewName "boot.wim" | Out-Null
	################# Ending of boot.wim patches ##################

	#Copying the setup config file to the iso copy folder
	[System.IO.File]::Copy((Get-ChildItem .\tools\autounattend.xml).FullName, ($isoFolder + "autounattend.xml"), $true) | Out-Null

	#Building the new trimmed and patched iso file
	Write-Output "Building the tiny11.iso file..."
	Write-Output ""
	.\tools\oscdimg.exe -m -o -u2 -udfver102 -bootdata:("2#p0,e,b" + $isoFolder + "boot\etfsboot.com#pEF,e,b" + $isoFolder + "efi\microsoft\boot\efisys.bin") $isoFolder $isoOutputPath | Out-Null
	Write-Output ""
    Write-Output "Complete! iso file written to: $((Get-Item -LiteralPath $isoOutputFolder).FullName)"
} else {
	Write-Output "Unable to build the tiny11 iso (an error occured while trying to download the original iso using WindowsIsoDownloader)."
}

#Cleaning the folders used during the process
Write-Output "Removing work folders..."
Remove-Item $isoPath -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item $rootWorkdir -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
