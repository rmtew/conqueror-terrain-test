; Numeric AmigaOS 1.x library ABI equates in Devpac syntax.
; Vector offsets follow Exec and Graphics FD entries (6-byte vectors).
; https://amigadev.elowar.com/read/ADCD_2.1/Includes_and_Autodocs_2._guide/node0011.html
; GraphicsBase field offsets follow Structure.offs, GfxBase.
; https://amigadev.elowar.com/read/ADCD_2.1/Includes_and_Autodocs_2._guide/node0551.html
SYSBASE_ADDR    equ 4
_LVOPermit      equ -138
_LVOForbid      equ -132
_LVOCloseLibrary equ -414
_LVOOpenLibrary equ -552
_LVOLoadView    equ -222
_LVOWaitBlit    equ -228
_LVOWaitTOF     equ -270
_LVOOwnBlitter  equ -456
_LVODisownBlitter equ -462
GB_ACTIVIEW     equ 34
GB_COPINIT      equ 38
