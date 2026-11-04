' Launch ClaudeNiang without a console window
Option Explicit
Dim sh, fso, dir, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\ClaudeNiang.ps1"""
sh.Run cmd, 0, False
