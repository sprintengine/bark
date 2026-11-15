; NSIS hooks for the Windows installer (bundle.windows.nsis.installerHooks).
;
; The app was called Fairspoken before it was renamed. The installer keys its
; uninstall entry, saved install folder and default folder on productName, so
; without this hook an update (or a fresh download) would install a second copy
; beside the old one. Before installing, remove a copy installed under the old
; name with its own uninstaller, silently. It never deletes app data in silent
; mode, and the data folders do not depend on the product name, so settings,
; history and models carry over.
;
; Without /UPDATE that uninstaller also removes the old Start menu and desktop
; shortcuts, and an update (/UPDATE) does not create new ones, so the hook puts
; them back under the new name after installing. Windows does not let an
; installer pin to the taskbar, so a taskbar pin has to be made again.

Var OldNameMigrated
Var OldNameHadDesktopShortcut

!macro NSIS_HOOK_PREINSTALL
  StrCpy $OldNameMigrated 0
  StrCpy $OldNameHadDesktopShortcut 0
  ReadRegStr $R0 SHCTX "Software\Microsoft\Windows\CurrentVersion\Uninstall\Fairspoken" "InstallLocation"
  ; Written as "$INSTDIR" with quotes; strip them.
  StrCpy $R1 $R0 1
  ${If} $R1 == '"'
    StrCpy $R0 $R0 "" 1
    StrCpy $R0 $R0 -1
  ${EndIf}
  ${If} $R0 != ""
  ${AndIf} $R0 != $INSTDIR
  ${AndIf} ${FileExists} "$R0\uninstall.exe"
    ${If} ${FileExists} "$DESKTOP\Fairspoken.lnk"
      StrCpy $OldNameHadDesktopShortcut 1
    ${EndIf}
    DetailPrint "Removing the copy installed under the old name, Fairspoken, from $R0"
    ; _?= runs the uninstaller in place and waits for it.
    ExecWait '"$R0\uninstall.exe" /S _?=$R0' $R2
    ${If} $R2 = 0
      StrCpy $OldNameMigrated 1
      ; In place, the uninstaller cannot delete itself or its folder.
      Delete "$R0\uninstall.exe"
      RMDir "$R0"
    ${Else}
      DetailPrint "The old uninstaller exited with $R2; leaving $R0 as it is"
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  ${If} $OldNameMigrated = 1
    ${IfNot} ${FileExists} "$SMPROGRAMS\${PRODUCTNAME}.lnk"
      CreateShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
      !insertmacro SetLnkAppUserModelId "$SMPROGRAMS\${PRODUCTNAME}.lnk"
    ${EndIf}
    ${If} $OldNameHadDesktopShortcut = 1
    ${AndIfNot} ${FileExists} "$DESKTOP\${PRODUCTNAME}.lnk"
      CreateShortcut "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
      !insertmacro SetLnkAppUserModelId "$DESKTOP\${PRODUCTNAME}.lnk"
    ${EndIf}
  ${EndIf}
!macroend
