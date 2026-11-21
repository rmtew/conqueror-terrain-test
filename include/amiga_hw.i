; Numeric OCS/CIA equates in Devpac syntax, written for this program.
; Register addresses and bits: Commodore Amiga Hardware Reference Manual,
; appendices A/B and F, and the DMA and interrupt control descriptions.
; https://amigadev.elowar.com/read/ADCD_2.1/Hardware_Manual_guide/node0060.html
; https://www.amigadev.elowar.com/read/ADCD_2.1/Hardware_Manual_guide/node012E.html
; Custom-register offsets also serve directly as Copper MOVE destinations.
CUSTOM          equ $dff000
DMACONR         equ $002
VPOSR           equ $004
VHPOSR          equ $006
INTENAR         equ $01c
INTREQR         equ $01e
COPCON          equ $02e
BLTCON0         equ $040
BLTAFWM         equ $044
BLTDPTH         equ $054
BLTSIZE         equ $058
BLTDMOD         equ $066
COP1LCH         equ $080
DIWSTRT         equ $08e
DIWSTOP         equ $090
DDFSTRT         equ $092
DDFSTOP         equ $094
DMACON          equ $096
INTENA          equ $09a
INTREQ          equ $09c
BPL1PTH         equ $0e0
BPL1PTL         equ $0e2
BPL2PTH         equ $0e4
BPL2PTL         equ $0e6
BPL3PTH         equ $0e8
BPL3PTL         equ $0ea
BPLCON0         equ $100
BPLCON1         equ $102
BPLCON2         equ $104
BPL1MOD         equ $108
BPL2MOD         equ $10a
SPR0POS         equ $140
SPR1POS         equ $148
SPR2POS         equ $150
SPR3POS         equ $158
SPR0DATA         equ $144
SPR1DATA         equ $14c
SPR2DATA         equ $154
SPR3DATA         equ $15c
COLOR00         equ $180
COLOR01         equ $182
COLOR02         equ $184
COLOR03         equ $186
COLOR04         equ $188
COLOR05         equ $18a
COLOR06         equ $18c
COLOR07         equ $18e
DMAF_SETCLR     equ $8000
DMAF_DMAEN      equ $0200
DMAF_BPLEN      equ $0100
DMAF_COPEN      equ $0080
DMAF_BLTEN      equ $0040
INTF_SETCLR     equ $8000
INTF_BLIT       equ $0040
INTB_BLIT       equ 6
DMAB_BBUSY_HI   equ 6    ; word bit 14, read in the high byte
VPOSB_V8_LO     equ 0    ; VPOSR low byte contains vertical position bit 8

CIAA_PRA        equ $bfe001
CIAA_SDR        equ $bfec01
CIAA_ICR        equ $bfed01
CIAA_CRA        equ $bfee01
CIAAB_FIRE0     equ 6
CIAAB_SP        equ 3
CIAAB_SPMODE    equ 6

; CIA-B's time-of-day counter receives HSYNC. Read high first, low last.
CIAB_TODHI      equ $bfda00
CIAB_TODMID     equ $bfd900
CIAB_TODLO      equ $bfd800
