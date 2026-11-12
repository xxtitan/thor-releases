# thor 一键安装脚本（Windows）。
#
#   irm https://raw.githubusercontent.com/xxtitan/thor-releases/main/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/xxtitan/thor-releases/main/install.ps1))) -Service
#
# 从 GitHub Release 下载当前平台的 thor.exe 并校验 SHA-256，直连 GitHub 失败时改经 gh-proxy.com 下载，
# 安装到用户目录并加入用户 PATH。-Service 注册开机运行 thor web serve 的计划任务（需要管理员权限）。
# 重复执行即升级到最新版本，并重启已注册的计划任务。
param(
    [ValidateSet('stable', 'nightly')]
    [string]$Channel = 'stable',
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'Programs\thor'),
    [switch]$Service,
    [string]$Listen = '127.0.0.1:7998',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 默认可能未启用 TLS 1.2。
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'xxtitan/thor-releases'
$Mirror = 'https://gh-proxy.com/'
$TaskName = 'thor'
$Exe = Join-Path $Dir 'thor.exe'
$DataDir = Join-Path $env:USERPROFILE '.config\thor'

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Green
}

function Get-Platform {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'AMD64' { return 'windows-amd64' }
        'ARM64' { return 'windows-arm64' }
        default { throw "不支持的架构 $arch" }
    }
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ReleaseUrl([string]$Name) {
    if ($Channel -eq 'stable') {
        return "https://github.com/$Repo/releases/latest/download/$Name"
    }
    return "https://github.com/$Repo/releases/download/nightly/$Name"
}

# 下载 Release 中的文件：先直连 GitHub，失败后经 gh-proxy.com。
function Save-ReleaseFile([string]$Name, [string]$OutFile) {
    $url = Get-ReleaseUrl $Name
    try {
        Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
    } catch {
        Write-Step "直连 GitHub 失败，改经 $Mirror 下载 $Name"
        Invoke-WebRequest -Uri "$Mirror$url" -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
    }
}

function Get-Task {
    return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Install-Binary([string]$Staging) {
    $asset = "thor-$(Get-Platform).exe"
    Write-Step "下载 $Channel 通道的 $asset"
    $sums = Join-Path $Staging 'checksums.txt'
    $file = Join-Path $Staging 'thor.exe'
    Save-ReleaseFile 'checksums.txt' $sums
    Save-ReleaseFile $asset $file

    $expected = Get-Content $sums | ForEach-Object {
        $fields = $_ -split '\s+'
        if ($fields[1] -eq $asset) { $fields[0] }
    } | Select-Object -First 1
    if (-not $expected) {
        throw "checksums.txt 中没有 $asset"
    }
    $actual = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "$asset 校验失败：SHA-256 为 $actual，应为 $expected"
    }

    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    # 运行中的 thor.exe 不能覆盖但可以重命名：先移到 thor.exe.old，再放入新文件。
    $old = "$Exe.old"
    if (Test-Path $old) {
        Remove-Item $old -Force
    }
    if (Test-Path $Exe) {
        Move-Item $Exe $old
    }
    Move-Item $file $Exe
    Write-Step "已安装 $(Get-ThorVersion)"
}

# thor 以 UTF-8 输出，捕获输出时按 UTF-8 解码，避免中文乱码。
function Get-ThorVersion {
    $encoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    try {
        return & $Exe --version
    } finally {
        [Console]::OutputEncoding = $encoding
    }
}

function Add-UserPath {
    $path = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($path -split ';' | Where-Object { $_ })
    if ($entries -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('Path', (($entries + $Dir) -join ';'), 'User')
        Write-Step "已把 $Dir 加入用户 PATH，新开的终端生效"
    }
    if (($env:Path -split ';') -notcontains $Dir) {
        $env:Path = "$env:Path;$Dir"
    }
}

function Remove-UserPath {
    $path = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($path -split ';' | Where-Object { $_ -and $_ -ne $Dir })
    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
}

# 计划任务以当前用户身份在开机时运行，不需要登录、不弹出窗口；注册 S4U 任务需要管理员权限。
function Install-Task {
    if (-not (Test-Admin)) {
        throw '注册开机自启的计划任务需要管理员权限，请在“以管理员身份运行”的 PowerShell 中执行'
    }
    $action = New-ScheduledTaskAction -Execute $Exe -Argument "--data-dir `"$DataDir`" web serve --listen $Listen"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'thor 管理中心' -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Step "已注册开机自启的计划任务 $TaskName（运行用户 $env:USERNAME）"
    Write-Step "管理中心: http://$Listen"
}

function Stop-Task {
    $task = Get-Task
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName
    }
}

function Uninstall-Thor {
    if (Get-Task) {
        if (-not (Test-Admin)) {
            throw '移除计划任务需要管理员权限，请在“以管理员身份运行”的 PowerShell 中执行'
        }
        Stop-Task
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Step "已移除计划任务 $TaskName"
    }
    foreach ($file in @($Exe, "$Exe.old")) {
        if (Test-Path $file) {
            Remove-Item $file -Force
            Write-Step "已删除 $file"
        }
    }
    if ((Test-Path $Dir) -and -not (Get-ChildItem $Dir -Force)) {
        Remove-Item $Dir -Force
    }
    Remove-UserPath
    Write-Step "数据目录 $DataDir 已保留，不再需要时可手动删除"
}

function Install-Thor {
    $staging = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        $task = Get-Task
        Install-Binary $staging
        Add-UserPath
        if ($Service) {
            Install-Task
        } elseif ($task -and (Test-Admin)) {
            # 已注册的计划任务改用新安装的 thor。
            Stop-Task
            Start-ScheduledTask -TaskName $TaskName
            Write-Step "已重启计划任务 $TaskName"
        } elseif ($task) {
            Write-Step "在管理员 PowerShell 中执行 Stop-ScheduledTask $TaskName; Start-ScheduledTask $TaskName 让计划任务改用新版本"
        }
    } finally {
        Remove-Item $staging -Recurse -Force
    }
}

if ($Uninstall) {
    Uninstall-Thor
} else {
    Install-Thor
}
