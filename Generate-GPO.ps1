<#
.SYNOPSIS
    使用 LGPO.exe 备份当前本地组策略到指定目录

.DESCRIPTION
    此脚本利用微软官方工具 LGPO.exe 将当前本地组策略备份到指定文件夹。
    备份会生成一个以 GUID 命名的子目录，包含完整的 GPO 备份文件。
    支持自定义备份名称，自动创建目录，并提供交互与非交互两种模式。

.PARAMETER BackupPath
    备份目标根目录，默认值为脚本所在目录下的 GPO_Backup 文件夹。
    脚本会自动创建该目录（如果不存在）。

.PARAMETER LGPOExePath
    LGPO.exe 的完整路径，默认值为脚本所在目录下的 LGPO.exe。

.PARAMETER GpoName
    可选参数，用于指定 GPO 的显示名称（对应 LGPO.exe 的 /n 参数）。
    如果名称包含空格，请使用引号括起来。

.PARAMETER NonInteractive
    非交互模式。不显示任何提示，自动执行备份。
    若备份路径已存在备份，脚本会自动在路径后追加时间戳以避免覆盖。

.PARAMETER Force
    强制模式。当备份路径已存在备份时，直接覆盖（删除原有备份）而不询问。
    与非交互模式结合时，也优先使用 Force 行为（覆盖）而非追加时间戳。

.EXAMPLE
    .\Generate-GPO.ps1
    以交互方式备份到默认路径 D:\LGPO\GPO_Backup，并询问是否覆盖已有备份。

.EXAMPLE
    .\Generate-GPO.ps1 -BackupPath "C:\MyBackups" -GpoName "MyPolicyBackup"
    备份到指定路径，并赋予 GPO 显示名称。

.EXAMPLE
    .\Generate-GPO.ps1 -NonInteractive -Force
    在计划任务中调用，自动覆盖默认路径下的已有备份。

.EXAMPLE
    .\Generate-GPO.ps1 -NonInteractive
    非交互模式下，若已有备份则自动创建带时间戳的新备份，避免覆盖。
#>

param(
    [string]$BackupPath = "$PSScriptRoot\GPO_Backup",
    [string]$LGPOExePath = "$PSScriptRoot\LGPO.exe",
    [string]$GpoName = "",
    [switch]$NonInteractive,
    [switch]$Force
)

# 设置控制台编码，防止中文乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   本地组策略备份工具 (GPO Generate)   " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. 检查是否以管理员身份运行
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "❌ 错误：此脚本必须以管理员身份运行！" -ForegroundColor Red
    Write-Host "   请右键点击 PowerShell 图标，选择“以管理员身份运行”。" -ForegroundColor Yellow
    if (-not $NonInteractive) { Read-Host "按 Enter 键退出" }
    exit 1
}

# 2. 检查 LGPO.exe 是否存在
if (-not (Test-Path $LGPOExePath)) {
    Write-Host "❌ 错误：找不到 LGPO.exe！" -ForegroundColor Red
    Write-Host "   请确保将此脚本与 LGPO.exe 放在同一目录下。" -ForegroundColor Yellow
    Write-Host "   当前查找路径: $LGPOExePath" -ForegroundColor Gray
    if (-not $NonInteractive) { Read-Host "按 Enter 键退出" }
    exit 1
}
Write-Host "✅ 找到 LGPO.exe: $LGPOExePath" -ForegroundColor Green

# 3. 处理备份路径
$backupDir = $BackupPath
if (-not (Test-Path $backupDir)) {
    Write-Host "📁 备份目录不存在，正在创建: $backupDir" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Write-Host "✅ 目录创建成功。" -ForegroundColor Green
} else {
    Write-Host "📁 使用已存在的备份目录: $backupDir" -ForegroundColor Gray
}

# 3.2 检查目录下是否已有 GPO 备份（即包含 GUID 子文件夹）
$guidPattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
$existingBackups = Get-ChildItem -Path $backupDir -Directory | Where-Object { $_.Name -match $guidPattern }

if ($existingBackups.Count -gt 0) {
    Write-Host "⚠️ 检测到备份目录中已存在 $($existingBackups.Count) 个 GPO 备份：" -ForegroundColor Yellow
    foreach ($b in $existingBackups) {
        Write-Host "   - $($b.Name)" -ForegroundColor Gray
    }

    # 决定处理方式
    $action = "ask"
    if ($Force) {
        $action = "overwrite"
        Write-Host "🔄 强制模式启用：将覆盖现有备份。" -ForegroundColor Cyan
    } elseif ($NonInteractive) {
        $action = "new"
        Write-Host "📌 非交互模式：将创建新的时间戳子文件夹，避免覆盖。" -ForegroundColor Cyan
    } else {
        do {
            $choice = Read-Host "请选择操作: (O) 覆盖现有备份, (N) 创建新备份（追加时间戳）, (C) 取消"
            $choice = $choice.ToUpper()
        } while ($choice -notmatch '^[ONC]$')
        switch ($choice) {
            'O' { $action = "overwrite" }
            'N' { $action = "new" }
            'C' { Write-Host "已取消备份操作。"; exit 0 }
        }
    }

    if ($action -eq "overwrite") {
        Write-Host "🗑️ 正在删除现有备份..." -ForegroundColor Yellow
        foreach ($b in $existingBackups) {
            Remove-Item -Path $b.FullName -Recurse -Force
            Write-Host "   已删除: $($b.Name)" -ForegroundColor Gray
        }
        Write-Host "✅ 现有备份已清除，将创建新备份。" -ForegroundColor Green
        $finalBackupPath = $backupDir
    } else {  # new
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $finalBackupPath = Join-Path $backupDir "GPO_Backup_$timestamp"
        Write-Host "📁 将创建新的备份子目录: $finalBackupPath" -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $finalBackupPath -Force | Out-Null
        Write-Host "✅ 子目录创建成功。" -ForegroundColor Green
    }
} else {
    $finalBackupPath = $backupDir
    Write-Host "📁 备份目录为空，将直接备份到此路径。" -ForegroundColor Gray
}

# 4. 构建 LGPO.exe 命令行参数（**关键修正**：不加额外双引号）
$lgpoArgs = @("/b", $finalBackupPath)
if ($GpoName -ne "") {
    $lgpoArgs += "/n"
    $lgpoArgs += $GpoName
}
Write-Host "`n🔄 正在执行备份命令: $LGPOExePath $($lgpoArgs -join ' ')" -ForegroundColor Cyan

# 5. 执行备份（捕获输出）
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logDir = "$PSScriptRoot\Logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir "generate_$timestamp.log"
Write-Host "📄 备份日志将保存至: $logFile" -ForegroundColor Gray

# 直接传递参数数组
$output = & $LGPOExePath $lgpoArgs 2>&1 | Tee-Object -FilePath $logFile

# 6. 检查结果
if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✅ 备份成功！" -ForegroundColor Green
    # 查找新生成的 GUID 子文件夹
    $newBackup = Get-ChildItem -Path $finalBackupPath -Directory | Where-Object { $_.Name -match $guidPattern } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newBackup) {
        Write-Host "📂 备份 GUID: $($newBackup.Name)" -ForegroundColor Cyan
        Write-Host "📂 完整路径: $($newBackup.FullName)" -ForegroundColor Gray
    } else {
        Write-Host "⚠️ 未能自动识别生成的 GUID 文件夹，请手动检查路径: $finalBackupPath" -ForegroundColor Yellow
    }
    Write-Host "📄 日志文件: $logFile" -ForegroundColor Gray
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "🎉 备份流程完成！" -ForegroundColor Green
} else {
    Write-Host "`n❌ 备份失败！错误代码: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "   请检查 LGPO.exe 的输出信息或日志文件。" -ForegroundColor Yellow
    Write-Host "📄 日志文件: $logFile" -ForegroundColor Gray
    Write-Host "========================================" -ForegroundColor Red
}

if (-not $NonInteractive) { Read-Host "`n按 Enter 键退出" }
exit $LASTEXITCODE