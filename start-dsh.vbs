' start-dsh.vbs - launch DeepSeek Harness and, in parallel, the boot watchdog.
'
' Order matters: the app is started FIRST (equivalent to a native double-click,
' no extra waiting), and only then the hidden watchdog. If the watchdog itself
' fails to start, the app is already up - the guard can never block a launch.
'
' Reads config.ini (written by install.ps1) next to this file.

Option Explicit
Dim fso, sh, base, exe, ps, cfg

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

base = fso.GetParentFolderName(WScript.ScriptFullName)
cfg  = base & "\config.ini"

exe = IniValue(cfg, "ExePath")

If exe = "" Then
    MsgBox "config.ini is missing or has no ExePath." & vbCrLf & _
           "Run install.ps1 once first:" & vbCrLf & vbCrLf & _
           "  powershell -NoProfile -ExecutionPolicy Bypass -File """ & base & "\install.ps1""", _
           16, "DSH guard boot"
    WScript.Quit 2
End If

If Not fso.FileExists(exe) Then
    MsgBox "DeepSeek Harness.exe not found:" & vbCrLf & exe & vbCrLf & vbCrLf & _
           "Edit ExePath in config.ini, or re-run install.ps1.", 16, "DSH guard boot"
    WScript.Quit 2
End If

' 1) start the app
sh.Run """" & exe & """", 1, False

' 2) start the watchdog (0 = hidden window, False = do not wait)
ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\watchdog.ps1"""
sh.Run ps, 0, False

Function IniValue(path, key)
    Dim ts, line, i, k
    IniValue = ""
    If Not fso.FileExists(path) Then Exit Function
    Set ts = fso.OpenTextFile(path, 1)
    Do While Not ts.AtEndOfStream
        line = Trim(ts.ReadLine)
        If Len(line) > 0 And Left(line, 1) <> ";" And Left(line, 1) <> "#" Then
            i = InStr(line, "=")
            If i > 0 Then
                k = Trim(Left(line, i - 1))
                If LCase(k) = LCase(key) Then
                    IniValue = Trim(Mid(line, i + 1))
                    Exit Do
                End If
            End If
        End If
    Loop
    ts.Close
End Function
