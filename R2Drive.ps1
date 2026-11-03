#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Open','Configure','SelfTest','PasswordCommand')][string]$Mode='Open',
    [switch]$MountTest
)

if ($Mode -eq 'PasswordCommand') {
    [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
    [Console]::Write($env:RCLONE_CONFIG_PASS)
    return
}
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
$script:SourcePath=$PSCommandPath
$ErrorActionPreference = 'Stop'

function Get-RcloneBinary {
    $command = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $package = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Rclone.Rclone_Microsoft.Winget.Source_8wekyb3d8bbwe'
    $binary = Get-ChildItem -LiteralPath $package -Filter rclone.exe -Recurse | Select-Object -First 1
    if (-not $binary) { throw 'rclone is not installed.' }
    return $binary.FullName
}

function New-RandomSecret {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function ConvertTo-ProcessArguments([string[]]$Items) {
    return (($Items | ForEach-Object {
        if ($_ -match '[\s"]' -or $_ -eq '') {
            '"' + ([regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
        } else { $_ }
    }) -join ' ')
}

function New-RcloneProcess([string[]]$Arguments, [string]$ConfigPassword, [hashtable]$ExtraEnvironment = @{}) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Get-RcloneBinary
    $info.Arguments = ConvertTo-ProcessArguments $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $info.EnvironmentVariables['RCLONE_CONFIG_PASS'] = $ConfigPassword
    foreach ($key in $ExtraEnvironment.Keys) { $info.EnvironmentVariables[$key] = $ExtraEnvironment[$key] }
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $info
    [void]$proc.Start()
    return $proc
}

function Invoke-Rclone([string[]]$Arguments, [string]$ConfigPassword) {
    $proc = New-RcloneProcess $Arguments $ConfigPassword
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(120000)) { $proc.Kill(); throw 'rclone timed out.' }
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    if ($proc.ExitCode -ne 0) {
        throw ('rclone failed (exit ' + $proc.ExitCode + '). Check the connection, credentials and bucket. No secret values have been logged.')
    }
    return $stdout
}

function Initialize-EncryptedConfig([string]$ConfigPath, [string]$Password, [string]$ScriptPath) {
    if (Test-Path -LiteralPath $ConfigPath) { throw 'A configuration already exists. It has been preserved.' }
    [IO.File]::WriteAllText($ConfigPath, '', (New-Object Text.UTF8Encoding($false)))
    $passwordCommand = 'powershell.exe -NoProfile -NonInteractive -File "' + $ScriptPath + '" -Mode PasswordCommand'
    [void](Invoke-Rclone @('config','encryption','set','--config',$ConfigPath,'--password-command',$passwordCommand,'--ask-password=false') $Password)
    [void](Invoke-Rclone @('config','encryption','check','--config',$ConfigPath,'--ask-password=false') $Password)
}

function Add-EncryptedRemote([string]$ConfigPath, [string]$Password, [hashtable]$RawParameters, [string]$CryptPath) {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $rcPassword = New-RandomSecret
    $proc = New-RcloneProcess @('rcd','--config',$ConfigPath,'--rc-addr',"127.0.0.1:$port",'--log-level','ERROR','--ask-password=false') $Password @{
        RCLONE_RC_USER = 'local-setup'; RCLONE_RC_PASS = $rcPassword
    }
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('local-setup:' + $rcPassword)) }
    try {
        $ready = $false
        for ($index=0; $index -lt 50; $index++) {
            if ($proc.HasExited) { throw 'Local configuration service stopped.' }
            try {
                $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/core/version" -Method Post -Headers $headers -TimeoutSec 1
                $ready = $true; break
            } catch { Start-Sleep -Milliseconds 100 }
        }
        if (-not $ready) { throw 'Local configuration service did not start.' }
        $opt = @{ obscure=$true; noOutput=$true; nonInteractive=$true }
        $rawBody = @{ name='r2raw'; type=$RawParameters.type; parameters=$RawParameters.parameters; opt=$opt } | ConvertTo-Json -Depth 8
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/config/create" -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($rawBody)) -TimeoutSec 20
        $cryptBody = @{
            name='r2'; type='crypt'; opt=$opt
            parameters=@{ remote=$CryptPath; password=$Password; password2=(New-RandomSecret); filename_encryption='standard'; directory_name_encryption='true'; filename_encoding='base32' }
        } | ConvertTo-Json -Depth 8
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/config/create" -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($cryptBody)) -TimeoutSec 20
        if ((Get-Content -LiteralPath $ConfigPath -TotalCount 1) -ne '# Encrypted rclone configuration File') {
            throw 'Encrypted configuration verification failed.'
        }
    } finally {
        if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
        $rcPassword=$null; $headers=$null; $rawBody=$null; $cryptBody=$null
    }
}

function Write-LocalPassword([string]$Directory, [string]$Password) {
    Add-Type -AssemblyName System.Security
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($Password)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($plainBytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllText((Join-Path $Directory 'unlock.dpapi'),('DPAPI-V1:' + [Convert]::ToBase64String($protected)),(New-Object Text.UTF8Encoding($false)))
    } finally { [Array]::Clear($plainBytes,0,$plainBytes.Length) }
}

function Read-LocalPassword([string]$Directory) {
    Add-Type -AssemblyName System.Security
    $stored = [IO.File]::ReadAllText((Join-Path $Directory 'unlock.dpapi'))
    if (-not $stored.StartsWith('DPAPI-V1:')) { throw 'An older unlock file was found. Re-enter the configuration passphrase in the recovery window.' }
    $protected = [Convert]::FromBase64String($stored.Substring(9))
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect($protected,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($plainBytes) }
    finally { [Array]::Clear($plainBytes,0,$plainBytes.Length) }
}

function Start-EncryptedDrive([string]$Directory, [string]$Password, [string]$DriveLetter) {
    if (Test-Path ($DriveLetter + ':\')) { throw 'The selected drive letter is already in use. No existing drive was changed.' }
    $config = Join-Path $Directory 'rclone.conf'
    $cache = Join-Path $Directory 'cache'
    $log = Join-Path $Directory 'mount.log'
    $proc = New-RcloneProcess @('mount','r2:',($DriveLetter + ':'),'--config',$config,'--volname','R2 Encrypted','--vfs-cache-mode','writes','--cache-dir',$cache,'--vfs-cache-max-size','2G','--vfs-cache-max-age','1h','--vfs-write-back','5s','--dir-cache-time','1m','--log-level','ERROR','--log-file',$log,'--log-file-max-size','2M','--log-file-max-backups','2','--ask-password=false') $Password
    for ($index=0; $index -lt 100; $index++) {
        if (Test-Path ($DriveLetter + ':\')) { return $proc.Id }
        if ($proc.HasExited) { throw 'The drive could not start. Check mount.log in the local setup folder.' }
        Start-Sleep -Milliseconds 200
    }
    if (-not $proc.HasExited) { $proc.Kill() }
    throw 'Drive startup timed out.'
}

function Get-Settings([string]$Directory) {
    $settings = Get-Content -LiteralPath (Join-Path $Directory 'settings.json') -Raw | ConvertFrom-Json
    if ($settings.AccountId -notmatch '^[a-f0-9]{32}$' -or
        $settings.Bucket -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' -or
        $settings.DriveLetter -notmatch '^[D-Z]$') {
        throw 'Saved connection settings are invalid. No existing configuration was changed.'
    }
    return $settings
}

function Test-OwnedMount([string]$Directory, [string]$DriveLetter) {
    if (-not (Test-Path ($DriveLetter + ':\'))) { return $false }
    $pidFile = Join-Path $Directory 'mount.pid'
    if (Test-Path -LiteralPath $pidFile) {
        $mountProcessId = [int][IO.File]::ReadAllText($pidFile)
        $mountProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $mountProcessId" -ErrorAction SilentlyContinue
        if ($mountProcess -and $mountProcess.Name -eq 'rclone.exe' -and
            $mountProcess.CommandLine.Contains((Join-Path $Directory 'rclone.conf'))) { return $true }
    }
    throw 'The selected drive letter is used by another drive. It was not changed.'
}

function Connect-Drive([string]$Directory, [string]$Password, [string]$DriveLetter) {
    if (Test-OwnedMount $Directory $DriveLetter) { return }
    $mountProcessId = Start-EncryptedDrive $Directory $Password $DriveLetter
    [IO.File]::WriteAllText((Join-Path $Directory 'mount.pid'),[string]$mountProcessId)
}

function Set-Startup([string]$Directory, [bool]$Enabled) {
    $shell = New-Object -ComObject WScript.Shell
    $target = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $installedScript = Join-Path $Directory 'R2Drive.ps1'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $installedScript + '"'
    $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'R2Drive.lnk'))
    $shortcut.TargetPath=$target; $shortcut.Arguments=$arguments; $shortcut.WorkingDirectory=$Directory
    $shortcut.Description='暗号化したR2ドライブを開く'
    $shortcut.Save()
    $startupPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'R2Drive.lnk'
    if ($Enabled) {
        $startup = $shell.CreateShortcut($startupPath)
        $startup.TargetPath=$target; $startup.Arguments=$arguments; $startup.WorkingDirectory=$Directory
        $startup.Save()
    } elseif (Test-Path -LiteralPath $startupPath) {
        Remove-Item -LiteralPath $startupPath
    }
}

function Export-Recovery([string]$Directory) {
    $dialog = New-Object Windows.Forms.SaveFileDialog
    $dialog.Title='暗号化した復旧用設定を保存'
    $dialog.FileName='r2drive-recovery.conf'
    $dialog.Filter='暗号化したrclone設定 (*.conf)|*.conf'
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        Copy-Item -LiteralPath (Join-Path $Directory 'rclone.conf') -Destination $dialog.FileName
    }
}

function Complete-Connection([string]$Directory, [string]$Password, $Settings) {
    $config = Join-Path $Directory 'rclone.conf'
    $remotes = Invoke-Rclone @('listremotes','--config',$config,'--ask-password=false') $Password
    if ($remotes -notmatch '(?m)^r2:\s*$') { throw 'The saved encrypted remote could not be unlocked.' }
    $null = Invoke-Rclone @('lsf','r2:','--max-depth','1','--config',$config,'--retries','1','--low-level-retries','1') $Password
    if ($Settings.AutoConnect) { Write-LocalPassword $Directory $Password }
    Connect-Drive $Directory $Password $Settings.DriveLetter
    Set-Startup $Directory ([bool]$Settings.AutoConnect)
}

function Show-ConnectionForm([string]$Directory, [bool]$Existing) {
    $config = Join-Path $Directory 'rclone.conf'
    $settings = $null
    if ($Existing) { $settings = Get-Settings $Directory }
    $form = New-Object Windows.Forms.Form
    $form.Tag=[pscustomobject]@{Existing=$Existing;Settings=$settings}
    $form.Text='R2 暗号化ドライブ'
    $form.ClientSize=New-Object Drawing.Size(650,710)
    $form.StartPosition='CenterScreen'; $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false
    $form.Font=New-Object Drawing.Font('Yu Gothic UI',10)
    function Add-Field([string]$Label,[int]$Y,[bool]$Secret) {
        $caption=New-Object Windows.Forms.Label
        $caption.Text=$Label; $caption.Location=New-Object Drawing.Point(22,$Y)
        $caption.Size=New-Object Drawing.Size(606,24); $form.Controls.Add($caption)
        $field=New-Object Windows.Forms.TextBox
        $field.Location=New-Object Drawing.Point(22,($Y+25)); $field.Size=New-Object Drawing.Size(606,28)
        $field.UseSystemPasswordChar=$Secret; $form.Controls.Add($field)
        return $field
    }
    $account=Add-Field 'CloudflareアカウントID（32桁）' 16 $false
    $bucket=Add-Field '既存の非公開R2バケット名' 81 $false
    $drive=Add-Field '使用するドライブ文字（D〜Z）' 146 $false
    $access=Add-Field 'S3 Access Key ID' 211 $true
    $secret=Add-Field 'S3 Secret Access Key' 276 $true
    $pass=Add-Field '暗号化パスフレーズ（初回は24文字以上で新しく設定）' 341 $true
    $confirm=Add-Field '暗号化パスフレーズをもう一度入力（初回のみ）' 406 $true
    $bucket.Text='rclone-crypt'; $drive.Text='R'
    if ($Existing) {
        $account.Text=$settings.AccountId; $bucket.Text=$settings.Bucket; $drive.Text=$settings.DriveLetter
        foreach ($field in @($account,$bucket,$drive,$access,$secret,$confirm)) { $field.Enabled=$false }
    }
    $saved=New-Object Windows.Forms.CheckBox
    $saved.Text='暗号化パスフレーズをパスワードマネージャーなどに保存しました'
    $saved.Location=New-Object Drawing.Point(22,477); $saved.Size=New-Object Drawing.Size(606,29)
    $saved.Checked=$Existing; $form.Controls.Add($saved)
    $auto=New-Object Windows.Forms.CheckBox
    $auto.Text='Windowsログイン時に自動接続する（鍵をこのユーザーに保管）'
    $auto.Location=New-Object Drawing.Point(22,511); $auto.Size=New-Object Drawing.Size(606,29)
    $auto.Checked=($Existing -and [bool]$settings.AutoConnect)
    $form.Controls.Add($auto)
    $backup=New-Object Windows.Forms.CheckBox
    $backup.Text='接続後に、暗号化した復旧用設定の保存先を選ぶ'
    $backup.Checked=-not $Existing
    $backup.Location=New-Object Drawing.Point(22,545); $backup.Size=New-Object Drawing.Size(606,29)
    $form.Controls.Add($backup)
    $note=New-Object Windows.Forms.Label
    $note.Text="自動接続を有効にすると、同じWindowsユーザーのアプリも保存鍵を復号できます。`r`n画面ロックによる自動切断はありません。PCには平文の一時キャッシュが残る場合があります。"
    $note.Location=New-Object Drawing.Point(22,586); $note.Size=New-Object Drawing.Size(606,54)
    $note.Font=New-Object Drawing.Font('Yu Gothic UI',9); $form.Controls.Add($note)
    $feedback=New-Object Windows.Forms.Label
    $feedback.Location=New-Object Drawing.Point(22,660); $feedback.Size=New-Object Drawing.Size(320,36)
    $form.Controls.Add($feedback)
    $button=New-Object Windows.Forms.Button
    $button.Text='確認して接続'; $button.Location=New-Object Drawing.Point(375,654)
    $button.Size=New-Object Drawing.Size(253,36); $form.Controls.Add($button); $form.AcceptButton=$button
    $button.Add_Click({
        $Existing=[bool]$form.Tag.Existing
        $settings=$form.Tag.Settings
        $password=$pass.Text
        try {
            if (-not $Existing) {
                if ($account.Text.Trim() -notmatch '^[a-fA-F0-9]{32}$' -or
                    $bucket.Text.Trim() -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' -or
                    $drive.Text.Trim().ToUpperInvariant() -notmatch '^[D-Z]$' -or
                    $access.Text.Trim() -notmatch '^[a-fA-F0-9]{32}$' -or
                    $secret.Text.Trim() -notmatch '^[a-fA-F0-9]{64}$') { throw 'アカウントID、バケット名、ドライブ文字、S3認証情報を確認してください。' }
                if ($password.Length -lt 24 -or $password -cne $confirm.Text -or -not $saved.Checked) {
                    throw '24文字以上の暗号化パスフレーズを入力し、保存済みのチェックを入れてください。'
                }
                if (Test-Path ($drive.Text.Trim().ToUpperInvariant() + ':\')) { throw 'そのドライブ文字は使用中です。別の文字を指定してください。' }
            } elseif ([string]::IsNullOrEmpty($password)) { throw '保存済みの暗号化パスフレーズを入力してください。' }
            $button.Enabled=$false; $feedback.Text='暗号化設定と接続を確認中…'; $form.Refresh()
            if (-not $Existing) {
                $settings=[pscustomobject]@{AccountId=$account.Text.Trim().ToLowerInvariant();Bucket=$bucket.Text.Trim();DriveLetter=$drive.Text.Trim().ToUpperInvariant();AutoConnect=[bool]$auto.Checked}
                $candidate=Join-Path $Directory ('pending-' + [Guid]::NewGuid().ToString('N') + '.conf')
                Initialize-EncryptedConfig $candidate $password $script:SourcePath
                $raw=@{type='s3';parameters=@{
                    provider='Cloudflare';access_key_id=$access.Text.Trim();secret_access_key=$secret.Text.Trim()
                    endpoint=('https://' + $settings.AccountId + '.r2.cloudflarestorage.com');region='auto';no_check_bucket='true'
                }}
                Add-EncryptedRemote $candidate $password $raw ('r2raw:' + $settings.Bucket + '/encrypted')
                $null=Invoke-Rclone @('lsf',('r2raw:'+$settings.Bucket),'--max-depth','1','--config',$candidate,'--retries','1','--low-level-retries','1') $password
                $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'settings.json') -Encoding UTF8
                Move-Item -LiteralPath $candidate -Destination $config
                # From here, retries must reuse this configuration and its salt.
                $Existing=$true
                $form.Tag.Existing=$true
                $form.Tag.Settings=$settings
                foreach ($field in @($account,$bucket,$drive,$access,$secret,$confirm)) { $field.Enabled=$false }
                $access.Clear(); $secret.Clear(); $confirm.Clear()
            }
            $settings.AutoConnect=[bool]$auto.Checked
            $form.Tag.Settings=$settings
            $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'settings.json') -Encoding UTF8
            Complete-Connection $Directory $password $settings
            if (-not $settings.AutoConnect -and (Test-Path -LiteralPath (Join-Path $Directory 'unlock.dpapi'))) {
                # The user explicitly chose manual unlocking; preserve the encrypted config.
                Remove-Item -LiteralPath (Join-Path $Directory 'unlock.dpapi')
            }
            if ($backup.Checked) { Export-Recovery $Directory }
            $pass.Clear(); $password=$null; $raw=$null
            $form.DialogResult=[Windows.Forms.DialogResult]::OK; $form.Close()
            Start-Process explorer.exe -ArgumentList ($settings.DriveLetter + ':\')
        } catch {
            $feedback.Text='接続を完了できませんでした。'
            [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'R2 暗号化ドライブ')
            $button.Enabled=$true
        } finally { $password=$null; $raw=$null }
    })
    $null=$form.ShowDialog()
}

function Invoke-SelfTest {
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('R2Drive-check-' + [Guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $directory
    $config=Join-Path $directory 'rclone.conf'
    $password=(New-RandomSecret) + '-日本語-'
    $testMountProcess=$null
    try {
        Initialize-EncryptedConfig $config $password $script:SourcePath
        Add-EncryptedRemote $config $password @{type='local';parameters=@{}} ('r2raw:' + (Join-Path $directory 'ciphertext'))
        $inputFile=Join-Path $directory 'input.txt'
        [IO.File]::WriteAllText($inputFile,'R2Drive isolated encryption check')
        $null=Invoke-Rclone @('copyto',$inputFile,'r2:example.txt','--config',$config) $password
        if ((Invoke-Rclone @('cat','r2:example.txt','--config',$config) $password) -cne 'R2Drive isolated encryption check') { throw 'Local encrypted roundtrip failed.' }
        $raw=@(Get-ChildItem -LiteralPath (Join-Path $directory 'ciphertext') -File)
        if ($raw.Count -ne 1 -or $raw[0].Name -eq 'example.txt') { throw 'Filename encryption check failed.' }
        $bytes=[IO.File]::ReadAllBytes($raw[0].FullName)
        if ([Text.Encoding]::ASCII.GetString($bytes,0,8) -cne "RCLONE`0`0") { throw 'Standard crypt header check failed.' }
        if ([IO.File]::ReadAllText($config) -notmatch 'RCLONE_ENCRYPT_V0:') { throw 'Config encryption check failed.' }
        Write-LocalPassword $directory $password
        if ((Read-LocalPassword $directory) -cne $password) { throw 'Windows DPAPI check failed.' }
        $failedAsExpected=$false
        try { $null=Invoke-Rclone @('listremotes','--config',$config,'--ask-password=false') (New-RandomSecret) }
        catch { $failedAsExpected=$true }
        if (-not $failedAsExpected) { throw 'Wrong config password was not rejected.' }
        if ($MountTest) {
            $testLetter=@('Z','Y','X','W','V') | Where-Object { -not (Test-Path ($_ + ':\')) } | Select-Object -First 1
            if (-not $testLetter) { throw 'No unused temporary drive letter was available.' }
            $testMountProcessId=Start-EncryptedDrive $directory $password $testLetter
            $testMountProcess=Get-Process -Id $testMountProcessId
            $testText='R2Drive temporary mounted write check'
            [IO.File]::WriteAllText(($testLetter + ':\mounted.txt'),$testText)
            $uploaded=$false
            for ($attempt=0; $attempt -lt 20; $attempt++) {
                Start-Sleep -Milliseconds 500
                try {
                    if ((Invoke-Rclone @('cat','r2:mounted.txt','--config',$config) $password) -ceq $testText) {
                        $uploaded=$true; break
                    }
                } catch { }
            }
            if (-not $uploaded) { throw 'Temporary mounted write did not reach the encrypted local backend.' }
            Write-Output ('PASS: temporary WinFsp drive ' + $testLetter + ':, mounted write and direct encrypted-backend readback.')
        }
        Write-Output 'PASS: one-file password helper, encrypted config, filename/content encryption, roundtrip, Windows DPAPI and wrong-password rejection.'
    } finally {
        if ($testMountProcess -and -not $testMountProcess.HasExited) {
            # Only the process created above for this isolated temporary config.
            $testMountProcess.Kill(); $testMountProcess.WaitForExit()
        }
        $password=$null
        $absolute=[IO.Path]::GetFullPath($directory)
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($absolute.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($absolute).StartsWith('R2Drive-check-')) {
            Remove-Item -LiteralPath $absolute -Recurse -Force
        }
    }
}

if ($Mode -eq 'SelfTest') { Invoke-SelfTest; return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try {
    # First launch offers official package installation before asking for secrets.
    $needRclone=$false
    try { $null=Get-RcloneBinary } catch { $needRclone=$true }
    $needWinFsp=-not (Test-Path "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp-x64.dll")
    if ($needRclone -or $needWinFsp) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'wingetが必要です。READMEの事前準備を確認してください。' }
        $answer=[Windows.Forms.MessageBox]::Show('ドライブ接続に必要なrcloneとWinFspを、wingetの公式パッケージからインストールしますか？ 管理者の確認画面が出る場合があります。','必要なソフトのインストール',[Windows.Forms.MessageBoxButtons]::YesNo)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
        if ($needRclone) { & winget.exe install --exact --id Rclone.Rclone --source winget --scope user --silent --disable-interactivity; if ($LASTEXITCODE -ne 0) { throw 'rcloneのインストールを完了できませんでした。' } }
        if ($needWinFsp) { & winget.exe install --exact --id WinFsp.WinFsp --source winget --silent --disable-interactivity; if ($LASTEXITCODE -ne 0) { throw 'WinFspのインストールを完了できませんでした。' } }
    }
    $directory=Join-Path $env:LOCALAPPDATA 'R2Drive'
    $null=New-Item -ItemType Directory -Path $directory -Force
    $userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $null=& icacls.exe $directory /inheritance:r /grant:r "*${userSid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) { throw '設定フォルダのアクセス制限を設定できませんでした。' }
    $installedScript=Join-Path $directory 'R2Drive.ps1'
    if ([IO.Path]::GetFullPath($script:SourcePath) -cne [IO.Path]::GetFullPath($installedScript)) {
        Copy-Item -LiteralPath $script:SourcePath -Destination $installedScript
    }
    $config=Join-Path $directory 'rclone.conf'
    if (Test-Path -LiteralPath $config) {
        $settings=Get-Settings $directory
        if (Test-OwnedMount $directory $settings.DriveLetter) {
            if ($Mode -eq 'Configure') { Show-ConnectionForm $directory $true }
            else { Start-Process explorer.exe -ArgumentList ($settings.DriveLetter + ':\') }
        } elseif ($Mode -ne 'Configure' -and $settings.AutoConnect -and (Test-Path -LiteralPath (Join-Path $directory 'unlock.dpapi'))) {
            $password=Read-LocalPassword $directory
            try { Complete-Connection $directory $password $settings }
            finally { $password=$null }
            Start-Process explorer.exe -ArgumentList ($settings.DriveLetter + ':\')
        } else { Show-ConnectionForm $directory $true }
    } else { Show-ConnectionForm $directory $false }
} catch {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'R2 暗号化ドライブ')
    exit 1
}
