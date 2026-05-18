' Double-click this file to open Mod Merger (no black PowerShell window).
Option Explicit
Dim fso, sh, root, launcher, psExe, cmd, exitCode, errFile, detail, tf

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
root = fso.GetParentFolderName(WScript.ScriptFullName)
launcher = fso.BuildPath(root, "Texturepack-Merge-Launcher.ps1")

If Not fso.FileExists(launcher) Then
    MsgBox "Cannot find:" & vbCrLf & launcher, vbCritical, "Mod Merger"
    WScript.Quit 1
End If

psExe = sh.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(psExe) Then
    MsgBox "PowerShell not found:" & vbCrLf & psExe, vbCritical, "Mod Merger"
    WScript.Quit 1
End If

errFile = fso.BuildPath(root, "_err.txt")
If fso.FileExists(errFile) Then
    On Error Resume Next
    fso.DeleteFile errFile, True
    On Error GoTo 0
End If

' Do not use -WindowStyle Hidden — on some PCs it hides the WinForms window too.
cmd = """" & psExe & """ -NoProfile -STA -ExecutionPolicy Bypass -File """ & launcher & """"
exitCode = sh.Run(cmd, 0, True)

If exitCode <> 0 Then
    detail = "Exit code: " & exitCode
    If fso.FileExists(errFile) Then
        Set tf = fso.OpenTextFile(errFile, 1)
        detail = detail & vbCrLf & vbCrLf & tf.ReadAll()
        tf.Close
    End If
    MsgBox "Mod Merger exited with an error (this is not normal after a successful merge)." & vbCrLf & vbCrLf & detail, vbCritical, "Mod Merger"
End If
