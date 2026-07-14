@echo off
chcp 65001 >nul
echo ========================================
echo   Sing-Box 网络诊断工具
echo ========================================
echo.

echo [1] 检查 sing-box 进程状态...
tasklist | findstr /i "sing-box"
if errorlevel 1 (
    echo     sing-box 未运行
) else (
    echo     sing-box 正在运行
)
echo.

echo [2] 检查 TUN 接口...
ipconfig /all | findstr /i "sing\|wintun\|tun"
if errorlevel 1 (
    echo     未发现 TUN 接口
)
echo.

echo [3] 检查默认路由...
route print | findstr "0.0.0.0.*0.0.0.0"
echo.

echo [4] 测试国内网络...
ping -n 1 -w 1000 223.5.5.5 >nul
if errorlevel 1 (
    echo     国内网络: 失败
) else (
    echo     国内网络: 正常
)
echo.

echo [5] 测试国外网络...
ping -n 1 -w 1000 8.8.8.8 >nul
if errorlevel 1 (
    echo     国外网络: 失败
) else (
    echo     国外网络: 正常
)
echo.

echo [6] 测试 DNS 解析...
nslookup baidu.com >nul 2>&1
if errorlevel 1 (
    echo     DNS 解析: 失败
) else (
    echo     DNS 解析: 正常
)
echo.

echo [7] 检查代理端口...
powershell -ExecutionPolicy Bypass -Command ". '%~dp0scripts\env.ps1' | Out-Null; $p = Get-ProxyPort; if (Test-ProxyPortListening -Port $p) { Write-Host \"    代理端口 $p 正常监听\" } else { Write-Host \"    代理端口 $p 未监听\" }"
echo.

echo [8] 检查系统代理设置...
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable 2>nul | findstr "0x1"
if errorlevel 1 (
    echo     系统代理: 关闭
) else (
    echo     系统代理: 开启
)
echo.

echo [9] 最近日志（最后 20 行）...
if exist "sing-box.log" (
    echo --- sing-box.log ---
    powershell -Command "Get-Content 'sing-box.log' -Tail 20"
) else (
    echo     日志文件不存在
)
echo.

echo ========================================
echo   诊断完成
echo ========================================
echo.
pause
