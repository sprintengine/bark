; NSIS hooks for the Windows installer (bundle.windows.nsis.installerHooks).
;
; The app was called Fairspoken before it was renamed. The installer keys its
; uninstall entry, saved install folder and default folder on productName, so
; without this hook an update (or a fresh download) would install a second copy
; beside the old one. Before installing, remove a copy installed under the old
; name with its own uninstaller, silently. Without /UPDATE the uninstaller also
; removes the old Start menu and desktop shortcuts; it never deletes app data
; in silent mode, and the data folders do not depend on the product name, so
; settings, history and models carry over.

!macro NSIS_HOOK_PREINSTALL
  ReadRegStr $R0 SHCTX "Software\Microsoft\Windows\CurrentVersion\Uninstall\Fairspoken" "InstallLocation"
  ; Written as "$INSTDIR" with quotes; strip them.
  StrCpy $R1 $R0 1
  ${If} $R1 == '"'
    StrCpy $R0 $R0 "" 1
    StrCpy $R0 $R0 -1
  ${EndIf}
  ${If} $R0 != ""
  ${AndIf} ${FileExists} "$R0\uninstall.exe"
    DetailPrint "Removing the copy installed under the old name, Fairspoken, from $R0"
    ; _?= runs the uninstaller in place and waits for it.
    ExecWait '"$R0\uninstall.exe" /S _?=$R0'
    ; In place, the uninstaller cannot delete itself or its folder.
    Delete "$R0\uninstall.exe"
    RMDir "$R0"
  ${EndIf}
!macroend
