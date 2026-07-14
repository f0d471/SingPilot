@echo off
echo ========================================
echo   Sing-Box 健康监控 - 一键安装
echo ========================================
echo.
echo 这将安装 3 个计划任务：
echo   1. 每5分钟健康检查，断网自动重启
echo   2. 每天凌晨4:00自动重启（防卡死）
echo   3. 内存超过600MB自动重启（防泄漏）
echo.
echo 需要管理员权限（下一步会弹出 UAC 授权）。
echo.
pause
powershell -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy','Bypass','-File','%~dp0scripts\watchdog.ps1','-SetupTask'"
