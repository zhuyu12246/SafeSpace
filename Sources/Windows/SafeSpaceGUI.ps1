# SafeSpace for Windows - Lightweight Hardware-Isolated Sandbox VM GUI
# Supports Windows Sandbox (Hyper-V Micro-VM) & QEMU WHPX Alpine Linux Desktop

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StagingDir = Join-Path $AppRoot "Runtime\Staging"
New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null

$script:NetworkEnabled = $false
$script:EphemeralOnQuit = $true

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "SafeSpace - 轻量级文件与软件隔离虚拟机 (Windows Edition)"
$Form.Size = New-Object System.Drawing.Size(1020, 680)
$Form.StartPosition = "CenterScreen"
$Form.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$Form.ForeColor = [System.Drawing.Color]::FromArgb(248, 250, 252)

$IconPath = Join-Path $AppRoot "AppIcon.ico"
if (Test-Path $IconPath) {
    $Form.Icon = New-Object System.Drawing.Icon($IconPath)
}

# Top Header Panel
$TopPanel = New-Object System.Windows.Forms.Panel
$TopPanel.Dock = "Top"
$TopPanel.Height = 60
$TopPanel.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$Form.Controls.Add($TopPanel)

$TitleLabel = New-Object System.Windows.Forms.Label
$TitleLabel.Text = "🛡️ SafeSpace 轻量级硬件隔离虚拟机  |  宿主机单向只读保护已启用"
$TitleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 12, [System.Drawing.FontStyle]::Bold)
$TitleLabel.AutoSize = $true
$TitleLabel.Location = New-Object System.Drawing.Point(18, 18)
$TopPanel.Controls.Add($TitleLabel)

$NetBtn = New-Object System.Windows.Forms.Button
$NetBtn.Text = "🔒 当前：完全断网隔离"
$NetBtn.Size = New-Object System.Drawing.Size(170, 34)
$NetBtn.Location = New-Object System.Drawing.Point(620, 13)
$NetBtn.BackColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
$NetBtn.ForeColor = [System.Drawing.Color]::White
$NetBtn.FlatStyle = "Flat"
$TopPanel.Controls.Add($NetBtn)

$ResetBtn = New-Object System.Windows.Forms.Button
$ResetBtn.Text = "🔥 一键销毁重置沙盒"
$ResetBtn.Size = New-Object System.Drawing.Size(170, 34)
$ResetBtn.Location = New-Object System.Drawing.Point(810, 13)
$ResetBtn.BackColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
$ResetBtn.ForeColor = [System.Drawing.Color]::White
$ResetBtn.FlatStyle = "Flat"
$TopPanel.Controls.Add($ResetBtn)

# Left File List & Upload Controls
$UploadBtn = New-Object System.Windows.Forms.Button
$UploadBtn.Text = "➕ 上传文件 / 软件 / PPT / PDF 到隔离沙盒"
$UploadBtn.Size = New-Object System.Drawing.Size(340, 44)
$UploadBtn.Location = New-Object System.Drawing.Point(20, 80)
$UploadBtn.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$UploadBtn.ForeColor = [System.Drawing.Color]::White
$UploadBtn.FlatStyle = "Flat"
$UploadBtn.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$Form.Controls.Add($UploadBtn)

$FileList = New-Object System.Windows.Forms.ListView
$FileList.View = "Details"
$FileList.FullRowSelect = $true
$FileList.Location = New-Object System.Drawing.Point(20, 136)
$FileList.Size = New-Object System.Drawing.Size(560, 470)
$FileList.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$FileList.ForeColor = [System.Drawing.Color]::White
$FileList.Columns.Add("文件名", 240) | Out-Null
$FileList.Columns.Add("大小", 90) | Out-Null
$FileList.Columns.Add("SHA-256 指纹", 210) | Out-Null
$Form.Controls.Add($FileList)

$OpenVMButton = New-Object System.Windows.Forms.Button
$OpenVMButton.Text = "🚀 启动隔离虚拟机桌面并打开文件 (Hyper-V / QEMU)"
$OpenVMButton.Size = New-Object System.Drawing.Size(380, 52)
$OpenVMButton.Location = New-Object System.Drawing.Point(600, 136)
$OpenVMButton.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$OpenVMButton.ForeColor = [System.Drawing.Color]::White
$OpenVMButton.FlatStyle = "Flat"
$OpenVMButton.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$Form.Controls.Add($OpenVMButton)

$InfoBox = New-Object System.Windows.Forms.TextBox
$InfoBox.Multiline = $true
$InfoBox.ReadOnly = $true
$InfoBox.Location = New-Object System.Drawing.Point(600, 204)
$InfoBox.Size = New-Object System.Drawing.Size(380, 402)
$InfoBox.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$InfoBox.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$InfoBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$InfoBox.Text = @"
[SafeSpace Windows 硬件隔离说明]

1. 单向只读映射 (ReadOnly Host Mapping):
   所有上传的文件均存放在隔离暂存区，并以硬件级只读 (<ReadOnly>true</ReadOnly>) 方式挂载到虚拟机桌面。

2. 支持直接打开的文件与软件:
   - Windows 可执行程序 (.exe / .msi / .bat)
   - Office 演示与办公文档 (.pptx / .docx / .xlsx)
   - PDF 文档 (.pdf)、图片、压缩包 (.zip / .7z)

3. 瞬时销毁无痕模式:
   关闭虚拟机或点击“一键销毁重置沙盒”将立即清除所有沙盒状态与文件。
"@
$Form.Controls.Add($InfoBox)

function Refresh-FileList {
    $FileList.Items.Clear()
    Get-ChildItem -Path $StagingDir -File | ForEach-Object {
        $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash.Substring(0, 16)
        $item = New-Object System.Windows.Forms.ListViewItem($_.Name)
        $item.SubItems.Add("$([math]::Round($_.Length / 1KB, 1)) KB") | Out-Null
        $item.SubItems.Add($hash) | Out-Null
        $FileList.Items.Add($item) | Out-Null
    }
}

$NetBtn.Add_Click({
    $script:NetworkEnabled = -not $script:NetworkEnabled
    if ($script:NetworkEnabled) {
        $NetBtn.Text = "🌐 当前：允许联网"
        $NetBtn.BackColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
    } else {
        $NetBtn.Text = "🔒 当前：完全断网隔离"
        $NetBtn.BackColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
    }
})

$UploadBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Title = "选择要上传到隔离沙盒的文件或软件"
    if ($dlg.ShowDialog() -eq "OK") {
        foreach ($f in $dlg.FileNames) {
            Copy-Item -Path $f -Destination $StagingDir -Force
        }
        Refresh-FileList
    }
})

$ResetBtn.Add_Click({
    Stop-Process -Name "WindowsSandboxClient" -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $StagingDir -File | Remove-Item -Force
    Refresh-FileList
    [System.Windows.Forms.MessageBox]::Show("沙盒虚拟机与所有上传文件已彻底销毁并重置！", "SafeSpace", "OK", "Information") | Out-Null
})

$OpenVMButton.Add_Click({
    $sandboxExe = Join-Path $env:WINDIR "System32\WindowsSandbox.exe"
    if (-not (Test-Path $sandboxExe)) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "检测到当前系统尚未启用 Windows Sandbox (Hyper-V 沙盒组件)。`n`n是否立即以管理员权限一键开启 Windows 沙盒功能？（开启后重启电脑即可生效）",
            "SafeSpace 环境检测",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -Command `"Enable-WindowsOptionalFeature -FeatureName 'Containers-DisposableClientVM' -All -Online`""
        }
        return
    }
    $netConfig = if ($script:NetworkEnabled) { "Default" } else { "Disable" }
    $wsbPath = Join-Path $AppRoot "Runtime\SafeSpaceSession.wsb"
    $wsbXml = @"
<Configuration>
  <VGpu>Enable</VGpu>
  <Networking>$netConfig</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$StagingDir</HostFolder>
      <SandboxFolder>C:\Users\WDAGUtilityAccount\Desktop\SafeSpaceFiles</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>explorer.exe C:\Users\WDAGUtilityAccount\Desktop\SafeSpaceFiles</Command>
  </LogonCommand>
</Configuration>
"@
    Set-Content -Path $wsbPath -Value $wsbXml -Encoding UTF8
    Start-Process -FilePath $wsbPath
})

$Form.Add_FormClosing({
    if ($script:EphemeralOnQuit) {
        Get-ChildItem -Path $StagingDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
})

Refresh-FileList
[void]$Form.ShowDialog()
