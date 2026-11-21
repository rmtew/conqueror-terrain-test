; Tank Render Lab: B86 benchmark suite
; Amiga 500 target: PAL, 68000, OCS, and 512 KiB of Chip RAM.
; Each display page has three 320 x 200 bitplanes.
; Start the program from AmigaDOS. No Conqueror files are necessary.
;
; Source sections
; - Playback: hardware ownership, stage control, input, and frame changes.
; - Display data: Copper lists, screen buffers, and panel graphics.
; - Scene: simulation, terrain, model geometry, and projection.
; - Painter and rasterizer: depth order, clipping, edges, and spans.
; - Inset map and FPS: map updates, measurement, and the results screen.
;
; A word has 16 bits. A longword has 32 bits.
; Q4, Q6, and Q7 values have 4, 6, and 7 fractional bits.
; A display page has all three bitplanes. The back page is not visible.
; FPS means frames per second. DMA means direct memory access.
; RLE means run-length encoding. ICR means interrupt control register.
; Input and output notes name the registers and their operand sizes.
        include "include/amiga_hw.i"
        include "include/amiga_os.i"

; The model projector uses a reciprocal table indexed by rounded depth.
; The projector uses exact division at the near plane or outside the table.
MODEL_RECIPROCAL_MODE equ 2

; ------------------------------------------------------------------------
; Display ownership, playback and frame publication
; ------------------------------------------------------------------------

        section code,code
; The exported trace labels do not add code to the timed stages.
        xdef play_title_wait,play_frame_begin,play_update_end,play_clear_begin,play_clear_end
        xdef trial_prep_work_end,trial_clear_final_launch
        xdef play_clear_second_fence,play_clear_final_launch_end
        xdef play_prepare_end,play_draw_end,play_flip_end,play_scene,play_front,play_back,play_return,play_scene_end
        xdef play_arm_late
        xdef play_copper_front,play_copper_back,play_copper1_begin,play_copper1_end,play_copper2_begin,play_copper2_end,play_pages
FPS_ROW equ 16
        xdef play_suite_stage,play_suite_done
        xdef play_suite_track,play_suite_hull
        xdef play_fps_tod,play_fps_rows,play_fps_live
        xdef play_fps_summary,play_fps_results_ready,play_fps_measure_done

; ------------------------------------------------------------------------
; Eight display colors and terrain material pairs
; ------------------------------------------------------------------------

TP_B1_EVEN equ 4
TP_B1_ODD equ 4
TP_B1_CODE equ $04
TP_43_EVEN equ 2
TP_43_ODD equ 2
TP_43_CODE equ $02
TP_54_EVEN equ 3
TP_54_ODD equ 2
TP_54_CODE equ $23
TP_65_EVEN equ 6
TP_65_ODD equ 2
TP_65_CODE equ $26
TP_46_EVEN equ 3
TP_46_ODD equ 3
TP_46_CODE equ $03
TP_C7_EVEN equ 5
TP_C7_ODD equ 4
TP_C7_CODE equ $45
        macro tp_palette
        dc.w COLOR00,$112
        dc.w COLOR01,$f43
        dc.w COLOR02,$073
        dc.w COLOR03,$0a3
        dc.w COLOR04,$653
        dc.w COLOR05,$b84
        dc.w COLOR06,$4c4
        dc.w COLOR07,$fd9
        endm

; ------------------------------------------------------------------------
; Scene scratch record layout and capture ABI
; ------------------------------------------------------------------------

; Keep these offsets constant for the scene capture tools.
; The maximum scene has 334 vertices:
; - 156 terrain vertices, 80 tank vertices, and 48 tree vertices.
; - 10 house vertices, 24 structure vertices, and 16 effect vertices.
SC_MAX_VERTICES equ 352
SC_MAX_FACES equ 224
SC_GROUND_MAX equ 21
SC_GRID_WIDTH equ 12
SC_GRID_DEPTH equ 16
; Use the lattice bounds to select props. Do not use the projected strip bounds.
SC_PROP_X_INTERVALS equ 12
SC_PROP_Z_INTERVALS equ 11
SC_PROP_X_END equ 2*SC_PROP_X_INTERVALS
SC_PROP_Z_END equ 2*SC_PROP_Z_INTERVALS
SC_GRID_POINTS equ SC_GRID_WIDTH*SC_GRID_DEPTH
SC_GRID_X_END equ 2*(SC_GRID_WIDTH-1)
SC_GRID_Z_END equ 2*(SC_GRID_DEPTH-1)
sc_seed equ 0
sc_tick equ 4
sc_phase equ 8
sc_reciprocal equ 10
sc_sin_q7 equ 2058
sc_camx equ 2588
sc_camy equ 2590
sc_camz equ 2592
sc_camera_dx equ 2594
sc_camera_dz equ 2596
sc_screen_x equ 2598
sc_screen_y equ 2600
sc_camera_yaw equ 2602
sc_grid_x equ 2604
sc_grid_z equ sc_grid_x+2*SC_GRID_WIDTH
sc_axis_x equ sc_grid_z+2*SC_GRID_DEPTH
sc_axis_z equ sc_axis_x+12*SC_GRID_WIDTH
sc_axis_ground equ sc_axis_z+12*SC_GRID_DEPTH
sc_tank equ sc_axis_ground+8*(SC_GROUND_MAX+1)
sc_camera_vertices equ sc_tank+12
sc_world_vertices equ sc_camera_vertices+6*SC_MAX_VERTICES
sc_faces equ sc_world_vertices+6*SC_MAX_VERTICES
sc_projected equ sc_faces+12*SC_MAX_FACES
sc_outcode equ sc_projected+8*SC_MAX_VERTICES
sc_needed equ sc_outcode+SC_MAX_VERTICES
sc_order equ (sc_needed+SC_MAX_VERTICES+1)&-2
sc_sort_work equ sc_order+2*SC_MAX_FACES
sc_vertex_count equ sc_sort_work+2*SC_MAX_FACES
sc_face_count equ sc_vertex_count+2
sc_terrain_faces equ sc_face_count+2
sc_draw_count equ sc_terrain_faces+2
sc_draw_order_from_temp equ sc_draw_count+2
; Two bytes next to the painter state contain the limits of the tree face range.
; The end index is exclusive.
    ifgt SC_MAX_FACES-255
    fail "Tree face bounds must fit one byte"
    endif
sc_tree_first_face equ sc_draw_order_from_temp
sc_tree_end_face equ sc_draw_order_from_temp+1
sc_draw_mode equ sc_draw_order_from_temp+2
sc_terrain_end equ sc_draw_mode+4
; Put the simulation fields after the terrain fields to keep the capture offsets constant.
sc_turret_yaw   equ sc_terrain_end  ; Two yaw bytes, one for each tank.
sc_tracer_x     equ sc_turret_yaw+2  ; World X (Q7).
sc_tracer_y     equ sc_tracer_x+2  ; World Y (integer).
sc_tracer_z     equ sc_tracer_y+2  ; World Z (Q7).
sc_tracer_dx    equ sc_tracer_z+2  ; X displacement per tick (Q7).
sc_tracer_dz    equ sc_tracer_dx+2
sc_tracer_life  equ sc_tracer_dz+2  ; Zero means no visible tracer.
sc_tracer_tank  equ sc_tracer_life+2
sc_tracer_yaw   equ sc_tracer_tank+2  ; Yaw at launch.
sc_size         equ sc_tracer_yaw+2
sc_turret_bytes equ sc_size-sc_turret_yaw
PL_PLANES       equ 3
PL_WIDTH        equ 320
PL_HEIGHT       equ 200
PL_ROW_BYTES    equ PL_WIDTH/8
PL_PLANE_BYTES  equ PL_ROW_BYTES*PL_HEIGHT
PL_FRAME_BYTES  equ PL_PLANES*PL_PLANE_BYTES
PL_VIEW_TOP     equ 56
PL_VIEW_ROWS    equ PL_HEIGHT-PL_VIEW_TOP
; BLTSIZE: the height uses bits 15 to 6. The width uses bits 5 to 0.
PL_CLEAR_SIZE   equ PL_VIEW_ROWS*64+PL_ROW_BYTES/2
PL_DMA_MASK     equ $07ff
PL_IRQ_MASK     equ $7fff
PL_SEED         equ $54424e43
PL_TICKS        equ 4
PL_DIW_STOP     equ $f4c1
PL_ARM_BEGIN    equ (PL_DIW_STOP>>8)+1
PL_ARM_PAL_END  equ 311-256  ; Last permitted line: 310.
PL_ARM_NTSC_END equ 260-256  ; Last permitted line: 259.
PL_PAL_DETECT   equ 272-256  ; NTSC fields end before line 272.

        ; The window must end before line 256. The OCS automatic high bit must be clear.
        ; Leave one full line after the display window ends.
        iflt (PL_DIW_STOP>>8)-128
        fail "The Copper flip requires an OCS display stop below v256"
        endif
        ifge PL_ARM_BEGIN-256
        fail "The Copper flip post-display start must fit the low VPOS byte"
        endif

; AmigaDOS entry. The program uses a private stack until it returns to AmigaDOS.
play_entry:
        move.l  sp,play_host_stack
        lea     play_stack_end,sp
        movem.l d2-d7/a2-a6,-(sp)
        lea     play_pages,a0
        move.l  a0,play_front
        lea     PL_FRAME_BYTES(a0),a1
        move.l  a1,play_back
        lea     play_title_rle,a1
        bsr.w   play_unpack_panel
        bsr.w   play_display
        tst.l   d0
        bne.w   play_leave
play_title_wait:
        bsr.w   play_read_key
        cmpi.b  #$45,d0            ; Escape
        beq.w   play_exit
        btst    #CIAAB_FIRE0,CIAA_PRA
        beq.w   play_mouse_exit
        cmpi.b  #$40,d0            ; Space
        bne.s   play_title_wait
        clr.b   play_suite_stage
        move.l  #PL_SEED,-(sp)
        pea     play_scene
        bsr.w   tb_scene_init
        addq.l  #8,sp
        jsr     tb_map_init
        move.w  #2,play_headers_left
        clr.b   play_input_pending
        jsr     play_fps_stage_begin

play_frame_begin:
        movea.l play_back,a4
        bsr.w   play_begin_clear  ; Start the first clear before the simulation.
        lea     play_scene,a3
        move.l  a2,-(sp)
        movea.l a3,a2  ; Keep the scene address for all four ticks.
        moveq   #PL_TICKS-1,d6
        tst.b   play_suite_stage
        beq.s   .step
        moveq   #0,d6
.step:
        bsr.w   tb_scene_step
        dbra    d6,.step
        movea.l (sp)+,a2
play_update_end:
        tst.w   play_headers_left
        beq.s   .header_ready
        bsr.w   play_copy_header
        subq.w  #1,play_headers_left
.header_ready:
        jsr     play_fps_stamp_live
play_clear_begin:
        bsr.w   play_clear
play_clear_end:
        pea     MODEL_RECIPROCAL_MODE.w
        pea     (a3)
        bsr.w   tb_scene_prepare_draw
        addq.l  #8,sp
trial_prep_work_end:
        bsr.w   play_wait_blit  ; Wait for the last clear before drawing.
play_prepare_end:
        bsr.w   play_poll_input
        pea     (a4)
        pea     (a3)
        bsr.w   tb_scene_emit_draw
        addq.l  #8,sp
        jsr     tb_map_draw
play_draw_end:
        bsr.w   play_vblank
        move.l  play_copper_back,d0
        move.l  play_copper_front,play_copper_back
        move.l  d0,play_copper_front
        move.l  d0,CUSTOM+COP1LCH  ; The Copper reads this address at the next field start.
        move.l  play_back,d0
        move.l  play_front,play_back
        move.l  d0,play_front
play_flip_end:
        jsr     play_fps_measure
        bsr.w   play_poll_input
        btst    #0,play_input_pending  ; Escape has priority over the mouse button.
        bne.s   play_exit
        btst    #1,play_input_pending
        beq.w   play_suite_next
play_mouse_exit:
        btst    #CIAAB_FIRE0,CIAA_PRA
        beq.s   play_mouse_exit
play_exit:
        bsr.w   play_restore
        moveq   #0,d0
play_leave:
        movem.l (sp)+,d2-d7/a2-a6
        movea.l play_host_stack,sp
play_return:
        rts

; ------------------------------------------------------------------------
; Stage transitions and results screen
; ------------------------------------------------------------------------

PL_SUITE_CHASE_TICKS equ 512
PL_SUITE_FIRE_END    equ 24
PL_SUITE_PASS_END    equ 80
PL_SUITE_LAST_TICK   equ 128

play_suite_next:
        tst.b   play_suite_stage
        beq.s   .chase
        move.w  play_scene+sc_tick+2,d0
        cmpi.w  #PL_SUITE_LAST_TICK,d0
        bhs.w   play_suite_done
        cmpi.b  #1,play_suite_stage
        bne.s   .scenery
        cmpi.w  #PL_SUITE_FIRE_END,d0
        blo.w   play_frame_begin
        move.b  #2,play_suite_stage
        bsr.w   play_suite_new_header
        bra.w   play_frame_begin
.scenery:
        cmpi.b  #2,play_suite_stage
        bne.w   play_frame_begin
        cmpi.w  #PL_SUITE_PASS_END,d0
        blo.w   play_frame_begin
        move.b  #3,play_suite_stage
        bsr.w   play_suite_new_header
        bra.w   play_frame_begin
.chase:
        cmpi.l  #PL_SUITE_CHASE_TICKS,play_scene+sc_tick
        blo.w   play_frame_begin
        move.b  #1,play_suite_stage
        ; Clear the complete scene record, including unused vertex slots.
        ; No drawing or blitter operation uses the back page during this reset.
        lea     play_scene,a0
        move.w  #(play_scene_end-play_scene)/2-1,d0
.clear:
        clr.w   (a0)+
        dbra    d0,.clear
        move.l  #PL_SEED,-(sp)
        pea     play_scene
        bsr.w   tb_scene_init
        addq.l  #8,sp
        bsr.w   play_suite_new_header
        bra.w   play_frame_begin

play_suite_done:
        jsr     play_fps_show_results
play_suite_results_hold:
        bsr.w   play_poll_input
        btst    #0,play_input_pending
        bne.w   play_exit
        btst    #1,play_input_pending
        beq.s   play_suite_results_hold
        bra.w   play_mouse_exit

play_suite_new_header:
        jsr     play_fps_stage_begin
        move.w  #2,play_headers_left
        ; The header copy replaces the map area. Reset the map state for both pages.
        jmp     tb_map_init

; Return a keyboard byte without waiting for input.
; If a byte is available, hold the serial-port acknowledge signal for two complete scan lines.
play_read_key:
        moveq   #-1,d0
        btst    #CIAAB_SP,CIAA_ICR
        bne.s   play_decode_key
        rts
play_decode_key:
        move.b  CIAA_SDR,d0
        not.b   d0
        ror.b   #1,d0
        move.b  CIAA_CRA,d3  ; Save the serial-port direction.
        bset    #CIAAB_SPMODE,CIAA_CRA
        move.b  CUSTOM+VHPOSR,d1
        moveq   #2,d2
.wait:
        cmp.b   CUSTOM+VHPOSR,d1
        beq.s   .wait
        move.b  CUSTOM+VHPOSR,d1
        dbra    d2,.wait
        btst    #6,d3
        bne.s   .done
        bclr    #CIAAB_SPMODE,CIAA_CRA
.done:
        rts

; Record short mouse clicks and acknowledge keyboard bytes during a frame.
; The main loop processes an exit request after drawing and the last blitter operation.
play_poll_input:
        btst    #CIAAB_FIRE0,CIAA_PRA
        bne.s   .keyboard
        bset    #1,play_input_pending
.keyboard:
        ; A read of ICR acknowledges the serial port. Read ICR only once.
        btst    #CIAAB_SP,CIAA_ICR
        beq.s   .no_key
        movem.l d0-d3,-(sp)
        bsr.s   play_decode_key
        cmpi.b  #$45,d0
        bne.s   .restore
        bset    #0,play_input_pending
.restore:
        movem.l (sp)+,d0-d3
.no_key:
        rts

play_vblank:
        ; Wait until the display window ends. Leave one full line before the field ends.
        ; At line 256, a repeated low byte can select blanking or cause a retry.
        ; In the high-byte path, check bit 8 again to reject the start of a new field.
        move.b  play_arm_late,d0
.beam:
        btst    #VPOSB_V8_LO,CUSTOM+VPOSR+1
        bne.s   .high
        cmpi.b  #PL_ARM_BEGIN,CUSTOM+VHPOSR
        blo.s   .beam
        rts
.high:
        cmp.b   CUSTOM+VHPOSR,d0
        bls.s   .beam
        btst    #VPOSB_V8_LO,CUSTOM+VPOSR+1  ; Reject a field wrap during the read.
        beq.s   .beam
        rts

; Copy the fixed header to a back page on its first use in each stage.
; The map and live FPS routines update their own areas separately.
play_copy_header:
        lea     play_header,a0
        movea.l a4,a1
        moveq   #PL_PLANES-1,d1
.plane:
        move.w  #PL_VIEW_TOP*PL_ROW_BYTES/32-1,d0
.copy:
        rept 8
        move.l  (a0)+,(a1)+
        endr
        dbra    d0,.copy
        lea     PL_PLANE_BYTES-PL_VIEW_TOP*PL_ROW_BYTES(a1),a1
        dbra    d1,.plane
        ; Copy the stage title with the fixed header. Do not copy it on each frame.
        moveq   #0,d0
        move.b  play_suite_stage,d0
        lsl.w   #8,d0
        move.w  d0,d1
        add.w   d0,d0
        add.w   d1,d0
        lea     play_suite_labels,a0
        adda.w  d0,a0
        lea     22*PL_ROW_BYTES+8(a4),a1
        move.l  d2,-(sp)
        moveq   #PL_PLANES-1,d1
.title_plane:
        moveq   #7,d2
.title_row:
        rept 8
        move.l  (a0)+,(a1)+
        endr
        addq.l  #8,a1
        dbra    d2,.title_row
        lea     PL_PLANE_BYTES-8*PL_ROW_BYTES(a1),a1
        dbra    d1,.title_plane
        move.l  (sp)+,d2
        rts

; Clear only the viewport of the back page. Keep the map and header.
; Start each plane clear before its CPU phase: simulation, scene construction, or projection.
; Wait for the active clear before changing the blitter destination or drawing.
play_begin_clear:
        move.l  #$01000000,CUSTOM+BLTCON0
        move.l  #$ffffffff,CUSTOM+BLTAFWM
        clr.w   CUSTOM+BLTDMOD
        lea     PL_VIEW_TOP*PL_ROW_BYTES(a4),a0
        move.l  a0,CUSTOM+BLTDPTH
        move.w  #PL_CLEAR_SIZE,CUSTOM+BLTSIZE
        rts
play_clear:
        bsr.s   play_wait_blit  ; Wait for the first plane clear.
        lea     PL_PLANE_BYTES+PL_VIEW_TOP*PL_ROW_BYTES(a4),a0
        move.l  a0,CUSTOM+BLTDPTH
        move.w  #PL_CLEAR_SIZE,CUSTOM+BLTSIZE
        rts

; Start the last plane clear after scene construction. Only A0 changes.
play_clear_final:
play_clear_second_fence:
        bsr.s   play_wait_blit
        movea.l play_back,a0
        lea     2*PL_PLANE_BYTES+PL_VIEW_TOP*PL_ROW_BYTES(a0),a0
        move.l  a0,CUSTOM+BLTDPTH
trial_clear_final_launch:
        move.w  #PL_CLEAR_SIZE,CUSTOM+BLTSIZE
play_clear_final_launch_end:
        rts
play_wait_blit:
        ; Read DMACONR before the busy-bit test for early Agnus revisions.
        tst.w   CUSTOM+DMACONR
.wait:
        btst    #DMAB_BBUSY_HI,CUSTOM+DMACONR
        bne.s   .wait
        rts

play_display:
        movea.l SYSBASE_ADDR.w,a6
        lea     play_gfx_name(pc),a1
        moveq   #0,d0
        jsr     _LVOOpenLibrary(a6)
        move.l  d0,play_gfx
        bne.s   .open
        moveq   #20,d0
        rts
.open:
        movea.l d0,a6
        move.l  GB_ACTIVIEW(a6),play_view
        jsr     _LVOOwnBlitter(a6)  ; Prevent other tasks from using the blitter.
        jsr     _LVOWaitBlit(a6)  ; Wait before disabling interrupts.
        suba.l  a1,a1
        jsr     _LVOLoadView(a6)
        jsr     _LVOWaitTOF(a6)
        jsr     _LVOWaitTOF(a6)
        movea.l SYSBASE_ADDR.w,a6
        jsr     _LVOForbid(a6)
        move.w  CUSTOM+DMACONR,play_dma
        move.w  CUSTOM+INTENAR,play_irq
        move.w  #PL_IRQ_MASK,CUSTOM+INTENA
        move.w  CUSTOM+INTREQR,play_pending_irq
        move.w  #PL_DMA_MASK,CUSTOM+DMACON
        lea     play_pages,a0
        lea     play_bpl+2,a1
        bsr.w   .pointers
        lea     play_pages+PL_FRAME_BYTES,a0
        lea     play_bpl2+2,a1
        bsr.w   .pointers
        move.l  #play_copper,play_copper_front
        move.l  #play_copper2,play_copper_back
        clr.w   CUSTOM+COPCON
        move.l  #play_copper,CUSTOM+COP1LCH
        move.w  #DMAF_SETCLR|DMAF_DMAEN|DMAF_BPLEN|DMAF_COPEN|DMAF_BLTEN,CUSTOM+DMACON
        ; Use the short field limit until the beam passes the NTSC limit.
        ; If bit 8 stays set after that limit, use the PAL field limit.
        move.b  #PL_ARM_NTSC_END,play_arm_late
.high:
        btst    #VPOSB_V8_LO,CUSTOM+VPOSR+1
        beq.s   .high
.low:
        btst    #VPOSB_V8_LO,CUSTOM+VPOSR+1
        beq.s   .ready
        cmpi.b  #PL_PAL_DETECT,CUSTOM+VHPOSR
        blo.s   .low
        btst    #VPOSB_V8_LO,CUSTOM+VPOSR+1
        beq.s   .ready
        move.b  #PL_ARM_PAL_END,play_arm_late
.pal_low:
        btst    #VPOSB_V8_LO,CUSTOM+VPOSR+1
        bne.s   .pal_low
.ready:
        moveq   #0,d0
        rts

.pointers:
        moveq   #PL_PLANES-1,d0
.ptr:
        move.l  a0,d1
        move.w  d1,4(a1)
        swap    d1
        move.w  d1,(a1)
        addq.l  #8,a1
        lea     PL_PLANE_BYTES(a0),a0
        dbra    d0,.ptr
        rts

play_restore:
        move.w  #PL_DMA_MASK,CUSTOM+DMACON
        ; The program has exclusive use of the blitter. No blitter operation is active.
        ; Clear the blitter interrupt request only if it was clear on entry.
        btst    #INTB_BLIT,play_pending_irq+1
        bne.s   .keep_blit_request
        move.w  #INTF_BLIT,CUSTOM+INTREQ
.keep_blit_request:
        movea.l play_gfx,a6
        move.l  GB_COPINIT(a6),CUSTOM+COP1LCH
        move.w  play_dma,d0
        andi.w  #PL_DMA_MASK,d0
        ori.w   #DMAF_SETCLR,d0
        move.w  d0,CUSTOM+DMACON
        move.w  play_irq,d0
        andi.w  #PL_IRQ_MASK,d0
        ori.w   #INTF_SETCLR,d0
        move.w  d0,CUSTOM+INTENA
        movea.l SYSBASE_ADDR.w,a6
        jsr     _LVOPermit(a6)
        movea.l play_gfx,a6
        movea.l play_view,a1
        jsr     _LVOLoadView(a6)
        jsr     _LVOWaitTOF(a6)
        jsr     _LVOWaitTOF(a6)
        jsr     _LVODisownBlitter(a6)
        movea.l play_gfx,a1
        movea.l SYSBASE_ADDR.w,a6
        jmp     _LVOCloseLibrary(a6)

; Decode a panel directly into a display page.
; Inputs: A1 = word stream, A0 = destination (24,000 bytes). Both addresses are even.
; A positive count gives the number of literal words that follow.
; A negative count gives the negative of the repeat count for the next word.
; A zero count ends the stream. Only D0, D1, A0, and A1 change.
; The title and results screens use this routine outside the timed stages.
play_unpack_panel:
.packet:
        move.w  (a1)+,d0
        beq.s   .done
        bmi.s   .repeat
        subq.w  #1,d0
.literal:
        move.w  (a1)+,(a0)+
        dbra    d0,.literal
        bra.s   .packet
.repeat:
        neg.w   d0
        subq.w  #1,d0
        move.w  (a1)+,d1
.fill:
        move.w  d1,(a0)+
        dbra    d0,.fill
        bra.s   .packet
.done:
        rts

play_gfx_name: dc.b "graphics.library",0
        even
        section chip,data_c
play_copper1_begin:
play_copper:
        dc.w BPLCON0,$3200,BPLCON1,0,BPLCON2,0
        dc.w DIWSTRT,$2c81,DIWSTOP,PL_DIW_STOP,DDFSTRT,$0038,DDFSTOP,$00d0
        dc.w BPL1MOD,0,BPL2MOD,0
        dc.w SPR0POS,0,SPR0DATA,0,SPR1POS,0,SPR1DATA,0,SPR2POS,0,SPR2DATA,0,SPR3POS,0,SPR3DATA,0
        tp_palette
play_bpl:
        dc.w BPL1PTH,0,BPL1PTL,0,BPL2PTH,0,BPL2PTL,0,BPL3PTH,0,BPL3PTL,0
        dc.w $ffff,$fffe

play_copper1_end:
play_copper2_begin:
play_copper2:
        dc.w BPLCON0,$3200,BPLCON1,0,BPLCON2,0
        dc.w DIWSTRT,$2c81,DIWSTOP,PL_DIW_STOP,DDFSTRT,$0038,DDFSTOP,$00d0
        dc.w BPL1MOD,0,BPL2MOD,0
        dc.w SPR0POS,0,SPR0DATA,0,SPR1POS,0,SPR1DATA,0,SPR2POS,0,SPR2DATA,0,SPR3POS,0,SPR3DATA,0
        tp_palette
play_bpl2:
        dc.w BPL1PTH,0,BPL1PTL,0,BPL2PTH,0,BPL2PTL,0,BPL3PTH,0,BPL3PTL,0
        dc.w $ffff,$fffe

play_copper2_end:

        section game_state,bss
play_gfx:           ds.l 1
play_view:          ds.l 1
play_dma:           ds.w 1
play_irq:           ds.w 1
play_pending_irq:   ds.w 1
play_front:         ds.l 1
play_back:          ds.l 1
play_copper_front:  ds.l 1
play_copper_back:   ds.l 1
play_host_stack:    ds.l 1
play_headers_left:  ds.w 1
play_input_pending: ds.b 1
play_arm_late:      ds.b 1
        ; The xyz-v1 capture tag has no storage. Keep the following offsets constant.
        ifne (SC_GRID_WIDTH-12)|(SC_GRID_DEPTH-16)|(sc_camx-2588)|(sc_grid_x-2604)|(sc_grid_z-2628)
        fail "Recheck typed strip capture axis layout"
        endif
        ifne (sc_camera_vertices-3184)|(sc_world_vertices-5296)
        fail "Recheck typed strip capture vertex layout"
        endif
        xdef play_scene_typed_strip_v1
play_scene_typed_strip_v1:
play_scene:         ds.b sc_size+2*(SC_GRID_WIDTH-1)*(SC_GRID_DEPTH-1)+12
play_scene_end:
play_stack:         ds.b 4096  ; Private stack, immediately after the scene.
play_stack_end:
play_suite_track:   ds.w 4
play_suite_hull:    ds.b 2
play_suite_stage:   ds.b 1
play_fps_have:      ds.b 1
play_fps_dirty:     ds.b 1
        even
play_fps_win_count: ds.w 1
play_fps_win_lines: ds.l 1
play_fps_tod:       ds.l 1
play_fps_live:      ds.w 1
play_fps_rows:      ds.b 4*FPS_ROW
play_fps_summary:   ds.w 4*3+1

        section renderbuffer,bss_c
play_pages: ds.b 2*PL_FRAME_BYTES

        section panels,data

; Title screen: three bitplanes, 8,000 bytes each, encoded with word RLE.
play_title_rle:
        dc.w $fd7f,$0000
        dc.w $0001,$00ff
        dc.w $fff0,$ffff
        dc.w $0004,$ff00,$0000,$0000,$00ff
        dc.w $fff0,$ffff
        dc.w $0001,$ff00
        dc.w $fee0,$0000
        dc.w $0006,$0f9c,$8a20,$3cfa,$2f3e,$f008,$1cf0
        dc.w $fff2,$0000
        dc.w $0006,$0222,$ca40,$2283,$28a0,$8808,$2288
        dc.w $fff2,$0000
        dc.w $0006,$0222,$aa80,$2282,$a8a0,$8808,$2288
        dc.w $fff2,$0000
        dc.w $0006,$023e,$9b00,$3cf2,$68bc,$f008,$3ef0
        dc.w $fff2,$0000
        dc.w $0006,$0222,$8a80,$2882,$28a0,$a008,$2288
        dc.w $fff2,$0000
        dc.w $0006,$0222,$8a40,$2482,$28a0,$9008,$2288
        dc.w $fff2,$0000
        dc.w $0006,$0222,$8a20,$22fa,$2f3e,$880f,$a2f0
        dc.w $fc82,$0000
        dc.w $0006,$0003,$de38,$e7c0,$00f7,$ce79,$f000
        dc.w $fff2,$0000
        dc.w $0006,$0004,$1145,$1400,$0101,$1144,$4000
        dc.w $fff2,$0000
        dc.w $0006,$0004,$1145,$0404,$0101,$1144,$4000
        dc.w $fff2,$0000
        dc.w $0006,$0003,$9e7d,$0780,$00e1,$1f78,$4000
        dc.w $fff1,$0000
        dc.w $0005,$5045,$0400,$0011,$1150,$4000
        dc.w $fff1,$0000
        dc.w $0005,$5045,$1404,$0011,$1148,$4000
        dc.w $fff2,$0000
        dc.w $0006,$0007,$9044,$e7c0,$01e1,$1144,$4000
        dc.w $fef0,$0000
        dc.w $000a,$0001,$f3ce,$0010,$107d,$f7c0,$44e4,$4f7c,$001f,$44e7,$c000
        dc.w $fff6,$0000
        dc.w $0009,$0001,$0411,$0020,$1041,$0100,$6d14,$5040,$0010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0410,$0020,$1041,$0100,$5514,$5040,$4010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$e390,$0040,$1079,$e100,$5514,$4e78,$001e,$1041
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0050,$0080,$1041,$0100,$4514,$4140,$0010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0051,$0080,$1041,$0100,$4514,$4140,$4010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$f78e,$0100,$1f7d,$0100,$44e3,$9e7c,$001f,$44e1
        dc.w $fe7d,$0000
        dc.w $0001,$00ff
        dc.w $fff0,$ffff
        dc.w $0004,$ff00,$0000,$0000,$00ff
        dc.w $fff0,$ffff
        dc.w $0001,$ff00
        dc.w $fee2,$0000
        dc.w $000a,$0078,$e400,$39f3,$8e00,$e38f,$0010,$1f10,$e440,$3913,$9e00
        dc.w $fff6,$0000
        dc.w $000a,$0045,$1400,$4504,$5101,$1450,$0020,$1031,$1480,$4511,$1100
        dc.w $fff6,$0000
        dc.w $000a,$0045,$1400,$4504,$d301,$1410,$0020,$1010,$1500,$4111,$1100
        dc.w $fff6,$0000
        dc.w $000a,$0079,$f400,$7de5,$5501,$140e,$0040,$1e10,$2600,$41f1,$1e00
        dc.w $fff6,$0000
        dc.w $000a,$0041,$1400,$4416,$5901,$1401,$0080,$0110,$4500,$4111,$1000
        dc.w $fff6,$0000
        dc.w $000a,$0041,$1400,$4414,$5101,$1441,$0080,$0110,$8480,$4511,$1000
        dc.w $fff6,$0000
        dc.w $000a,$0041,$17c0,$45e3,$8e00,$e39e,$0100,$1e39,$f440,$3913,$9000
        dc.w $f9b4,$0000
        dc.w $0006,$0f9c,$8a20,$3cfa,$2f3e,$f008,$1cf0
        dc.w $fff2,$0000
        dc.w $0006,$0222,$ca40,$2283,$28a0,$8808,$2288
        dc.w $fff2,$0000
        dc.w $0006,$0222,$aa80,$2282,$a8a0,$8808,$2288
        dc.w $fff2,$0000
        dc.w $0006,$023e,$9b00,$3cf2,$68bc,$f008,$3ef0
        dc.w $fff2,$0000
        dc.w $0006,$0222,$8a80,$2882,$28a0,$a008,$2288
        dc.w $fff2,$0000
        dc.w $0006,$0222,$8a40,$2482,$28a0,$9008,$2288
        dc.w $fff2,$0000
        dc.w $0006,$0222,$8a20,$22fa,$2f3e,$880f,$a2f0
        dc.w $ff02,$0000
        dc.w $0005,$0003,$8e01,$f391,$4407,$917d
        dc.w $fff1,$0000
        dc.w $0005,$0004,$4400,$4459,$4804,$5141
        dc.w $fff1,$0000
        dc.w $0005,$0004,$4400,$4455,$5004,$5141
        dc.w $fff1,$0000
        dc.w $0005,$0007,$c400,$47d3,$6004,$5179
        dc.w $fff1,$0000
        dc.w $0005,$0004,$4400,$4451,$5004,$5141
        dc.w $fff1,$0000
        dc.w $0005,$0004,$4400,$4451,$4804,$5141
        dc.w $fff1,$0000
        dc.w $0006,$0004,$4e00,$4451,$4407,$8e7d,$f000
        dc.w $fdfe,$0000
        dc.w $0006,$0003,$de38,$e7c0,$00f7,$ce79,$f000
        dc.w $fff2,$0000
        dc.w $0006,$0004,$1145,$1400,$0101,$1144,$4000
        dc.w $fff2,$0000
        dc.w $0006,$0004,$1145,$0404,$0101,$1144,$4000
        dc.w $fff2,$0000
        dc.w $0006,$0003,$9e7d,$0780,$00e1,$1f78,$4000
        dc.w $fff1,$0000
        dc.w $0005,$5045,$0400,$0011,$1150,$4000
        dc.w $fff1,$0000
        dc.w $0005,$5045,$1404,$0011,$1148,$4000
        dc.w $fff2,$0000
        dc.w $0006,$0007,$9044,$e7c0,$01e1,$1144,$4000
        dc.w $f620,$0000
        dc.w $0001,$00ff
        dc.w $fff0,$ffff
        dc.w $0004,$ff00,$0000,$0000,$00ff
        dc.w $fff0,$ffff
        dc.w $0001,$ff00
        dc.w $fee0,$0000
        dc.w $0006,$0f9c,$8a20,$3cfa,$2f3e,$f008,$1cf0
        dc.w $fff2,$0000
        dc.w $0006,$0222,$ca40,$2283,$28a0,$8808,$2288
        dc.w $fff2,$0000
        dc.w $0006,$0222,$aa80,$2282,$a8a0,$8808,$2288
        dc.w $fff2,$0000
        dc.w $0006,$023e,$9b00,$3cf2,$68bc,$f008,$3ef0
        dc.w $fff2,$0000
        dc.w $0006,$0222,$8a80,$2882,$28a0,$a008,$2288
        dc.w $fff2,$0000
        dc.w $0006,$0222,$8a40,$2482,$28a0,$9008,$2288
        dc.w $fff2,$0000
        dc.w $0006,$0222,$8a20,$22fa,$2f3e,$880f,$a2f0
        dc.w $ff02,$0000
        dc.w $0005,$0003,$8e01,$f391,$4407,$917d
        dc.w $fff1,$0000
        dc.w $0005,$0004,$4400,$4459,$4804,$5141
        dc.w $fff1,$0000
        dc.w $0005,$0004,$4400,$4455,$5004,$5141
        dc.w $fff1,$0000
        dc.w $0005,$0007,$c400,$47d3,$6004,$5179
        dc.w $fff1,$0000
        dc.w $0005,$0004,$4400,$4451,$5004,$5141
        dc.w $fff1,$0000
        dc.w $0005,$0004,$4400,$4451,$4804,$5141
        dc.w $fff1,$0000
        dc.w $0006,$0004,$4e00,$4451,$4407,$8e7d,$f000
        dc.w $fdfe,$0000
        dc.w $0006,$0003,$de38,$e7c0,$00f7,$ce79,$f000
        dc.w $fff2,$0000
        dc.w $0006,$0004,$1145,$1400,$0101,$1144,$4000
        dc.w $fff2,$0000
        dc.w $0006,$0004,$1145,$0404,$0101,$1144,$4000
        dc.w $fff2,$0000
        dc.w $0006,$0003,$9e7d,$0780,$00e1,$1f78,$4000
        dc.w $fff1,$0000
        dc.w $0005,$5045,$0400,$0011,$1150,$4000
        dc.w $fff1,$0000
        dc.w $0005,$5045,$1404,$0011,$1148,$4000
        dc.w $fff2,$0000
        dc.w $0006,$0007,$9044,$e7c0,$01e1,$1144,$4000
        dc.w $fef0,$0000
        dc.w $000a,$0001,$f3ce,$0010,$107d,$f7c0,$44e4,$4f7c,$001f,$44e7,$c000
        dc.w $fff6,$0000
        dc.w $0009,$0001,$0411,$0020,$1041,$0100,$6d14,$5040,$0010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0410,$0020,$1041,$0100,$5514,$5040,$4010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$e390,$0040,$1079,$e100,$5514,$4e78,$001e,$1041
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0050,$0080,$1041,$0100,$4514,$4140,$0010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0051,$0080,$1041,$0100,$4514,$4140,$4010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$f78e,$0100,$1f7d,$0100,$44e3,$9e7c,$001f,$44e1
        dc.w $fe7d,$0000
        dc.w $0001,$00ff
        dc.w $fff0,$ffff
        dc.w $0004,$ff00,$0000,$0000,$00ff
        dc.w $fff0,$ffff
        dc.w $0001,$ff00
        dc.w $fee2,$0000
        dc.w $000a,$0078,$e400,$39f3,$8e00,$e38f,$0010,$1f10,$e440,$3913,$9e00
        dc.w $fff6,$0000
        dc.w $000a,$0045,$1400,$4504,$5101,$1450,$0020,$1031,$1480,$4511,$1100
        dc.w $fff6,$0000
        dc.w $000a,$0045,$1400,$4504,$d301,$1410,$0020,$1010,$1500,$4111,$1100
        dc.w $fff6,$0000
        dc.w $000a,$0079,$f400,$7de5,$5501,$140e,$0040,$1e10,$2600,$41f1,$1e00
        dc.w $fff6,$0000
        dc.w $000a,$0041,$1400,$4416,$5901,$1401,$0080,$0110,$4500,$4111,$1000
        dc.w $fff6,$0000
        dc.w $000a,$0041,$1400,$4414,$5101,$1441,$0080,$0110,$8480,$4511,$1000
        dc.w $fff6,$0000
        dc.w $000a,$0041,$17c0,$45e3,$8e00,$e39e,$0100,$1e39,$f440,$3913,$9000
        dc.w $fd7b,$0000
        dc.w $0000

; Fixed header for the four stages. The map and live FPS have separate fields.
play_header:
        ; Plane 0, palette index bit 0; bit 15 is the leftmost pixel.
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dc.w $0007,$ffff,$ffff,$e000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2003,$e722,$880f,$3e8b,$cfbc,$0207,$3c00,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88b2,$9008,$a0ca,$2822,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88aa,$a008,$a0aa,$2822,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$8fa6,$c00f,$3c9a,$2f3c,$020f,$bc00,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88a2,$a00a,$208a,$2828,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88a2,$9009,$208a,$2824,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88a2,$8808,$be8b,$cfa2,$03e8,$bc00,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2003,$e79c,$0020,$20fb,$ef80,$89c8,$9ef8,$003e,$89cf,$8000,$0000,$0000,$0fbc,$7800,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2002,$0822,$0040,$2082,$0200,$da28,$a080,$0020,$8882,$0000,$0000,$0000,$0822,$8000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2002,$0820,$0040,$2082,$0200,$aa28,$a080,$8020,$5082,$0000,$0000,$0000,$0822,$8080,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2003,$c720,$0080,$20f3,$c200,$aa28,$9cf0,$003c,$2082,$0000,$0000,$0000,$0f3c,$7000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2002,$00a0,$0100,$2082,$0200,$8a28,$8280,$0020,$5082,$0000,$0000,$0000,$0820,$0800,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2002,$00a2,$0100,$2082,$0200,$8a28,$8280,$8020,$8882,$0000,$0000,$0000,$0820,$0880,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2003,$ef1c,$0200,$3efa,$0200,$89c7,$3cf8,$003e,$89c2,$0000,$0000,$0000,$0820,$f000,$0000,$0000,$0000
        dc.w $0007,$ffff,$ffff,$e000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dc.w $ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff
        dcb.w 20,0
        dcb.w 20,0
        ; Plane 1, palette index bit 1; bit 15 is the leftmost pixel.
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dc.w $0000,$0000,$0000,$0003,$e722,$880f,$3e8b,$cfbc,$0207,$3c00,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0000,$0000,$0000,$0000,$88b2,$9008,$a0ca,$2822,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0000,$0000,$0000,$0000,$88aa,$a008,$a0aa,$2822,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0000,$0000,$0000,$0000,$8fa6,$c00f,$3c9a,$2f3c,$020f,$bc00,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0000,$0000,$0000,$0000,$88a2,$a00a,$208a,$2828,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0000,$0000,$0000,$0000,$88a2,$9009,$208a,$2824,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0000,$0000,$0000,$0000,$88a2,$8808,$be8b,$cfa2,$03e8,$bc00,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        ; Plane 2, palette index bit 2; bit 15 is the leftmost pixel.
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dc.w $0007,$ffff,$ffff,$e000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2003,$e722,$880f,$3e8b,$cfbc,$0207,$3c00,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88b2,$9008,$a0ca,$2822,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88aa,$a008,$a0aa,$2822,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$8fa6,$c00f,$3c9a,$2f3c,$020f,$bc00,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88a2,$a00a,$208a,$2828,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88a2,$9009,$208a,$2824,$0208,$a200,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$88a2,$8808,$be8b,$cfa2,$03e8,$bc00,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2003,$e79c,$0020,$20fb,$ef80,$89c8,$9ef8,$003e,$89cf,$8000,$0000,$0000,$0fbc,$7800,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2002,$0822,$0040,$2082,$0200,$da28,$a080,$0020,$8882,$0000,$0000,$0000,$0822,$8000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2002,$0820,$0040,$2082,$0200,$aa28,$a080,$8020,$5082,$0000,$0000,$0000,$0822,$8080,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2003,$c720,$0080,$20f3,$c200,$aa28,$9cf0,$003c,$2082,$0000,$0000,$0000,$0f3c,$7000,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2002,$00a0,$0100,$2082,$0200,$8a28,$8280,$0020,$5082,$0000,$0000,$0000,$0820,$0800,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2002,$00a2,$0100,$2082,$0200,$8a28,$8280,$8020,$8882,$0000,$0000,$0000,$0820,$0880,$0000,$0000,$0000
        dc.w $0004,$0000,$0000,$2003,$ef1c,$0200,$3efa,$0200,$89c7,$3cf8,$003e,$89c2,$0000,$0000,$0000,$0820,$f000,$0000,$0000,$0000
        dc.w $0007,$ffff,$ffff,$e000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dcb.w 20,0
        dc.w $ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff,$ffff
        dcb.w 20,0
        dcb.w 20,0

; Results background: three bitplanes, 8,000 bytes each, encoded with word RLE.
play_fps_results_rle:
        dc.w $fdce,$0000
        dc.w $0001,$0fff
        dc.w $fff2,$ffff
        dc.w $0001,$fff0
        dc.w $ff6d,$0000
        dc.w $000a,$000f,$9c8a,$203c,$fa2f,$3ef0,$081c,$f00f,$3e7a,$283e,$7800
        dc.w $fff6,$0000
        dc.w $000a,$0002,$22ca,$4022,$8328,$a088,$0822,$8808,$a082,$2808,$8000
        dc.w $fff6,$0000
        dc.w $000a,$0002,$22aa,$8022,$82a8,$a088,$0822,$8808,$a082,$2808,$8000
        dc.w $fff6,$0000
        dc.w $000a,$0002,$3e9b,$003c,$f268,$bcf0,$083e,$f00f,$3c72,$2808,$7000
        dc.w $fff6,$0000
        dc.w $000a,$0002,$228a,$8028,$8228,$a0a0,$0822,$880a,$200a,$2808,$0800
        dc.w $fff6,$0000
        dc.w $000a,$0002,$228a,$4024,$8228,$a090,$0822,$8809,$200a,$2808,$0800
        dc.w $fff6,$0000
        dc.w $000a,$0002,$228a,$2022,$fa2f,$3e88,$0fa2,$f008,$bef1,$cf88,$f000
        dc.w $ff7e,$0000
        dc.w $000a,$0001,$e390,$00e7,$ce38,$0040,$7c43,$8045,$e00e,$44e7,$8000
        dc.w $fff6,$0000
        dc.w $000a,$0001,$1450,$0114,$1144,$0080,$40c4,$4049,$1011,$4444,$4000
        dc.w $fff6,$0000
        dc.w $000a,$0001,$1450,$0114,$134c,$0080,$4040,$4051,$1010,$4444,$4000
        dc.w $fff6,$0000
        dc.w $000a,$0001,$e7d0,$01f7,$9554,$0100,$7840,$8061,$e010,$7c47,$8000
        dc.w $fff6,$0000
        dc.w $0009,$0001,$0450,$0110,$5964,$0200,$0441,$0051,$1010,$4444
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0450,$0110,$5144,$0200,$0442,$0049,$1011,$4444
        dc.w $fff5,$0000
        dc.w $0009,$0001,$045f,$0117,$8e38,$0400,$78e7,$c045,$e00e,$44e4
        dc.w $fef4,$0000
        dc.w $0001,$00ff
        dc.w $fff2,$ffff
        dc.w $0001,$ff00
        dc.w $ffd4,$0000
        dc.w $0003,$0072,$271e,$f800
        dc.w $ffef,$0000
        dc.w $0003,$008a,$28a0,$8000
        dc.w $ffef,$0000
        dc.w $0003,$0082,$28a0,$8000
        dc.w $ffef,$0000
        dc.w $0003,$0083,$ef9c,$f000
        dc.w $ffef,$0000
        dc.w $0003,$0082,$2882,$8000
        dc.w $ffef,$0000
        dc.w $0003,$008a,$2882,$8000
        dc.w $ffef,$0000
        dc.w $0003,$0072,$28bc,$f800
        dc.w $ff3b,$0000
        dc.w $0006,$0073,$cf3c,$71c7,$220b,$e73c,$f800
        dc.w $fff2,$0000
        dc.w $0006,$008a,$28a2,$8a28,$a212,$0222,$8000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$28a2,$8a28,$2212,$0222,$8000
        dc.w $fff2,$0000
        dc.w $0006,$00fb,$cf3c,$8be8,$3e23,$c23c,$f000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$0828,$8a28,$2242,$0228,$8000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$0824,$8a28,$a242,$0224,$8000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$0822,$7227,$2282,$0722,$f800
        dc.w $ff3e,$0000
        dc.w $0005,$0079,$cfa2,$fbc8,$8072,$2000
        dc.w $fff1,$0000
        dc.w $0005,$0082,$2832,$8228,$8023,$2000
        dc.w $fff1,$0000
        dc.w $0005,$0082,$082a,$8225,$0022,$a000
        dc.w $fff1,$0000
        dc.w $0005,$0072,$0f26,$f3c2,$0022,$6000
        dc.w $fff1,$0000
        dc.w $0005,$000a,$0822,$8282,$0022,$2000
        dc.w $fff1,$0000
        dc.w $0005,$000a,$2822,$8242,$0022,$2000
        dc.w $fff1,$0000
        dc.w $0005,$00f1,$cfa2,$fa22,$0072,$2000
        dc.w $ff3d,$0000
        dc.w $0005,$0079,$cfa2,$fbc8,$8072,$2f80
        dc.w $fff1,$0000
        dc.w $0005,$0082,$2832,$8228,$808a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$0082,$082a,$8225,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$0072,$0f26,$f3c2,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$000a,$0822,$8282,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$000a,$2822,$8242,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$00f1,$cfa2,$fa22,$0071,$c200
        dc.w $ff8d,$0000
        dc.w $0001,$00ff
        dc.w $fff2,$ffff
        dc.w $0001,$ff00
        dc.w $ffa9,$0000
        dc.w $0005,$0089,$cf1e,$f80f,$bc72,$2f80
        dc.w $fffd,$0000
        dc.w $0002,$0089,$e000
        dc.w $fff6,$0000
        dc.w $0005,$008a,$28a0,$2008,$228b,$6800
        dc.w $fffd,$0000
        dc.w $0001,$00da
        dc.w $fff5,$0000
        dc.w $0005,$008a,$28a0,$2008,$228a,$a808
        dc.w $fffd,$0000
        dc.w $0001,$00aa
        dc.w $fff5,$0000
        dc.w $0005,$00aa,$2f1c,$200f,$3cfa,$af00
        dc.w $fffd,$0000
        dc.w $0002,$00a9,$c000
        dc.w $fff6,$0000
        dc.w $0005,$00aa,$2a02,$2008,$288a,$2800
        dc.w $fffd,$0000
        dc.w $0002,$0088,$2000
        dc.w $fff6,$0000
        dc.w $0005,$00aa,$2902,$2008,$248a,$2808
        dc.w $fffd,$0000
        dc.w $0002,$0088,$2000
        dc.w $fff6,$0000
        dc.w $0005,$0051,$c8bc,$2008,$228a,$2f80
        dc.w $fffd,$0000
        dc.w $0002,$008b,$c000
        dc.w $ff1a,$0000
        dc.w $000a,$0001,$f3ce,$0010,$107d,$f7c0,$44e4,$4f7c,$001f,$44e7,$c000
        dc.w $fff6,$0000
        dc.w $0009,$0001,$0411,$0020,$1041,$0100,$6d14,$5040,$0010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0410,$0020,$1041,$0100,$5514,$5040,$4010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$e390,$0040,$1079,$e100,$5514,$4e78,$001e,$1041
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0050,$0080,$1041,$0100,$4514,$4140,$0010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0051,$0080,$1041,$0100,$4514,$4140,$4010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$f78e,$0100,$1f7d,$0100,$44e3,$9e7c,$001f,$44e1
        dc.w $ff1c,$0000
        dc.w $0001,$0fff
        dc.w $fff2,$ffff
        dc.w $0001,$fff0
        dc.w $fb21,$0000
        dc.w $000a,$000f,$9c8a,$203c,$fa2f,$3ef0,$081c,$f00f,$3e7a,$283e,$7800
        dc.w $fff6,$0000
        dc.w $000a,$0002,$22ca,$4022,$8328,$a088,$0822,$8808,$a082,$2808,$8000
        dc.w $fff6,$0000
        dc.w $000a,$0002,$22aa,$8022,$82a8,$a088,$0822,$8808,$a082,$2808,$8000
        dc.w $fff6,$0000
        dc.w $000a,$0002,$3e9b,$003c,$f268,$bcf0,$083e,$f00f,$3c72,$2808,$7000
        dc.w $fff6,$0000
        dc.w $000a,$0002,$228a,$8028,$8228,$a0a0,$0822,$880a,$200a,$2808,$0800
        dc.w $fff6,$0000
        dc.w $000a,$0002,$228a,$4024,$8228,$a090,$0822,$8809,$200a,$2808,$0800
        dc.w $fff6,$0000
        dc.w $000a,$0002,$228a,$2022,$fa2f,$3e88,$0fa2,$f008,$bef1,$cf88,$f000
        dc.w $fea5,$0000
        dc.w $0002,$007b,$efbc
        dc.w $fffd,$0000
        dc.w $000b,$3913,$807d,$e3c0,$0000,$44e4,$407d,$e3c0,$0000,$44e4,$407d,$e3c0
        dc.w $fffc,$0000
        dc.w $0002,$0080,$8822
        dc.w $fffd,$0000
        dc.w $000b,$4514,$4041,$1400,$0000,$6c46,$4041,$1400,$0000,$6d14,$4041,$1400
        dc.w $fffc,$0000
        dc.w $0002,$0080,$8822
        dc.w $fffd,$0000
        dc.w $000b,$4514,$0041,$1400,$0000,$5445,$4041,$1400,$0000,$5512,$8041,$1400
        dc.w $fffc,$0000
        dc.w $0002,$0070,$8f3c
        dc.w $fffd,$0000
        dc.w $000b,$7d15,$c079,$e380,$0000,$5444,$c079,$e380,$0000,$55f1,$0079,$e380
        dc.w $fffc,$0000
        dc.w $0002,$0008,$8820
        dc.w $fffd,$0000
        dc.w $000b,$4514,$4041,$0040,$0000,$4444,$4041,$0040,$0000,$4512,$8041,$0040
        dc.w $fffc,$0000
        dc.w $0002,$0008,$8820
        dc.w $fffd,$0000
        dc.w $000b,$44a4,$4041,$0040,$0000,$4444,$4041,$0040,$0000,$4514,$4041,$0040
        dc.w $fffc,$0000
        dc.w $0002,$00f0,$8fa0
        dc.w $fffd,$0000
        dc.w $000b,$4443,$c041,$0780,$0000,$44e4,$4041,$0780,$0000,$4514,$4041,$0780
        dc.w $ff98,$0000
        dc.w $0003,$0072,$271e,$f800
        dc.w $ffef,$0000
        dc.w $0003,$008a,$28a0,$8000
        dc.w $ffef,$0000
        dc.w $0003,$0082,$28a0,$8000
        dc.w $ffef,$0000
        dc.w $0003,$0083,$ef9c,$f000
        dc.w $ffef,$0000
        dc.w $0003,$0082,$2882,$8000
        dc.w $ffef,$0000
        dc.w $0003,$008a,$2882,$8000
        dc.w $ffef,$0000
        dc.w $0003,$0072,$28bc,$f800
        dc.w $ff3b,$0000
        dc.w $0006,$0073,$cf3c,$71c7,$220b,$e73c,$f800
        dc.w $fff2,$0000
        dc.w $0006,$008a,$28a2,$8a28,$a212,$0222,$8000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$28a2,$8a28,$2212,$0222,$8000
        dc.w $fff2,$0000
        dc.w $0006,$00fb,$cf3c,$8be8,$3e23,$c23c,$f000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$0828,$8a28,$2242,$0228,$8000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$0824,$8a28,$a242,$0224,$8000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$0822,$7227,$2282,$0722,$f800
        dc.w $ff3e,$0000
        dc.w $0005,$0079,$cfa2,$fbc8,$8072,$2000
        dc.w $fff1,$0000
        dc.w $0005,$0082,$2832,$8228,$8023,$2000
        dc.w $fff1,$0000
        dc.w $0005,$0082,$082a,$8225,$0022,$a000
        dc.w $fff1,$0000
        dc.w $0005,$0072,$0f26,$f3c2,$0022,$6000
        dc.w $fff1,$0000
        dc.w $0005,$000a,$0822,$8282,$0022,$2000
        dc.w $fff1,$0000
        dc.w $0005,$000a,$2822,$8242,$0022,$2000
        dc.w $fff1,$0000
        dc.w $0005,$00f1,$cfa2,$fa22,$0072,$2000
        dc.w $ff3d,$0000
        dc.w $0005,$0079,$cfa2,$fbc8,$8072,$2f80
        dc.w $fff1,$0000
        dc.w $0005,$0082,$2832,$8228,$808a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$0082,$082a,$8225,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$0072,$0f26,$f3c2,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$000a,$0822,$8282,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$000a,$2822,$8242,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$00f1,$cfa2,$fa22,$0071,$c200
        dc.w $fdbe,$0000
        dc.w $000a,$0001,$f3ce,$0010,$107d,$f7c0,$44e4,$4f7c,$001f,$44e7,$c000
        dc.w $fff6,$0000
        dc.w $0009,$0001,$0411,$0020,$1041,$0100,$6d14,$5040,$0010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0410,$0020,$1041,$0100,$5514,$5040,$4010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$e390,$0040,$1079,$e100,$5514,$4e78,$001e,$1041
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0050,$0080,$1041,$0100,$4514,$4140,$0010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0051,$0080,$1041,$0100,$4514,$4140,$4010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$f78e,$0100,$1f7d,$0100,$44e3,$9e7c,$001f,$44e1
        dc.w $fad0,$0000
        dc.w $0001,$0fff
        dc.w $fff2,$ffff
        dc.w $0001,$fff0
        dc.w $ff6d,$0000
        dc.w $000a,$000f,$9c8a,$203c,$fa2f,$3ef0,$081c,$f00f,$3e7a,$283e,$7800
        dc.w $fff6,$0000
        dc.w $000a,$0002,$22ca,$4022,$8328,$a088,$0822,$8808,$a082,$2808,$8000
        dc.w $fff6,$0000
        dc.w $000a,$0002,$22aa,$8022,$82a8,$a088,$0822,$8808,$a082,$2808,$8000
        dc.w $fff6,$0000
        dc.w $000a,$0002,$3e9b,$003c,$f268,$bcf0,$083e,$f00f,$3c72,$2808,$7000
        dc.w $fff6,$0000
        dc.w $000a,$0002,$228a,$8028,$8228,$a0a0,$0822,$880a,$200a,$2808,$0800
        dc.w $fff6,$0000
        dc.w $000a,$0002,$228a,$4024,$8228,$a090,$0822,$8809,$200a,$2808,$0800
        dc.w $fff6,$0000
        dc.w $000a,$0002,$228a,$2022,$fa2f,$3e88,$0fa2,$f008,$bef1,$cf88,$f000
        dc.w $ff7e,$0000
        dc.w $000a,$0001,$e390,$00e7,$ce38,$0040,$7c43,$8045,$e00e,$44e7,$8000
        dc.w $fff6,$0000
        dc.w $000a,$0001,$1450,$0114,$1144,$0080,$40c4,$4049,$1011,$4444,$4000
        dc.w $fff6,$0000
        dc.w $000a,$0001,$1450,$0114,$134c,$0080,$4040,$4051,$1010,$4444,$4000
        dc.w $fff6,$0000
        dc.w $000a,$0001,$e7d0,$01f7,$9554,$0100,$7840,$8061,$e010,$7c47,$8000
        dc.w $fff6,$0000
        dc.w $0009,$0001,$0450,$0110,$5964,$0200,$0441,$0051,$1010,$4444
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0450,$0110,$5144,$0200,$0442,$0049,$1011,$4444
        dc.w $fff5,$0000
        dc.w $0009,$0001,$045f,$0117,$8e38,$0400,$78e7,$c045,$e00e,$44e4
        dc.w $ffa8,$0000
        dc.w $0002,$007b,$efbc
        dc.w $fffd,$0000
        dc.w $000b,$3913,$807d,$e3c0,$0000,$44e4,$407d,$e3c0,$0000,$44e4,$407d,$e3c0
        dc.w $fffc,$0000
        dc.w $0002,$0080,$8822
        dc.w $fffd,$0000
        dc.w $000b,$4514,$4041,$1400,$0000,$6c46,$4041,$1400,$0000,$6d14,$4041,$1400
        dc.w $fffc,$0000
        dc.w $0002,$0080,$8822
        dc.w $fffd,$0000
        dc.w $000b,$4514,$0041,$1400,$0000,$5445,$4041,$1400,$0000,$5512,$8041,$1400
        dc.w $fffc,$0000
        dc.w $0002,$0070,$8f3c
        dc.w $fffd,$0000
        dc.w $000b,$7d15,$c079,$e380,$0000,$5444,$c079,$e380,$0000,$55f1,$0079,$e380
        dc.w $fffc,$0000
        dc.w $0002,$0008,$8820
        dc.w $fffd,$0000
        dc.w $000b,$4514,$4041,$0040,$0000,$4444,$4041,$0040,$0000,$4512,$8041,$0040
        dc.w $fffc,$0000
        dc.w $0002,$0008,$8820
        dc.w $fffd,$0000
        dc.w $000b,$44a4,$4041,$0040,$0000,$4444,$4041,$0040,$0000,$4514,$4041,$0040
        dc.w $fffc,$0000
        dc.w $0002,$00f0,$8fa0
        dc.w $fffd,$0000
        dc.w $000b,$4443,$c041,$0780,$0000,$44e4,$4041,$0780,$0000,$4514,$4041,$0780
        dc.w $ffd4,$0000
        dc.w $0001,$00ff
        dc.w $fff2,$ffff
        dc.w $0001,$ff00
        dc.w $ffd4,$0000
        dc.w $0003,$0072,$271e,$f800
        dc.w $ffef,$0000
        dc.w $0003,$008a,$28a0,$8000
        dc.w $ffef,$0000
        dc.w $0003,$0082,$28a0,$8000
        dc.w $ffef,$0000
        dc.w $0003,$0083,$ef9c,$f000
        dc.w $ffef,$0000
        dc.w $0003,$0082,$2882,$8000
        dc.w $ffef,$0000
        dc.w $0003,$008a,$2882,$8000
        dc.w $ffef,$0000
        dc.w $0003,$0072,$28bc,$f800
        dc.w $ff3b,$0000
        dc.w $0006,$0073,$cf3c,$71c7,$220b,$e73c,$f800
        dc.w $fff2,$0000
        dc.w $0006,$008a,$28a2,$8a28,$a212,$0222,$8000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$28a2,$8a28,$2212,$0222,$8000
        dc.w $fff2,$0000
        dc.w $0006,$00fb,$cf3c,$8be8,$3e23,$c23c,$f000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$0828,$8a28,$2242,$0228,$8000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$0824,$8a28,$a242,$0224,$8000
        dc.w $fff2,$0000
        dc.w $0006,$008a,$0822,$7227,$2282,$0722,$f800
        dc.w $ff3e,$0000
        dc.w $0005,$0079,$cfa2,$fbc8,$8072,$2000
        dc.w $fff1,$0000
        dc.w $0005,$0082,$2832,$8228,$8023,$2000
        dc.w $fff1,$0000
        dc.w $0005,$0082,$082a,$8225,$0022,$a000
        dc.w $fff1,$0000
        dc.w $0005,$0072,$0f26,$f3c2,$0022,$6000
        dc.w $fff1,$0000
        dc.w $0005,$000a,$0822,$8282,$0022,$2000
        dc.w $fff1,$0000
        dc.w $0005,$000a,$2822,$8242,$0022,$2000
        dc.w $fff1,$0000
        dc.w $0005,$00f1,$cfa2,$fa22,$0072,$2000
        dc.w $ff3d,$0000
        dc.w $0005,$0079,$cfa2,$fbc8,$8072,$2f80
        dc.w $fff1,$0000
        dc.w $0005,$0082,$2832,$8228,$808a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$0082,$082a,$8225,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$0072,$0f26,$f3c2,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$000a,$0822,$8282,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$000a,$2822,$8242,$008a,$2200
        dc.w $fff1,$0000
        dc.w $0005,$00f1,$cfa2,$fa22,$0071,$c200
        dc.w $ff8d,$0000
        dc.w $0001,$00ff
        dc.w $fff2,$ffff
        dc.w $0001,$ff00
        dc.w $ffa9,$0000
        dc.w $0005,$0089,$cf1e,$f80f,$bc72,$2f80
        dc.w $fffd,$0000
        dc.w $0002,$0089,$e000
        dc.w $fff6,$0000
        dc.w $0005,$008a,$28a0,$2008,$228b,$6800
        dc.w $fffd,$0000
        dc.w $0001,$00da
        dc.w $fff5,$0000
        dc.w $0005,$008a,$28a0,$2008,$228a,$a808
        dc.w $fffd,$0000
        dc.w $0001,$00aa
        dc.w $fff5,$0000
        dc.w $0005,$00aa,$2f1c,$200f,$3cfa,$af00
        dc.w $fffd,$0000
        dc.w $0002,$00a9,$c000
        dc.w $fff6,$0000
        dc.w $0005,$00aa,$2a02,$2008,$288a,$2800
        dc.w $fffd,$0000
        dc.w $0002,$0088,$2000
        dc.w $fff6,$0000
        dc.w $0005,$00aa,$2902,$2008,$248a,$2808
        dc.w $fffd,$0000
        dc.w $0002,$0088,$2000
        dc.w $fff6,$0000
        dc.w $0005,$0051,$c8bc,$2008,$228a,$2f80
        dc.w $fffd,$0000
        dc.w $0002,$008b,$c000
        dc.w $ff1a,$0000
        dc.w $000a,$0001,$f3ce,$0010,$107d,$f7c0,$44e4,$4f7c,$001f,$44e7,$c000
        dc.w $fff6,$0000
        dc.w $0009,$0001,$0411,$0020,$1041,$0100,$6d14,$5040,$0010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0410,$0020,$1041,$0100,$5514,$5040,$4010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$e390,$0040,$1079,$e100,$5514,$4e78,$001e,$1041
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0050,$0080,$1041,$0100,$4514,$4140,$0010,$2841
        dc.w $fff5,$0000
        dc.w $0009,$0001,$0051,$0080,$1041,$0100,$4514,$4140,$4010,$4441
        dc.w $fff5,$0000
        dc.w $0009,$0001,$f78e,$0100,$1f7d,$0100,$44e3,$9e7c,$001f,$44e1
        dc.w $ff1c,$0000
        dc.w $0001,$0fff
        dc.w $fff2,$ffff
        dc.w $0001,$fff0
        dc.w $fdf6,$0000
        dc.w $0000

; Tank Render Lab 8x8 monochrome glyphs, one line per glyph:
; digits 0 through 9, dash, then decimal point. Each byte is one row.
play_fps_digits:
        dc.w $7088,$98a8,$c888,$7000
        dc.w $2060,$2020,$2020,$7000
        dc.w $7088,$0810,$2040,$f800
        dc.w $f008,$0870,$0808,$f000
        dc.w $1030,$5090,$f810,$1000
        dc.w $f880,$80f0,$0808,$f000
        dc.w $7080,$80f0,$8888,$7000
        dc.w $f808,$1020,$4040,$4000
        dc.w $7088,$8870,$8888,$7000
        dc.w $7088,$8878,$0808,$7000
        dc.w $0000,$0070,$0000,$0000
        dc.w $0000,$0000,$0000,$2000

; Tank Render Lab stage labels. Each label is 256x8: eight 32-byte rows
; for each of the three planes, then the next stage in playback order.
play_suite_labels:
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dc.w $2021,$0072,$271e,$f800,$1efb,$e73c,$880f,$bc72,$2f80,$71c7,$be00,$0000,$0000,$0000,$0000,$0000
        dc.w $6043,$008a,$28a0,$8000,$2022,$08a2,$8808,$228b,$6800,$8a28,$0800,$0000,$0000,$0000,$0000,$0000
        dc.w $2045,$0082,$28a0,$8080,$2022,$08a2,$5008,$228a,$a800,$8228,$0800,$0000,$0000,$0000,$0000,$0000
        dc.w $2089,$0083,$ef9c,$f000,$1c23,$cfa2,$200f,$3cfa,$af00,$8227,$0800,$0000,$0000,$0000,$0000,$0000
        dc.w $210f,$8082,$2882,$8000,$0222,$08a2,$2008,$288a,$2800,$8220,$8800,$0000,$0000,$0000,$0000,$0000
        dc.w $2101,$008a,$2882,$8080,$0222,$08a2,$2008,$248a,$2800,$8a20,$8800,$0000,$0000,$0000,$0000,$0000
        dc.w $7201,$0072,$28bc,$f800,$3c23,$e8bc,$2008,$228a,$2f80,$71cf,$0800,$0000,$0000,$0000,$0000,$0000
        dcb.w 16,0
        dc.w $2021,$0072,$271e,$f800,$1efb,$e73c,$880f,$bc72,$2f80,$71c7,$be00,$0000,$0000,$0000,$0000,$0000
        dc.w $6043,$008a,$28a0,$8000,$2022,$08a2,$8808,$228b,$6800,$8a28,$0800,$0000,$0000,$0000,$0000,$0000
        dc.w $2045,$0082,$28a0,$8080,$2022,$08a2,$5008,$228a,$a800,$8228,$0800,$0000,$0000,$0000,$0000,$0000
        dc.w $2089,$0083,$ef9c,$f000,$1c23,$cfa2,$200f,$3cfa,$af00,$8227,$0800,$0000,$0000,$0000,$0000,$0000
        dc.w $210f,$8082,$2882,$8000,$0222,$08a2,$2008,$288a,$2800,$8220,$8800,$0000,$0000,$0000,$0000,$0000
        dc.w $2101,$008a,$2882,$8080,$0222,$08a2,$2008,$248a,$2800,$8a20,$8800,$0000,$0000,$0000,$0000,$0000
        dc.w $7201,$0072,$28bc,$f800,$3c23,$e8bc,$2008,$228a,$2f80,$71cf,$0800,$0000,$0000,$0000,$0000,$0000
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dc.w $7021,$00f9,$c8a2,$01cf,$3cf1,$c71c,$8807,$22f0,$071c,$8bef,$00f9,$cf3e,$0000,$0000,$0000,$0000
        dc.w $8843,$0022,$2ca4,$0228,$a28a,$28a2,$8808,$b288,$0888,$da08,$8080,$88a0,$0000,$0000,$0000,$0000
        dc.w $0845,$0022,$2aa8,$0228,$a28a,$28a0,$8808,$aa88,$0888,$aa08,$8080,$88a0,$0000,$0000,$0000,$0000
        dc.w $1089,$0023,$e9b0,$03ef,$3cf2,$2fa0,$f80f,$a688,$0f88,$abc8,$80f0,$8f3c,$0000,$0000,$0000,$0000
        dc.w $210f,$8022,$28a8,$0228,$20a2,$28a0,$8808,$a288,$0888,$8a08,$8080,$8a20,$0000,$0000,$0000,$0000
        dc.w $4101,$0022,$28a4,$0228,$2092,$28a2,$8808,$a288,$0888,$8a08,$8080,$8920,$0000,$0000,$0000,$0000
        dc.w $fa01,$0022,$28a2,$0228,$2089,$c89c,$8808,$a2f0,$089c,$8bef,$0081,$c8be,$0000,$0000,$0000,$0000
        dcb.w 16,0
        dc.w $7021,$00f9,$c8a2,$01cf,$3cf1,$c71c,$8807,$22f0,$071c,$8bef,$00f9,$cf3e,$0000,$0000,$0000,$0000
        dc.w $8843,$0022,$2ca4,$0228,$a28a,$28a2,$8808,$b288,$0888,$da08,$8080,$88a0,$0000,$0000,$0000,$0000
        dc.w $0845,$0022,$2aa8,$0228,$a28a,$28a0,$8808,$aa88,$0888,$aa08,$8080,$88a0,$0000,$0000,$0000,$0000
        dc.w $1089,$0023,$e9b0,$03ef,$3cf2,$2fa0,$f80f,$a688,$0f88,$abc8,$80f0,$8f3c,$0000,$0000,$0000,$0000
        dc.w $210f,$8022,$28a8,$0228,$20a2,$28a0,$8808,$a288,$0888,$8a08,$8080,$8a20,$0000,$0000,$0000,$0000
        dc.w $4101,$0022,$28a4,$0228,$2092,$28a2,$8808,$a288,$0888,$8a08,$8080,$8920,$0000,$0000,$0000,$0000
        dc.w $fa01,$0022,$28a2,$0228,$2089,$c89c,$8808,$a2f0,$089c,$8bef,$0081,$c8be,$0000,$0000,$0000,$0000
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dc.w $f021,$0089,$c89e,$f807,$22f0,$0fbc,$fbe7,$8003,$e8be,$fbc0,$2273,$e880,$0000,$0000,$0000,$0000
        dc.w $0843,$008a,$28a0,$8008,$b288,$0222,$8208,$0002,$0c88,$8220,$2222,$0880,$0000,$0000,$0000,$0000
        dc.w $0845,$008a,$28a0,$8008,$aa88,$0222,$8208,$0802,$0a88,$8220,$2222,$0880,$0000,$0000,$0000,$0000
        dc.w $7089,$00fa,$289c,$f00f,$a688,$023c,$f3c7,$0003,$c988,$f3c0,$2223,$ca80,$0000,$0000,$0000,$0000
        dc.w $090f,$808a,$2882,$8008,$a288,$0228,$8200,$8002,$0888,$8280,$2222,$0a80,$0000,$0000,$0000,$0000
        dc.w $0901,$008a,$2882,$8008,$a288,$0224,$8200,$8802,$0888,$8240,$1422,$0a80,$0000,$0000,$0000,$0000
        dc.w $f201,$0089,$c73c,$f808,$a2f0,$0222,$fbef,$0003,$e888,$fa20,$0873,$e500,$0000,$0000,$0000,$0000
        dcb.w 16,0
        dc.w $f021,$0089,$c89e,$f807,$22f0,$0fbc,$fbe7,$8003,$e8be,$fbc0,$2273,$e880,$0000,$0000,$0000,$0000
        dc.w $0843,$008a,$28a0,$8008,$b288,$0222,$8208,$0002,$0c88,$8220,$2222,$0880,$0000,$0000,$0000,$0000
        dc.w $0845,$008a,$28a0,$8008,$aa88,$0222,$8208,$0802,$0a88,$8220,$2222,$0880,$0000,$0000,$0000,$0000
        dc.w $7089,$00fa,$289c,$f00f,$a688,$023c,$f3c7,$0003,$c988,$f3c0,$2223,$ca80,$0000,$0000,$0000,$0000
        dc.w $090f,$808a,$2882,$8008,$a288,$0228,$8200,$8002,$0888,$8280,$2222,$0a80,$0000,$0000,$0000,$0000
        dc.w $0901,$008a,$2882,$8008,$a288,$0224,$8200,$8802,$0888,$8240,$1422,$0a80,$0000,$0000,$0000,$0000
        dc.w $f201,$0089,$c73c,$f808,$a2f0,$0222,$fbef,$0003,$e888,$fa20,$0873,$e500,$0000,$0000,$0000,$0000
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dcb.w 16,0
        dc.w $1021,$0079,$cfa2,$fbc8,$8002,$0f9c,$8be0,$2273,$e880,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $3043,$0082,$2832,$8228,$8002,$0822,$8a00,$2222,$0880,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $5045,$0082,$082a,$8225,$0802,$0822,$8a00,$2222,$0880,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $9089,$0072,$0f26,$f3c2,$0002,$0f3e,$8bc0,$2223,$ca80,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $f90f,$800a,$0822,$8282,$0002,$0822,$8a00,$2222,$0a80,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $1101,$000a,$2822,$8242,$0802,$0822,$5200,$1422,$0a80,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $1201,$00f1,$cfa2,$fa22,$0003,$efa2,$23e0,$0873,$e500,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dcb.w 16,0
        dc.w $1021,$0079,$cfa2,$fbc8,$8002,$0f9c,$8be0,$2273,$e880,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $3043,$0082,$2832,$8228,$8002,$0822,$8a00,$2222,$0880,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $5045,$0082,$082a,$8225,$0802,$0822,$8a00,$2222,$0880,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $9089,$0072,$0f26,$f3c2,$0002,$0f3e,$8bc0,$2223,$ca80,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $f90f,$800a,$0822,$8282,$0002,$0822,$8a00,$2222,$0a80,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $1101,$000a,$2822,$8242,$0802,$0822,$5200,$1422,$0a80,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w $1201,$00f1,$cfa2,$fa22,$0003,$efa2,$23e0,$0873,$e500,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dcb.w 16,0

        section code,code

; ------------------------------------------------------------------------
; Scene simulation, geometry, and projection
; ------------------------------------------------------------------------

; Private scene routines use A2 as the scene record address.
; tb_scene_init and tb_scene_prepare_draw take their arguments on the stack.

    xdef tb_scene_init,tb_scene_step
SC_TERRAIN_ROW_END_BYTES equ 4*(SC_GRID_DEPTH-1)

SC_NEAR     equ 512                   ; The near plane is 32 world units away (Q4).
SC_FOCUS_Q4 equ 4096                  ; The focal length is 256 pixels.
SC_CAMERA_ORIGIN_Y equ 1216           ; The origin is page row 76, or viewport row 20 (Q4).
SC_EYE_HEIGHT equ 44
SC_EYE_DX equ 0
SC_EYE_DZ equ -200
SC_EYE_YAW equ 128
SC_CX       equ 2560                  ; The origin is pixel 160 (Q4).
    ifne (SC_GRID_WIDTH&3)|(SC_FOCUS_Q4-4096)
    fail "Recheck strip byte row alignment and exact X scaling"
    endif
; Store terrain heights in the reserved prefix of the world vertex array.
sc_strip_heights equ sc_world_vertices
; Store the cell counts after the height bytes and before the model vertices.
; The capture tool reconstructs terrain vertices from the two axes and the height
; bytes.
sc_strip_row_counts equ sc_strip_heights+SC_GRID_POINTS
    ifgt SC_GRID_DEPTH-1-5*SC_GRID_POINTS
    fail "Terrain row counts overlap actor world vertices"
    endif

; Multiply a Q7 sine in [-128, 128] by a fixed radius. The product fits in a signed
; word.
; Add 127 to a negative product before the shift to round toward zero.
SC_TANK_SCALE macro
    ifeq \1-35
    move.w  d0,d1
    add.w   d1,d1
    add.w   d0,d1
    lsl.w   #5,d0
    add.w   d1,d0
    else
    SC_TIMES48_W d0,d1
    endif
    bpl.s   .positive\@
    addi.w  #127,d0
.positive\@:
    asr.w   #7,d0
    endm

; Calculate 48 times the first argument as 3 times 16. The result occupies a word.
SC_TIMES48_W macro
    lsl.w   #4,\1
    move.w  \1,\2
    add.w   \1,\1
    add.w   \2,\1
    endm

; Read the Q7 sine table at A0. D2.W contains the phase, and the argument supplies the
; radius.
; Write the X, Y, and Z words at A1. Write zero for Y until the ground height is
; known.
SC_TANK_POSITION macro
    add.w   d2,d2
    move.w  (a0,d2.w),d0
    SC_TANK_SCALE \1
    move.w  d0,(a1)+
    clr.w   (a1)+
    addi.w  #128,d2
    andi.w  #510,d2
    move.w  (a0,d2.w),d0
    SC_TANK_SCALE \1
    move.w  d0,(a1)+
    rts
    endm

; Multiply the first argument by three. A word displacement does not use its upper 16
; bits.
SC_TIMES3_W macro
    move.w  \1,\2
    add.w   \1,\1
    add.w   \2,\1
    endm

; Initialize the scene record, the projection tables, and the first tank positions.
; At entry, 4(SP) holds the scene address and 8(SP) holds the longword seed.
tb_scene_init:
    movem.l d2-d3/a2-a3,-(sp)
    movea.l 20(sp),a2
    move.l  24(sp),d0
    move.l  d0,sc_seed(a2)
    bne.s   .seeded
    moveq   #1,d0
.seeded:
    clr.l   sc_tick(a2)
    move.b  d0,sc_phase(a2)
    ; This phase offset keeps both hulls on the terrain during Chase.
    addi.b  #40,d0
    move.b  d0,sc_phase+1(a2)

    lea     sc_sin_q7(a2),a0
    lea     sc_sine_table(pc),a1
    move.w  #127,d0
.copy_sin:
    move.l  (a1)+,(a0)+
    dbra    d0,.copy_sin

    lea     sc_reciprocal(a2),a0
    moveq   #15,d0
.clear_recip:
    clr.l   (a0)+
    dbra    d0,.clear_recip
    moveq   #32,d1
.recip:
    move.w  d1,d0
    lsr.w   #1,d0
    andi.l  #$ffff,d0
    addi.l  #SC_FOCUS_Q4*256,d0       ; Add half the depth for nearest rounding.
    divu.w  d1,d0
    move.w  d0,(a0)+
    addq.w  #1,d1
    cmpi.w  #512,d1
    bne.s   .recip

    clr.w   sc_vertex_count(a2)
    clr.w   sc_face_count(a2)
    clr.w   sc_draw_count(a2)
    clr.l   sc_draw_mode(a2)
    bsr     sc_update_tanks
    bsr     sc_camera
    bsr.w   sc_seed_prop_heights
    movem.l (sp)+,d2-d3/a2-a3
    rts

; Advance one simulation tick. A2 contains the scene address.
tb_scene_step:
    addq.l  #1,sc_tick(a2)
    addq.b  #1,sc_phase(a2)
    move.l  sc_tick(a2),d0
    andi.w  #31,d0
    cmpi.w  #6,d0
    bhs.s   .one
    addq.b  #1,sc_phase+1(a2)
.one:
    cmpi.w  #26,d0
    bhs.s   .updated
    addq.b  #1,sc_phase+1(a2)
.updated:
    ; Continue directly to sc_update_tanks. Its RTS returns to the caller of
    ; tb_scene_step.

; Use circular motion during Chase. The later stages use scripted forward motion.
sc_update_tanks:
    movem.l d2-d3,-(sp)
    tst.b   play_suite_stage
    beq.s   .stock
    bsr.w   sc_suite_drive
    bra.s   .ground
.stock:
    lea     sc_sin_q7(a2),a0
    lea     sc_tank(a2),a1
    moveq   #0,d2
    move.b  sc_phase(a2),d2
    bsr.w   .lead_tank
    moveq   #0,d2
    move.b  sc_phase+1(a2),d2
    bsr.w   .other_tank
.ground:
    bsr.w   sc_ground_and_aim
    movem.l (sp)+,d2-d3
    rts
.lead_tank:
    SC_TANK_POSITION 35
.other_tank:
    SC_TANK_POSITION 48

; ------------------------------------------------------------------------
; Stage-specific hull motion
; ------------------------------------------------------------------------

; In the drive stages, each hull moves in its own forward direction.
; A yaw of 64 points along positive X. Turret aim does not change the hull direction.
sc_suite_drive:
    move.l  a4,-(sp)
    tst.l   sc_tick(a2)
    bne.s   .advance
    move.w  #-124*128,play_suite_track
    move.w  #-70*128,play_suite_track+2
    move.w  #-48*128,play_suite_track+4
    move.w  #-118*128,play_suite_track+6
    move.w  #$4040,play_suite_hull
    moveq   #0,d1
    bra.s   .lead
.advance:
    move.w  sc_tick+2(a2),d3
    lea     .steering(pc),a0
.turn_at:
    move.w  (a0)+,d0
    beq.s   .speed
    cmp.w   d0,d3
    blo.s   .speed
    cmp.w   (a0)+,d3
    bhi.s   .next_turn
    move.w  (a0),d0
    add.b   d0,play_suite_hull
    bra.s   .speed
.next_turn:
    addq.l  #2,a0
    bra.s   .turn_at
.speed:
    moveq   #8,d1                     ; Use the 2-unit cruise speed (Q2).
    cmpi.w  #16,d3
    bhs.s   .lead
    moveq   #12,d1
    cmpi.w  #12,d3
    bls.s   .opening
    subi.w  #12,d3
    sub.w   d3,d1                     ; Decrease from 3 to 2 units per tick.
    bra.s   .lead
.opening:
    cmpi.w  #6,d3
    bhs.s   .lead
    move.w  d3,d1
    add.w   d1,d1                     ; Increase speed by half a unit per tick.
.lead:
    lea     sc_sin_q7(a2),a4
    lea     play_suite_track,a0
    lea     sc_tank(a2),a1
    moveq   #0,d0
    move.b  play_suite_hull,d0
    bsr.s   sc_suite_step_hull
    move.w  sc_tick+2(a2),d1
    subi.w  #22,d1
    bgt.s   .other_roll
    moveq   #0,d1                     ; Hold the second tank before its start tick.
    bra.s   .other
.other_roll:
    cmpi.w  #8,d1
    bls.s   .other
    moveq   #8,d1                     ; Limit the second tank to its cruise speed.
.other:
    moveq   #0,d0
    move.b  play_suite_hull+1,d0
    bsr.s   sc_suite_step_hull
    movea.l (sp)+,a4
    rts

.steering:
    dc.w    33,40,-1,49,56,1,89,96,1,105,112,-1,0

; D0.W contains yaw. D1.W contains speed in Q2 world units per tick.
; A0 points to two signed Q7 position words. A1 points to three integral position
; words.
; Use the same heading for X and Z. Round the integral X and Z toward negative
; infinity.
sc_suite_step_hull:
    add.w   d0,d0
    move.w  (a4,d0.w),d2
    muls.w  d1,d2
    asr.l   #2,d2
    add.w   d2,(a0)
    move.w  (a0)+,d2
    asr.w   #7,d2
    move.w  d2,(a1)+
    clr.w   (a1)+
    addi.w  #128,d0
    andi.w  #510,d0
    move.w  (a4,d0.w),d2
    muls.w  d1,d2
    asr.l   #2,d2
    add.w   d2,(a0)
    move.w  (a0)+,d2
    asr.w   #7,d2
    move.w  d2,(a1)+
    rts

; Keep the camera level and follow the lead tank. Fixed yaw lets an entire terrain row
; share its depth.
sc_camera:
    move.b  #SC_EYE_YAW,sc_camera_yaw(a2)
    move.w  #SC_CX,sc_screen_x(a2)
    move.w  #SC_CAMERA_ORIGIN_Y,sc_screen_y(a2)
    move.w  #SC_EYE_DX,sc_camera_dx(a2)
    move.w  #SC_EYE_DZ,sc_camera_dz(a2)
    move.w  sc_tank(a2),d1
    subi.w  #SC_EYE_DX,d1
    move.w  d1,sc_camx(a2)
    move.w  sc_tank+4(a2),d1
    subi.w  #SC_EYE_DZ,d1
    move.w  d1,sc_camz(a2)
    move.w  #SC_EYE_HEIGHT,sc_camy(a2)
    move.w  sc_tank+2(a2),d1
    add.w   d1,sc_camy(a2)
    rts

; D0.W, D1.W, and D2.W contain signed Q4 camera X, Y, and Z. Z is at least 32 world
; units.
; D3.W selects the method. Value 2 uses the reciprocal table when the rounded depth is
; in range.
; Return Q4 screen X and Y in D0.L and D1.L. Preserve D2-D7 and A2-A6.
sc_project:
    movem.l d4-d6,-(sp)
    cmpi.w  #2,d3
    bne.s   .direct
    move.w  d2,d4
    addq.w  #8,d4
    lsr.w   #4,d4
    cmpi.w  #511,d4
    bhi.s   .direct
    add.w   d4,d4
    lea     sc_reciprocal(a2),a1
    move.w  (a1,d4.w),d4
    bmi.s   .slot32
    muls.w  d4,d0
    muls.w  d4,d1
    tst.l   d0
    bpl.s   .shift_x
    addi.l  #4095,d0
.shift_x:
    asr.l   #8,d0
    asr.l   #4,d0
    tst.l   d1
    bpl.s   .shift_y
    addi.l  #4095,d1
.shift_y:
    asr.l   #8,d1
    asr.l   #4,d1
    bra.w   .centre
.slot32:
    ; The table entry for depth 32 is +32768, which does not fit in a signed word.
    ; Shift left by three to calculate (Q4 coordinate * 32768) / 4096.
    ext.l   d0
    ext.l   d1
    lsl.l   #3,d0
    lsl.l   #3,d1
    bra.s   .centre
.direct:
    muls.w  #SC_FOCUS_Q4,d0
    muls.w  #SC_FOCUS_Q4,d1
    divs.w  d2,d0
    divs.w  d2,d1
    ext.l   d0
    ext.l   d1
.centre:
    move.w  sc_screen_x(a2),d4
    ext.l   d4
    add.l   d4,d0
    move.w  sc_screen_y(a2),d4
    ext.l   d4
    sub.l   d1,d4
    move.l  d4,d1
    movem.l (sp)+,d4-d6
    rts

; ------------------------------------------------------------------------
; Q7 sine table
; ------------------------------------------------------------------------

; The table has 256 samples per turn. The scale is 128, so +1.0 is 128.
sc_sine_table:
    dc.w 0,3,6,9,13,16,19,22,25,28,31,34
    dc.w 37,40,43,46,49,52,55,58,60,63,66,68
    dc.w 71,74,76,79,81,84,86,88,91,93,95,97
    dc.w 99,101,103,105,106,108,110,111,113,114,116,117
    dc.w 118,119,121,122,122,123,124,125,126,126,127,127
    dc.w 127,128,128,128,128,128,128,128,127,127,127,126
    dc.w 126,125,124,123,122,122,121,119,118,117,116,114
    dc.w 113,111,110,108,106,105,103,101,99,97,95,93
    dc.w 91,88,86,84,81,79,76,74,71,68,66,63
    dc.w 60,58,55,52,49,46,43,40,37,34,31,28
    dc.w 25,22,19,16,13,9,6,3,0,-3,-6,-9
    dc.w -13,-16,-19,-22,-25,-28,-31,-34,-37,-40,-43,-46
    dc.w -49,-52,-55,-58,-60,-63,-66,-68,-71,-74,-76,-79
    dc.w -81,-84,-86,-88,-91,-93,-95,-97,-99,-101,-103,-105
    dc.w -106,-108,-110,-111,-113,-114,-116,-117,-118,-119,-121,-122
    dc.w -122,-123,-124,-125,-126,-126,-127,-127,-127,-128,-128,-128
    dc.w -128,-128,-128,-128,-127,-127,-127,-126,-126,-125,-124,-123
    dc.w -122,-122,-121,-119,-118,-117,-116,-114,-113,-111,-110,-108
    dc.w -106,-105,-103,-101,-99,-97,-95,-93,-91,-88,-86,-84
    dc.w -81,-79,-76,-74,-71,-68,-66,-63,-60,-58,-55,-52
    dc.w -49,-46,-43,-40,-37,-34,-31,-28,-25,-22,-19,-16
    dc.w -13,-9,-6,-3

; Append a model face. A2 contains the scene address, and D0.W-D3.W contain vertex
; indices.
; D4.W contains a material index. Bit 8 sets a triangle, with a duplicate fourth
; index.
; Preserve D0-D7 and A2-A6. A0 and A1 are scratch registers.
sc_face:
    move.l  d5,-(sp)
    moveq   #0,d5
    move.w  sc_face_count(a2),d5
    addq.w  #1,sc_face_count(a2)
    movea.w d5,a0
    add.w   d5,d5
    add.w   a0,d5
    add.w   d5,d5
    add.w   d5,d5
    lea     sc_faces(a2),a0
    adda.w  d5,a0
    move.w  d0,(a0)+
    move.w  d1,(a0)+
    move.w  d2,(a0)+
    move.w  d3,(a0)+
    moveq   #4,d5
    btst    #8,d4
    beq.s   .count
    moveq   #3,d5
.count:
    move.b  d5,(a0)+
    ; Resolve the model material here. Terrain uses a separate table.
    moveq   #0,d5
    move.b  d4,d5
    lea     sc_model_inks(pc),a1
    move.b  (a1,d5.w),(a0)
    lea     sc_needed(a2),a1
    move.b  #1,(a1,d0.w)
    move.b  #1,(a1,d1.w)
    move.b  #1,(a1,d2.w)
    move.b  #1,(a1,d3.w)
    move.l  (sp)+,d5
    rts

; Map model material indices to one of eight palette entries or to a checker pattern.
sc_model_inks:
    dc.b    0,4,5,2,2,3,6,3,2,3,6,4,5,1,7,7
    ; Use blue-black and brown for track ends and tops. Use dark green and brown for
    ; track sides.
    dc.b    $40,$42
    even

; ------------------------------------------------------------------------
; Terrain window, height interpolation and material preparation
; ------------------------------------------------------------------------

; The map samples a height at each node and assigns one material to each cell.
; The world lattice has 16 units between nodes.
SC_MAP_SHIFT equ 5
SC_MAP_CELLS equ 1<<SC_MAP_SHIFT
SC_MAP_SIDE equ SC_MAP_CELLS+1
SC_MAP_EDGE equ SC_MAP_CELLS*8
SC_TILE_SHIFT equ 4
SC_TILE_SIZE equ 1<<SC_TILE_SHIFT
SC_TILE_MASK equ SC_TILE_SIZE-1
    ifne (SC_GRID_WIDTH-12)|(sc_needed&1)
    fail "Precomputed strip need masks require an even 12-byte row"
    endif

; D0.W contains the tank coordinate, D1.W contains the node count minus one, and A0
; points to the destination.
; Snap the window to the lattice. Clamp the complete window to the map so it retains
; all requested cells.
sc_land_axis:
    andi.w  #-SC_TILE_SIZE,d0
    move.w  d1,d2
    lsr.w   #1,d2
    lsl.w   #SC_TILE_SHIFT,d2
    sub.w   d2,d0
    cmpi.w  #-SC_MAP_EDGE,d0
    bge.s   .high
    move.w  #-SC_MAP_EDGE,d0
.high:
    move.w  d1,d2
    lsl.w   #SC_TILE_SHIFT,d2
    neg.w   d2
    addi.w  #SC_MAP_EDGE,d2
    cmp.w   d2,d0
    ble.s   .node
    move.w  d2,d0
.node:
    move.w  d0,(a0)+
    addi.w  #SC_TILE_SIZE,d0
    dbra    d1,.node
    rts

; Convert a signed coordinate to a clamped cell index and a fraction in [0, 16].
SC_GROUND_CELL macro
    move.w  \1,\2
    cmpi.w  #SC_MAP_EDGE,\2
    blt.s   .low\@
    moveq   #SC_MAP_CELLS-1,\2
    moveq   #16,\3
    bra.s   .end\@
.low\@:
    addi.w  #SC_MAP_EDGE,\2
    bpl.s   .cell\@
    clr.w   \2
.cell\@:
    move.w  \2,\3
    andi.w  #SC_TILE_MASK,\3
    lsr.w   #SC_TILE_SHIFT,\2
.end\@:
    endm

; D0.W and D2.W contain world X and Z. Return the height in D1.W. Preserve all other
; registers.
; Use one height byte at a lattice node. Otherwise, use bilinear interpolation and
; round to the nearest integer.
; Clamp coordinates outside the map to the nearest edge.
sc_ground_height:
    movem.l d3-d6/a0,-(sp)
    SC_GROUND_CELL d0,d3,d4
    SC_GROUND_CELL d2,d5,d6
    move.w  d5,d1
    lsl.w   #SC_MAP_SHIFT,d1
    add.w   d1,d5                     ; Include the last node in the row stride.
    add.w   d3,d5
    lea     sc_heightmap,a0
    adda.w  d5,a0
    moveq   #0,d1
    move.b  (a0),d1
    tst.w   d4
    bne.s   .with_x
    tst.w   d6
    beq.s   .done
    ; When X is a lattice node, interpolate only along Z.
    moveq   #0,d5
    move.b  SC_MAP_SIDE(a0),d5
    sub.w   d1,d5
    muls.w  d6,d5
    lsl.w   #4,d1
    add.w   d5,d1
    bra.s   .x_only
.with_x:

    ; Interpolate each side in X at scale 16 before the Z step.
    moveq   #0,d3
    move.b  1(a0),d3
    sub.w   d1,d3
    muls.w  d4,d3
    lsl.w   #4,d1
    add.w   d3,d1
    tst.w   d6
    beq.s   .x_only
    moveq   #0,d3
    moveq   #0,d5
    move.b  SC_MAP_SIDE+1(a0),d3
    move.b  SC_MAP_SIDE(a0),d5
    sub.w   d5,d3
    muls.w  d4,d3
    lsl.w   #4,d5
    add.w   d3,d5
    sub.w   d1,d5
    muls.w  d6,d5
    ; The height range is [0, 21]. The weighted sum stays in [0, 5376].
    lsl.w   #4,d1
    add.w   d5,d1
    addi.w  #128,d1
    lsr.w   #8,d1
    bra.s   .done
.x_only:
    addq.w  #8,d1
    lsr.w   #4,d1
.done:
    movem.l (sp)+,d3-d6/a0
    rts

SC_CLASS_TERRAIN_FACES equ (SC_GRID_WIDTH-1)*(SC_GRID_DEPTH-1)
sc_strip equ sc_size
sc_strip_fallback equ sc_strip+2*SC_CLASS_TERRAIN_FACES

; Clip the terrain lattice in world space before projection. The camera faces negative
; Z.
SC_FOOT_WEST equ 56
SC_FOOT_EAST equ 100
SC_FOOT_NEAR equ 96
SC_FOOT_CENTRE equ 124
SC_FOOT_FAR  equ 304
sc_front_dx equ sc_axis_x+32

; D0.W and D2.W contain the bounds. D1.W contains the slot count minus one. A0 points
; to the destination.
; Write both clipped bounds and all lattice nodes between them.
; Repeat the high endpoint to keep the face IDs fixed.
sc_foot_axis:
    cmpi.w  #-SC_MAP_EDGE,d0
    bge.s   .low
    move.w  #-SC_MAP_EDGE,d0
.low:
    cmpi.w  #SC_MAP_EDGE,d2
    ble.s   .high
    move.w  #SC_MAP_EDGE,d2
.high:
    move.w  d0,(a0)+
    andi.w  #-SC_TILE_SIZE,d0
    subq.w  #1,d1
.next:
    addi.w  #SC_TILE_SIZE,d0
    cmp.w   d2,d0
    bge.s   .last
    move.w  d0,(a0)+
    dbra    d1,.next
    rts
.last:
    move.w  d2,(a0)+
    dbra    d1,.last
    rts

    ; D4.W contains the packed X descriptor. A6 points to the height row. Return the
    ; height in D1.W.
    macro SC_LATTICE_HEIGHT_EDGE
    move.w  d4,d3
    lsr.w   #8,d3
    andi.w  #SC_TILE_MASK,d3
    andi.w  #2*SC_MAP_CELLS-1,d4
    moveq   #0,d1
    moveq   #0,d0
    move.b  (a6,d4.w),d1
    move.b  1(a6,d4.w),d0
    sub.w   d1,d0
    muls.w  d3,d0
    lsl.w   #4,d1
    add.w   d0,d1
    addq.w  #8,d1
    lsr.w   #4,d1
    endm

; D2.W contains the largest admitted cell count for either side of the row.
; Copy its complete 12-byte vertex mask, including the zero suffix.
    macro SC_WRITE_PREFIX_NEEDED
    move.w  d2,d3
    add.w   d2,d2
    add.w   d3,d2
    lsl.w   #2,d2
    lea     (a1,d2.w),a4
    rept SC_GRID_WIDTH/4
    move.l  (a4)+,(a0)+
    endr
    endm

; Build the terrain strip and the terrain face records. A2 contains the scene address.
; Keep the prop window separate from the camera footprint.
sc_terrain:
    movem.l d2-d7/a3-a6,-(sp)
    move.w  #SC_GRID_POINTS,sc_vertex_count(a2)
    move.w  #SC_CLASS_TERRAIN_FACES,sc_face_count(a2)
    ; Use the route window for prop admission. The camera projection does not use
    ; these axes.
    move.w  sc_tank(a2),d0
    lea     sc_axis_x(a2),a0
    moveq   #SC_PROP_X_INTERVALS,d1
    bsr     sc_land_axis
    move.w  sc_tank+4(a2),d0
    lea     sc_axis_z(a2),a0
    moveq   #SC_PROP_Z_INTERVALS,d1
    bsr     sc_land_axis

    move.w  sc_camx(a2),d0
    andi.w  #-2,d0
    move.w  d0,d2
    subi.w  #SC_FOOT_WEST,d0
    addi.w  #SC_FOOT_EAST,d2
    lea     sc_grid_x(a2),a0
    moveq   #SC_GRID_WIDTH-1,d1
    bsr     sc_foot_axis
    move.w  sc_camx(a2),d0
    andi.w  #-2,d0
    add.w   sc_camz(a2),d0
    add.w   sc_camz(a2),d0
    subi.w  #2*SC_FOOT_CENTRE,d0
    move.w  d0,sc_front_dx(a2)
    move.w  sc_camz(a2),d0
    move.w  d0,d2
    subi.w  #SC_FOOT_FAR,d0
    subi.w  #SC_FOOT_NEAR,d2
    lea     sc_grid_z(a2),a0
    moveq   #SC_GRID_DEPTH-1,d1
    bsr     sc_foot_axis

    ; Classify each X coordinate once. Reuse its height column and fraction for every
    ; Z row.
    ; The packed descriptor uses the lattice dimensions checked below.
    ifne (SC_MAP_SIDE-17)*(SC_MAP_SIDE-33)|(SC_TILE_SHIFT-4)
    fail "Packed terrain heights support 17 or 33 nodes and 16-unit tiles"
    endif
    lea     -2*SC_GRID_WIDTH(sp),sp
    movea.l sp,a0
    lea     sc_grid_x(a2),a4
    moveq   #SC_GRID_WIDTH-1,d6
.height_col:
    move.w  (a4)+,d0
    SC_GROUND_CELL d0,d4,d1
    cmpi.w  #SC_TILE_SIZE,d1
    bne.s   .save_height_col
    addq.w  #1,d4                     ; Use the exact high-edge node.
    moveq   #0,d1
.save_height_col:
    tst.w   d1
    beq.s   .height_index
    ; The sign bit marks a fractional endpoint. Bits 8 through 11 hold the X fraction.
    lsl.w   #8,d1
    or.w    d1,d4
    bset    #15,d4
.height_index:
    move.w  d4,(a0)+
    dbra    d6,.height_col
    ifne SC_GRID_WIDTH-12
    fail "Recheck contiguous central height slice after grid width changes"
    endif
    ; Only the endpoints can be fractional, and padding repeats the high endpoint.
    ; If columns 1 and 8 are lattice nodes seven steps apart, all eight interior
    ; entries are consecutive.
    movea.w #-1,a4
    move.w  2(sp),d0
    bmi.s   .lattice_core_ready
    move.w  16(sp),d1
    bmi.s   .lattice_core_ready
    sub.w   d0,d1
    cmpi.w  #7,d1
    bne.s   .lattice_core_ready
    movea.w d0,a4
.lattice_core_ready:
    lea     sc_grid_z(a2),a3
    lea     sc_strip_heights(a2),a5
    moveq   #SC_GRID_DEPTH-1,d7
    move.w  #32767,d2                 ; Set a sentinel that cannot match the first row.
.vertex_row:
    cmp.w   (a3),d2
    beq.w   .duplicate_row
    move.w  (a3)+,d2
    ; All columns in a row share the Z cell and fraction.
    ; At an exact X node, interpolate between the two source rows without
    ; interpolating in X.
    SC_GROUND_CELL d2,d3,d5
    cmpi.w  #SC_TILE_SIZE,d5
    bne.s   .height_row
    ; Use the last height row directly. The map has no row beyond it.
    addq.w  #1,d3
    moveq   #0,d5
.height_row:
    move.w  d3,d4
    lsl.w   #SC_MAP_SHIFT,d4
    add.w   d4,d3
    lea     sc_heightmap,a6
    adda.w  d3,a6
    movea.l sp,a0
    moveq   #SC_GRID_WIDTH-1,d6
    tst.w   d5
    beq.w   .lattice_row
.vertex_column:
    move.w  (a0)+,d4
    bmi.s   .subcolumn
    moveq   #0,d1
    move.b  (a6,d4.w),d1
    moveq   #0,d3
    addi.w  #SC_MAP_SIDE,d4
    move.b  (a6,d4.w),d3
    sub.w   d1,d3
    muls.w  d5,d3
    lsl.w   #4,d1
    add.w   d3,d1
    addq.w  #8,d1
    lsr.w   #4,d1
    bra.s   .height_ready
.subcolumn:
    ; D3.W and D5.W contain the X and Z fractions. D4.W contains the source column.
    ; Restore the current Z in D2.W after the two interpolation steps.
    move.w  d4,d3
    lsr.w   #8,d3
    andi.w  #SC_TILE_MASK,d3
    andi.w  #2*SC_MAP_CELLS-1,d4
    moveq   #0,d1
    moveq   #0,d2
    move.b  (a6,d4.w),d1
    move.b  1(a6,d4.w),d2
    sub.w   d1,d2
    muls.w  d3,d2
    lsl.w   #4,d1
    add.w   d2,d1                     ; Keep this X interpolation at scale 16.
    moveq   #0,d2
    moveq   #0,d0
    move.b  SC_MAP_SIDE(a6,d4.w),d2
    move.b  SC_MAP_SIDE+1(a6,d4.w),d0
    sub.w   d2,d0
    muls.w  d3,d0
    lsl.w   #4,d2
    add.w   d0,d2
    sub.w   d1,d2
    muls.w  d5,d2
    lsl.w   #4,d1
    add.w   d2,d1
    addi.w  #128,d1
    lsr.w   #8,d1
    move.w  -2(a3),d2
.height_ready:
    move.b  d1,(a5)+
    dbra    d6,.vertex_column
    bra.w   .advance_vertex_row
.lattice_row:
    ; At an exact Z node, interpolate only in X. The height fits in an unsigned byte.
    moveq   #0,d1
    cmpa.w  #-1,a4
    beq.s   .lattice_point
    move.w  (a0)+,d4
    bmi.s   .lattice_left_edge
    move.b  (a6,d4.w),d1
    bra.s   .lattice_inner
.lattice_left_edge:
    SC_LATTICE_HEIGHT_EDGE
.lattice_inner:
    move.b  d1,(a5)+
    lea     (a6,a4.w),a1
    rept 8
    move.b  (a1)+,(a5)+
    endr
    ; Use the general X lookup for the final three columns.
    lea     16(a0),a0
    moveq   #2,d6
.lattice_point:
    move.w  (a0)+,d4
    bmi.s   .lattice_fraction
    move.b  (a6,d4.w),d1
.lattice_store:
    move.b  d1,(a5)+
    dbra    d6,.lattice_point
    bra.s   .advance_vertex_row
.lattice_fraction:
    SC_LATTICE_HEIGHT_EDGE
    bra.s   .lattice_store
.duplicate_row:
    ; Padding repeats the previous Z coordinate. Copy its height bytes without
    ; interpolation.
    addq.l  #2,a3
    lea     -SC_GRID_WIDTH(a5),a1
    rept SC_GRID_WIDTH/4
    move.l  (a1)+,(a5)+
    endr
.advance_vertex_row:
    dbra    d7,.vertex_row

    lea     2*SC_GRID_WIDTH(sp),sp

    lea     sc_grid_z(a2),a3
    lea     sc_strip(a2),a5           ; Each tile word holds its kind and solid ink.
    lea     sc_needed(a2),a0
    lea     .need_prefix(pc),a1
    ; A4 and A6 point to X coordinates and material bytes. The row counter counts
    ; backward.
    moveq   #0,d5                     ; Start with zero admitted cells in the previous row.
    ; Discard the repeated high X endpoints. Keep the last active interval in the
    ; upper word of D4.
    lea     sc_grid_x+SC_GRID_X_END(a2),a4
    move.w  (a4),d2
    moveq   #SC_GRID_WIDTH-2,d4
.trim_x:
    cmp.w   -(a4),d2
    dbne    d4,.trim_x
    swap    d4
    move.w  #$0400,d4                 ; Put the ordinary cell kind in the high byte.
    moveq   #SC_GRID_DEPTH-2,d7
.frow:
    move.w  (a3)+,d2
    cmp.w   (a3),d2
    beq.s   .padded_row
    addi.w  #SC_MAP_EDGE,d2
    andi.w  #(SC_MAP_CELLS-1)*SC_TILE_SIZE,d2
    add.w   d2,d2                     ; Convert the source row to a 32-byte material offset.
    lea     sc_grid_x(a2),a4
    move.w  (a4),d3
    addi.w  #SC_MAP_EDGE,d3
    lsr.w   #SC_TILE_SHIFT,d3
    add.w   d3,d2
    lea     sc_land_inks,a6
    adda.w  d2,a6
    move.w  (a3),d1
    add.w   d1,d1
    sub.w   sc_front_dx(a2),d1
    move.l  d4,d6
    swap    d6
    tst.w   d6
    bmi.s   .padded_row
    ; The final slot contains the upper endpoint even when the row has padding.
    ; If the high-X, high-Z corner is inside, all active cells are ordinary. This
    ; includes equality.
    move.w  sc_grid_x+SC_GRID_X_END(a2),d2
    add.w   d1,d2
    bgt.s   .partial_material_row
.ordinary_material_cell:
    move.b  (a6)+,d4
    move.w  d4,(a5)+
    dbra    d6,.ordinary_material_cell
    bra.s   .padded_column
.partial_material_row:
    move.w  -2(a3),d0
    add.w   d0,d0
    sub.w   sc_front_dx(a2),d0
.fcol:
    move.w  (a4)+,d2
    add.w   d0,d2
    bge.s   .padded_column
    move.w  (a4),d2
    add.w   d1,d2
    bgt.s   .diagonal
    move.w  d4,d2
.record:
    move.b  (a6)+,d2                  ; Keep the kind byte and replace the ink byte.
    move.w  d2,(a5)+
    dbra    d6,.fcol
    ; Count complete intervals even when the clipped X endpoint comes before the last
    ; slot.
    ; After DBRA completes the full loop, D6.W is -1.
    bra.s   .padded_column
.diagonal:
    move.w  #$0500,d2
    bra.s   .record
.padded_column:
    ; Subtract the current counter from its initial value to get the admitted cell
    ; count.
    ; Diagonal rejection and a trimmed X suffix use the same exit.
    move.l  d4,d2
    swap    d2
    sub.w   d6,d2
    moveq   #SC_GRID_WIDTH-2,d6
    sub.w   d2,d6
    bmi.s   .row_advance
    bra.s   .pad
.padded_row:
    moveq   #SC_GRID_WIDTH-2,d6
    moveq   #0,d2
.pad:
    clr.w   (a5)+
    dbra    d6,.pad
.row_advance:
    ; Store the admitted cell count before writing the vertex mask.
    ; A4 can hold the count address here. The 68000 indexed displacement has only
    ; eight signed bits.
    lea     sc_strip_row_counts(a2),a4
    move.b  d2,(a4,d7.w)
    ; A lattice row touches two cell rows. Use the larger of their admitted prefixes.
    ; If this prefix contains a cell, include its rightmost vertex.
    move.w  d2,d0
    cmp.w   d5,d2
    bhs.s   .mark_needed
    move.w  d5,d2
.mark_needed:
    move.w  d0,d5
    SC_WRITE_PREFIX_NEEDED
    dbra    d7,.frow
    ; Only the preceding cell row touches the final vertex row.
    move.w  d5,d2
    SC_WRITE_PREFIX_NEEDED
    movem.l (sp)+,d2-d7/a3-a6
    rts
.need_prefix:
    dcb.b SC_GRID_WIDTH,0
sc_need_cells set 1
    rept SC_GRID_WIDTH-1
    dcb.b sc_need_cells+1,1
    dcb.b SC_GRID_WIDTH-sc_need_cells-1,0
sc_need_cells set sc_need_cells+1
    endr

    section suite_map,data

; ------------------------------------------------------------------------
; Expanded authored route height map
; ------------------------------------------------------------------------

; The outer belt extends the original Tank Render Lab terrain.
; The map starts at (-256, -256). Each row has 33 height nodes and 32 material cells.
sc_heightmap:
    dc.b  1, 1, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 2, 1, 0, 0, 0
    dc.b  2, 3, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 3, 4, 6, 6, 6, 4, 3, 1, 0, 0
    dc.b  4, 5, 5, 5, 4, 2, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 2, 4, 7, 8, 9, 8, 7, 4, 2, 0, 0
    dc.b  5, 7, 7, 7, 5, 4, 2, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 3, 6, 8,10,11,10, 8, 6, 3, 0, 0
    dc.b  6, 8, 8, 8, 6, 4, 2, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 3, 6, 9,11,12,11, 9, 6, 3, 1, 0
    dc.b  7, 8, 9, 8, 7, 5, 2, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 3, 6, 8,10,11,10, 8, 6, 3, 0, 0
    dc.b  6, 8, 8, 8, 6, 4, 2, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 2, 4, 7, 8, 9, 8, 7, 4, 2, 0, 0
    dc.b  5, 7, 7, 7, 5, 4, 2, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 6, 6, 4, 3, 1, 0, 0
    dc.b  4, 5, 5, 5, 4, 2, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 3, 2, 1, 0, 0, 0
    dc.b  2, 3, 4, 3, 2, 1, 0, 0, 0, 0, 0, 1, 2, 4, 4, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0
    dc.b  1, 1, 2, 1, 1, 0, 0, 0, 0, 0, 0, 2, 4, 6, 7, 6, 4, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    dc.b  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 5, 7, 8, 7, 5, 4, 3, 3, 3, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    dc.b  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 5, 7, 8, 7, 7,10,12,12,11, 8, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    dc.b  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 5, 6, 6, 9,14,18,20,18,13, 7, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
    dc.b  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 4, 3, 8,13,18,21,19,14, 7, 2, 0, 0, 1, 2, 1, 1, 0, 0, 0
    dc.b  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 5, 4, 3, 4, 9,13,15,13, 9, 4, 0, 0, 1, 3, 4, 3, 2, 1, 0, 0
    dc.b  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 7, 9, 8, 6, 3, 2, 4, 6, 5, 2, 0, 0, 0, 2, 5, 6, 5, 4, 3, 1, 0
    dc.b  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 5, 9,11,11, 8, 4, 3, 3, 3, 3, 1, 0, 0, 0, 3, 7, 8, 7, 6, 4, 2, 1
    dc.b  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 6,10,12,11, 9, 6, 5, 6, 7, 6, 4, 1, 0, 0, 4, 9,10, 9, 8, 6, 4, 1
    dc.b  0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 1, 4, 8,10, 9, 7, 6, 6, 8, 9, 8, 6, 2, 0, 0, 4,11,11,11, 9, 7, 5, 2
    dc.b  0, 1, 2, 3, 3, 3, 2, 0, 0, 0, 0, 2, 5, 6, 6, 4, 4, 6, 9,10, 9, 6, 3, 0, 0, 5,12,12,12,10, 8, 5, 2
    dc.b  0, 2, 4, 5, 5, 5, 4, 1, 0, 0, 0, 0, 1, 2, 2, 1, 2, 5, 8, 9, 8, 5, 2, 0, 0, 5,12,13,12,10, 8, 5, 3
    dc.b  1, 3, 5, 6, 7, 6, 5, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 5, 6, 5, 3, 1, 0, 0, 5,12,12,12,10, 8, 5, 2
    dc.b  2, 4, 6, 8, 8, 8, 6, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 2, 2, 1, 0, 0, 0, 4,11,11,11, 9, 7, 5, 2
    dc.b  2, 5, 7, 9, 9, 9, 7, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 9,10, 9, 8, 6, 4, 1
    dc.b  3, 5, 7, 9,10, 9, 7, 2, 1, 0, 0, 0, 0, 0, 0, 1, 2, 2, 3, 3, 3, 3, 3, 2, 2, 3, 7, 8, 7, 6, 4, 2, 1
    dc.b  2, 5, 7, 9, 9, 9, 7, 5, 2, 0, 0, 0, 0, 1, 2, 4, 5, 7, 8, 9, 9, 9, 8, 7, 5, 4, 5, 6, 5, 4, 3, 1, 0
    dc.b  2, 4, 6, 8, 8, 8, 6, 4, 2, 0, 0, 0, 0, 1, 3, 4, 6, 8, 9,10,10,10, 9, 8, 6, 4, 3, 4, 3, 2, 1, 0, 0
    dc.b  1, 3, 5, 6, 7, 6, 5, 3, 1, 0, 0, 0, 0, 1, 3, 5, 7, 8, 9,10,11,10, 9, 8, 7, 5, 3, 2, 1, 1, 0, 0, 0
    dc.b  0, 2, 4, 5, 5, 5, 4, 2, 0, 0, 0, 0, 0, 1, 3, 4, 6, 8, 9,10,10,10, 9, 8, 6, 4, 3, 1, 0, 0, 0, 0, 0
    dc.b  0, 1, 2, 3, 3, 3, 2, 1, 0, 0, 0, 0, 0, 1, 2, 4, 5, 7, 8, 9, 9, 9, 8, 7, 5, 4, 2, 1, 0, 0, 0, 0, 0
    dc.b  0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 2, 4, 5, 6, 7, 7, 7, 6, 5, 4, 2, 1, 0, 0, 0, 0, 0, 0
    dc.b  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 4, 4, 4, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0

; ------------------------------------------------------------------------
; Authored terrain materials
; ------------------------------------------------------------------------

; Store resolved terrain inks by cell. The map inset uses its own three bitplanes.
sc_land_inks:
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,5,5,5,6,6,6,6,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,5,5,5,6,3,3,6,5,5,5,5
    dc.b 2,6,6,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,5,5,5,6,3,3,6,5,5,5,5
    dc.b 2,6,6,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,5,5,5,6,6,6,6,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,2,6,6,6,6,2,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,2,6,6,6,6,2,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,6,6,6,6,2,2,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,6,6,6,6,2,2,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,6,6,6,2,2,2,6,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,3,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,3,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,2,6,6,2,2,6,6,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5
    dc.b 2,2,2,2,2,2,2,2,2,2,6,3,3,2,2,2,2,5,5,5,5,5,5,5,5,2,2,2,2,2,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,6,3,6,2,2,2,2,5,5,5,5,5,5,5,5,2,2,2,2,2,2,2
    dc.b 4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4
    dc.b 2,2,2,2,2,2,2,2,2,6,6,6,2,2,2,2,2,6,6,2,2,2,2,2,2,2,6,6,6,2,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,6,6,2,2,2,2,2,6,6,2,2,2,2,2,2,6,3,3,6,6,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,6,2,2,2,2,2,2,2,6,3,3,3,6,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,6,2,2,2,2,2,2,2,6,3,3,3,6,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,3,3,6,6,2,2
    dc.b 2,2,2,6,6,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,6,6,2,2,2
    dc.b 2,2,6,6,6,6,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,6,2,2,2,2
    dc.b 2,2,6,6,6,6,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2
    dc.b 2,2,2,6,6,2,2,2,2,2,2,2,2,2,2,2,2,6,6,6,6,6,6,2,2,2,2,2,2,2,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,6,6,6,6,6,2,2,2,2,2,2,2,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,6,6,6,6,6,2,2,2,2,2,2,2,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,6,6,6,6,6,2,2,2,2,2,2,2,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,6,6,2,2,2,2,2,2,2,2,2,2,2
    dc.b 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2
    even
; Store the map inset as three planes, in screen row order.
tb_map_planes:
    dc.l $ffffffff,$ffffffff,$ffffffff,$ffffffff
    dc.l $ffffffff,$ffffffff,$fffcffff,$ffffffff
    dc.l $00000000,$ffcf3fff,$c3cfffff,$f3cfffff
    dc.l $ffffffff,$ffffffff,$ffffffff,$ffffffff
    dc.l $003fffff,$0f3fffff,$0f3fffff,$000fffff
    dc.l $0000ffff,$0000ffff,$0003ffff,$0000ffff
    dc.l $00000000,$ffffffff,$ffffffff,$ffffffff
    dc.l $ffffffff,$ffffffff,$ffffffff,$ffffffff
    dc.l $ffc00000,$f0c00000,$f0c00000,$fff00000
    dc.l $ffff0000,$ffff0000,$fffc0000,$ffff0000
    dc.l $ffffffff,$00000000,$00000000,$00000000
    dc.l $00000000,$00000000,$00000000,$00000000
    section code,code

    ; ------------------------------------------------------------------------
; Tank and scenery geometry
; ------------------------------------------------------------------------

; A5 points to cached products for the prism rotation.
    ; Return world X in D2.W and world Z in D0.W. Sum the products before rounding
    ; toward zero.
SC_PRISM_PRODUCT_BYTES equ 2          ; The prism bounds keep all products in signed words.
SC_PRISM_PAIR_BYTES equ 2*SC_PRISM_PRODUCT_BYTES

    macro SC_PRISM_XZ_BODY
    move.\3  \1*SC_PRISM_PAIR_BYTES(a5),d0
    add.\3   \2*SC_PRISM_PAIR_BYTES(a5),d0
    bpl.s   .xpos\@
    addi.\3  #127,d0
.xpos\@:
    asr.\3   #7,d0
    add.w   (a3),d0
    move.w  d0,d2
    move.\3  SC_PRISM_PRODUCT_BYTES+\2*SC_PRISM_PAIR_BYTES(a5),d0
    sub.\3   SC_PRISM_PRODUCT_BYTES+\1*SC_PRISM_PAIR_BYTES(a5),d0
    bpl.s   .zpos\@
    addi.\3  #127,d0
.zpos\@:
    asr.\3   #7,d0
    add.w   4(a3),d0
    endm

    macro SC_PRISM_XZ
    SC_PRISM_XZ_BODY \1,\2,w
    endm

    macro SC_PRISM_STORE_TERM
    move.w  \1,\2
    endm

    macro SC_PRISM_CORNER_PAIR
    SC_PRISM_XZ \1,\2
    move.w  d2,\3(a6)
    move.w  d4,\3+2(a6)
    move.w  d0,\3+4(a6)
    move.w  d2,\3+12(a6)
    move.w  d5,\3+14(a6)
    move.w  d0,\3+16(a6)
    endm

    macro SC_PRISM_CORNER
    SC_PRISM_XZ \1,\2
    move.w  d2,\3(a6)
    move.w  \4,\3+2(a6)
    move.w  d0,\3+4(a6)
    endm

; Append a prism. A3 points to its origin, and A4 points to its descriptor.
; The words give the X, Y, and Z bounds, the front upper inset, and flags. Color bytes
; follow.
; Flag bit 0 omits the top. Flag bit 1 selects the wedge.
; D0.W contains yaw in 1/256 turns. Return the first vertex index in D0.W.
sc_prism:
    movem.l d2-d7/a3-a6,-(sp)
    bsr.w   sc_prism_yaw
    bra.s   sc_prism_oriented

; D4.W and D5.W contain camera Z and X in prism coordinates. D6.W and D7.W contain
; sine and cosine.
; Prisms on the same articulated part can reuse all four words.
sc_prism_prepared:
    movem.l d2-d7/a3-a6,-(sp)
sc_prism_oriented:
    moveq   #0,d3
    cmp.w   8(a4),d4
    bge.s   .not_back
    bset    #0,d3
.not_back:
    btst    #1,15(a4)
    bne.s   .wedge_front
    cmp.w   10(a4),d4
    ble.s   .not_front
    bset    #1,d3
    bra.s   .not_front
.wedge_front:
    move.w  sc_camy(a2),d0
    sub.w   2(a3),d0                  ; Measure eye height from the model origin.
    sub.w   4(a4),d0
    ext.l   d0
    lsl.l   #2,d0
    move.w  6(a4),d1
    sub.w   4(a4),d1
    sub.w   10(a4),d4
    muls.w  d4,d1
    add.l   d1,d0
    ble.s   .not_front
    bset    #1,d3
.not_front:
    cmp.w   (a4),d5
    bge.s   .not_left
    bset    #2,d3
.not_left:
    cmp.w   2(a4),d5
    ble.s   .not_right
    bset    #3,d3
.not_right:
    btst    #0,15(a4)
    bne.s   .mask_ready
    btst    #1,15(a4)
    bne.s   .top
    move.w  sc_camy(a2),d0
    sub.w   2(a3),d0
    cmp.w   6(a4),d0
    ble.s   .mask_ready
.top:
    bset    #4,d3
.mask_ready:
    move.w  d3,-(sp)
    move.w  sc_vertex_count(a2),-(sp)
    ; Cache products for the two X coordinates and three possible Z coordinates.
    ; Keep signed products at full precision until the sum.
    lea     -5*SC_PRISM_PAIR_BYTES(sp),sp
    movea.l sp,a5
    move.w  (a4),d0
    move.w  d0,d1
    muls.w  d7,d0
    muls.w  d6,d1
    SC_PRISM_STORE_TERM d0,(a5)+
    SC_PRISM_STORE_TERM d1,(a5)+
    move.w  2(a4),d0
    move.w  d0,d1
    muls.w  d7,d0
    muls.w  d6,d1
    SC_PRISM_STORE_TERM d0,(a5)+
    SC_PRISM_STORE_TERM d1,(a5)+
    move.w  8(a4),d0
    move.w  d0,d1
    muls.w  d6,d0
    muls.w  d7,d1
    SC_PRISM_STORE_TERM d0,(a5)+
    SC_PRISM_STORE_TERM d1,(a5)+
    move.w  10(a4),d0
    move.w  d0,d1
    muls.w  d6,d0
    muls.w  d7,d1
    SC_PRISM_STORE_TERM d0,(a5)+
    SC_PRISM_STORE_TERM d1,(a5)+
    ; The upper and lower back corners share X and Z.
    ; The front corners also share X and Z when the upper front has no inset.
    move.w  12(a4),d3
    beq.s   .output
    move.w  10(a4),d0
    sub.w   d3,d0
    move.w  d0,d1
    muls.w  d6,d0
    muls.w  d7,d1
    SC_PRISM_STORE_TERM d0,(a5)+
    SC_PRISM_STORE_TERM d1,(a5)
.output:
    movea.l sp,a5
    move.w  sc_vertex_count(a2),d0
    addq.w  #8,sc_vertex_count(a2)
    SC_TIMES3_W d0,d1
    add.w   d0,d0
    lea     sc_world_vertices(a2),a6
    adda.w  d0,a6
    move.w  2(a3),d4
    move.w  d4,d5
    add.w   4(a4),d4
    add.w   6(a4),d5

    ; Keep all eight indices in the order that the face tables use.
    SC_PRISM_CORNER_PAIR 0,2,0
    SC_PRISM_CORNER_PAIR 1,2,6
    tst.w   d3
    bne.w   .inset
    SC_PRISM_CORNER_PAIR 0,3,24
    SC_PRISM_CORNER_PAIR 1,3,30
    bra.w   .built
.inset:
    SC_PRISM_CORNER 0,3,24,d4
    SC_PRISM_CORNER 1,3,30,d4
    SC_PRISM_CORNER 0,4,36,d5
    SC_PRISM_CORNER 1,4,42,d5
.built:
    lea     5*SC_PRISM_PAIR_BYTES(sp),sp
    move.w  (sp)+,d7
    move.w  (sp)+,d6
    lea     sc_box_faces(pc),a5
    btst    #1,15(a4)
    beq.s   .face_table
    lea     sc_wedge_faces(pc),a5
.face_table:
    ; Keep the output face pointer and both lookup addresses across the loop.
    ; No other geometry producer writes face records during this loop.
    lea     sc_model_inks(pc),a0
    lea     sc_needed(a2),a1
    move.w  sc_face_count(a2),d4
    SC_TIMES3_W d4,d5
    lsl.w   #2,d4
    lea     sc_faces(a2),a6
    adda.w  d4,a6
    suba.l  a3,a3
    moveq   #4,d5
.face_loop:
    moveq   #0,d4
    move.b  (a5)+,d4
    btst    d4,d6
    beq.s   .skip_face
    move.b  (a5)+,d4
    move.b  (a4,d4.w),d4
    moveq   #0,d0
    moveq   #0,d1
    moveq   #0,d2
    moveq   #0,d3
    move.b  (a5)+,d0
    move.b  (a5)+,d1
    move.b  (a5)+,d2
    move.b  (a5)+,d3
    add.w   d7,d0
    add.w   d7,d1
    add.w   d7,d2
    add.w   d7,d3
    ; Both prism face tables contain only quadrilaterals.
    ; The face cull calculates depth from the transformed vertices.
    movem.w d0-d3,(a6)
    move.b  (a0,d4.w),d4
    ori.w   #$0400,d4
    move.w  d4,8(a6)
    lea     12(a6),a6
    addq.l  #1,a3
    move.b  #1,(a1,d0.w)
    move.b  #1,(a1,d1.w)
    move.b  #1,(a1,d2.w)
    move.b  #1,(a1,d3.w)
    bra.s   .next_face
.skip_face:
    addq.l  #5,a5
.next_face:
    dbra    d5,.face_loop
    move.w  a3,d4
    add.w   d4,sc_face_count(a2)
    move.w  d7,d0
    movem.l (sp)+,d2-d7/a3-a6
    rts

; D0.W contains yaw and A3 points to the prism origin. Return the four rotation words
; in D4.W-D7.W.
; D0-D3 and A0 are scratch registers. Rotate with Q7 products and round toward zero.
sc_prism_yaw:
    lea     sc_sin_q7(a2),a0
    andi.w  #255,d0
    add.w   d0,d0
    move.w  (a0,d0.w),d6
    addi.w  #128,d0
    andi.w  #510,d0
    move.w  (a0,d0.w),d7
    move.w  sc_camx(a2),d2
    sub.w   (a3),d2
    move.w  sc_camz(a2),d3
    sub.w   4(a3),d3
    move.w  d7,d0
    muls.w  d2,d0
    move.w  d6,d1
    muls.w  d3,d1
    sub.l   d1,d0
    bsr     sc_div128
    move.w  d0,d5
    move.w  d6,d0
    muls.w  d2,d0
    move.w  d7,d1
    muls.w  d3,d1
    add.l   d1,d0
    bsr     sc_div128
    move.w  d0,d4
    rts

sc_div128:
    tst.l   d0
    bpl.s   .shift
    addi.l  #127,d0
.shift:
    asr.l   #7,d0
    rts

; Each entry contains a visibility bit, a color byte offset, and four local vertex
; indices.
sc_box_faces:
    dc.b 0,16,0,2,3,1, 1,16,4,5,7,6, 2,17,0,4,6,2
    dc.b 3,17,1,3,7,5, 4,18,2,6,7,3
sc_wedge_faces:
    dc.b 0,16,0,2,3,1, 2,17,0,4,6,2, 3,17,1,3,7,5
    dc.b 1,17,4,5,7,6, 4,18,2,6,7,3

sc_model:
    ; D0 selects the tank. The tracks share hull yaw. The gun shares turret yaw.
    movem.l d2-d7/a3-a5,-(sp)
    move.w  d0,d2
    lea     sc_tank(a2),a3
    lea     sc_model_lead(pc),a4
    tst.w   d2
    beq.s   .inputs
    addq.l  #6,a3
    lea     sc_model_other(pc),a4
.inputs:
    lea     sc_turret_yaw(a2),a1
    moveq   #0,d0
    move.b  (a1,d2.w),d0
    movea.w d0,a5
    tst.b   play_suite_stage
    beq.s   .chase_hull
    lea     play_suite_hull,a1
    moveq   #0,d0
    move.b  (a1,d2.w),d0
    bra.s   .orient_hull
.chase_hull:
    lea     sc_phase(a2),a1
    moveq   #0,d0
    move.b  (a1,d2.w),d0
    addi.w  #64,d0
.orient_hull:
    bsr     sc_prism_yaw

    rept 3
    bsr     sc_prism_prepared
    lea     20(a4),a4
    endr
    move.w  a5,d0
    bsr     sc_prism_yaw
    bsr     sc_prism_prepared
    lea     20(a4),a4
    bsr     sc_prism_prepared
    movem.l (sp)+,d2-d7/a3-a5
    rts

; The descriptor contains X, Y, and Z bounds, the upper inset, flags, and three color
; indices.
; Scale the prism at assembly time. Round to the nearest unit, with ties away from
; zero.
; The barrel uses explicit bounds to stay thin and visible.
SC_TANK_WORD macro
    iflt \1
    dc.w -((-(\1)*3+2)/4)
    else
    dc.w ((\1)*3+2)/4
    endif
    endm

SC_TANK_PRISM macro
    SC_TANK_WORD \1
    SC_TANK_WORD \2
    SC_TANK_WORD \3
    SC_TANK_WORD \4
    SC_TANK_WORD \5
    SC_TANK_WORD \6
    SC_TANK_WORD \7
    dc.w \8
    endm

sc_muzzle_lead  equ 19                ; Round 25 times 3/4 to the nearest unit.
sc_muzzle_other equ 15                ; Round 20 times 3/4 to the nearest unit.
sc_barrel_y     equ 8                 ; Round 11 times 3/4 to the nearest unit.

; Track shading uses two repeating checker inks.
SC_TRACK_END_TOP equ 16
SC_TRACK_SIDE    equ 17

sc_model_lead:
    SC_TANK_PRISM -11,-7,0,4,-12,14,0,0
    dc.b SC_TRACK_END_TOP,SC_TRACK_SIDE,SC_TRACK_END_TOP,0
    SC_TANK_PRISM 7,11,0,4,-12,14,0,0
    dc.b SC_TRACK_END_TOP,SC_TRACK_SIDE,SC_TRACK_END_TOP,0
    SC_TANK_PRISM -7,7,2,7,-11,14,4,2
    dc.b 8,9,9,0
    SC_TANK_PRISM -5,5,7,13,-5,7,4,2
    dc.b 9,8,10,0
    dc.w -1,1,sc_barrel_y-1,sc_barrel_y+1,3,sc_muzzle_lead,0,0
    dc.b 9,8,10,0
sc_model_other:
    SC_TANK_PRISM -10,-6,0,4,-10,12,0,0
    dc.b SC_TRACK_END_TOP,SC_TRACK_SIDE,SC_TRACK_END_TOP,0
    SC_TANK_PRISM 6,10,0,4,-10,12,0,0
    dc.b SC_TRACK_END_TOP,SC_TRACK_SIDE,SC_TRACK_END_TOP,0
    SC_TANK_PRISM -6,6,2,7,-9,12,4,2
    dc.b 11,12,12,0
    SC_TANK_PRISM -5,5,7,13,-5,7,4,2
    dc.b 12,11,12,0                   ; Use ochre on the top and front of the turret.
    dc.w -1,1,sc_barrel_y-1,sc_barrel_y+1,3,sc_muzzle_other,0,0
    dc.b 12,11,14,0
SC_HOUSE_X equ -12
SC_HOUSE_HALF_X equ 8
SC_HOUSE_HALF_Z equ 7
; Place the spark beside the road. Its box uses the terrain footprint test.
SC_HOUSE_Z equ 8
sc_spark_box:
    dc.w -1,1,-1,1,-1,1,0,0
    dc.b 15,14,15,0

    macro SC_HOUSE_CORNER
    move.w  #\1,(a0)+
    move.w  \2,(a0)+
    move.w  #\3,(a0)+
    endm

    macro SC_HOUSE_INK
    iflt \1-128
    moveq   #\1,d4
    else
    move.w  #\1,d4
    endif
    endm

    macro SC_HOUSE_WALL
    move.w  d5,d0
    move.w  d5,d1
    move.w  d5,d2
    move.w  d5,d3
    ifne \1
    addq.w  #\1,d0
    endif
    addq.w  #\2,d1
    addq.w  #\3,d2
    addq.w  #\4,d3
    SC_HOUSE_INK \5,\6
    bsr     sc_face
    endm

sc_house:
    ; Draw the house only when its entire foundation lies inside the terrain
    ; footprint.
    ; The footprint is the clipped rectangle with the additional limit X + 2Z <=
    ; front.
    cmpi.w  #SC_HOUSE_X-SC_HOUSE_HALF_X,sc_grid_x(a2)
    bgt     .done
    cmpi.w  #SC_HOUSE_X+SC_HOUSE_HALF_X,sc_grid_x+SC_GRID_X_END(a2)
    blt     .done
    cmpi.w  #SC_HOUSE_Z-SC_HOUSE_HALF_Z,sc_grid_z(a2)
    bgt     .done
    cmpi.w  #SC_HOUSE_Z+SC_HOUSE_HALF_Z,sc_grid_z+SC_GRID_Z_END(a2)
    blt     .done
    cmpi.w  #SC_HOUSE_X+SC_HOUSE_HALF_X+2*(SC_HOUSE_Z+SC_HOUSE_HALF_Z),sc_front_dx(a2)
    blt     .done
    ; The house has zero yaw. Its Q7 sine is zero, and its cosine is 128.
    ; Write the corners in face-table order.
    movem.l d2-d6,-(sp)
    move.w  sc_house_ground,d1
    move.w  d1,d4
    addi.w  #10,d4
    move.w  d1,d6
    addi.w  #17,d6
    move.w  sc_vertex_count(a2),d5
    move.w  d5,d3
    add.w   d3,d3
    add.w   d5,d3
    add.w   d3,d3
    lea     sc_world_vertices(a2),a0
    adda.w  d3,a0

    rept 2
    ; The repeat index selects the rear or front half of the house walls.
    SC_HOUSE_CORNER SC_HOUSE_X-SC_HOUSE_HALF_X,d1,SC_HOUSE_Z-SC_HOUSE_HALF_Z+(2*SC_HOUSE_HALF_Z)*REPTN
    SC_HOUSE_CORNER SC_HOUSE_X+SC_HOUSE_HALF_X,d1,SC_HOUSE_Z-SC_HOUSE_HALF_Z+(2*SC_HOUSE_HALF_Z)*REPTN
    SC_HOUSE_CORNER SC_HOUSE_X-SC_HOUSE_HALF_X,d4,SC_HOUSE_Z-SC_HOUSE_HALF_Z+(2*SC_HOUSE_HALF_Z)*REPTN
    SC_HOUSE_CORNER SC_HOUSE_X+SC_HOUSE_HALF_X,d4,SC_HOUSE_Z-SC_HOUSE_HALF_Z+(2*SC_HOUSE_HALF_Z)*REPTN
    endr
    SC_HOUSE_CORNER SC_HOUSE_X,d6,SC_HOUSE_Z-SC_HOUSE_HALF_Z
    SC_HOUSE_CORNER SC_HOUSE_X,d6,SC_HOUSE_Z+SC_HOUSE_HALF_Z
    addi.w  #10,sc_vertex_count(a2)

    move.w  sc_camz(a2),d6
    subi.w  #SC_HOUSE_Z,d6
    cmpi.w  #-SC_HOUSE_HALF_Z,d6
    bge.s   .not_back
    SC_HOUSE_WALL 0,2,3,1,2,4*(SC_HOUSE_Z-SC_HOUSE_HALF_Z)
.not_back:
    cmpi.w  #SC_HOUSE_HALF_Z,d6
    ble.s   .not_front
    SC_HOUSE_WALL 4,5,7,6,2,4*(SC_HOUSE_Z+SC_HOUSE_HALF_Z)
.not_front:
    move.w  sc_camx(a2),d6
    subi.w  #SC_HOUSE_X,d6
    cmpi.w  #-SC_HOUSE_HALF_X,d6
    bge.s   .not_left
    SC_HOUSE_WALL 0,4,6,2,15,4*SC_HOUSE_Z
.not_left:
    cmpi.w  #SC_HOUSE_HALF_X,d6
    ble.s   .not_right
    SC_HOUSE_WALL 1,3,7,5,15,4*SC_HOUSE_Z
.not_right:
    move.w  d5,d6
    addq.w  #8,d6

    move.w  d5,d0
    addq.w  #2,d0
    move.w  d5,d1
    addq.w  #6,d1
    move.w  d6,d2
    addq.w  #1,d2
    move.w  d6,d3
    SC_HOUSE_INK 12,4*SC_HOUSE_Z
    bsr     sc_face
    move.w  d6,d0
    move.w  d6,d1
    addq.w  #1,d1
    move.w  d5,d2
    addq.w  #7,d2
    move.w  d5,d3
    addq.w  #3,d3
    SC_HOUSE_INK 14,4*SC_HOUSE_Z
    bsr     sc_face
    cmpi.w  #SC_HOUSE_Z,sc_camz(a2)
    bge.s   .opposite
    move.w  d5,d0
    addq.w  #2,d0
    move.w  d6,d1
    move.w  d5,d2
    addq.w  #3,d2
    SC_HOUSE_INK $102,4*(SC_HOUSE_Z-SC_HOUSE_HALF_Z)
    bra.s   .gable
.opposite:
    move.w  d5,d0
    addq.w  #6,d0
    move.w  d5,d1
    addq.w  #7,d1
    move.w  d6,d2
    addq.w  #1,d2
    SC_HOUSE_INK $10f,4*(SC_HOUSE_Z+SC_HOUSE_HALF_Z)
.gable:
    move.w  d2,d3
    bsr     sc_face
    movem.l (sp)+,d2-d6
.done:
    rts

; D0.W and D1.W contain ground X and Z. D2.W is canopy height. D3.W is the sampled
; base height.
; A2 contains the scene address.
sc_tree:
    ; Require the complete ground contact to lie inside the footprint.
    ; The screen clip still applies to the canopy and trunk after projection.
    subq.w  #3,d0
    cmp.w   sc_grid_x(a2),d0
    blt     .done
    addq.w  #6,d0
    cmp.w   sc_grid_x+SC_GRID_X_END(a2),d0
    bgt     .done
    cmp.w   sc_grid_z(a2),d1
    blt     .done
    cmp.w   sc_grid_z+SC_GRID_Z_END(a2),d1
    bgt     .done
    movea.w d0,a0
    add.w   d1,d0
    add.w   d1,d0
    cmp.w   sc_front_dx(a2),d0
    bgt     .done
    move.w  a0,d0
    subq.w  #3,d0
    ; Reserve four vertex records and two triangle records before writing them.
    movem.l d3-d5,-(sp)
    move.w  d3,d5
    move.w  d2,d3
    move.w  d1,d2
    move.w  d5,d1
    move.w  sc_vertex_count(a2),d4
    addq.w  #4,sc_vertex_count(a2)
    move.w  d4,d5
    add.w   d5,d5
    add.w   d4,d5
    add.w   d5,d5
    lea     sc_world_vertices(a2),a0
    adda.w  d5,a0
    addq.w  #3,d0
    move.w  d0,(a0)+
    addq.w  #4,d1
    move.w  d1,(a0)+
    move.w  d2,(a0)+
    subq.w  #3,d0
    move.w  d0,(a0)+
    subq.w  #4,d1
    add.w   d1,d3
    move.w  d3,(a0)+
    move.w  d2,(a0)+
    move.w  d0,(a0)+
    addq.w  #1,d1
    move.w  d1,(a0)+
    move.w  d2,(a0)+
    subq.w  #3,d0
    move.w  d0,(a0)+
    addq.w  #4,d1
    move.w  d1,(a0)+
    move.w  d2,(a0)

    move.w  sc_face_count(a2),d5
    addq.w  #2,sc_face_count(a2)
    move.w  d5,d3
    add.w   d5,d5
    add.w   d3,d5
    add.w   d5,d5
    add.w   d5,d5
    lea     sc_faces(a2),a0
    adda.w  d5,a0
    move.w  d4,d0
    move.w  d0,(a0)+
    addq.w  #1,d0
    move.w  d0,(a0)+
    addq.w  #1,d0
    move.w  d0,(a0)+
    move.w  d0,(a0)+
    move.w  #$0306,(a0)+              ; Set the canopy triangle to ink 6.
    addq.l  #2,a0                     ; Leave the depth slot for the face cull.
    move.w  d0,(a0)+
    subq.w  #1,d0
    move.w  d0,(a0)+
    addq.w  #2,d0
    move.w  d0,(a0)+
    move.w  d0,(a0)+
    move.w  #$0302,(a0)               ; Set the trunk triangle to ink 2.
    lea     sc_needed(a2),a0
    adda.w  d4,a0
    moveq   #1,d0
    move.b  d0,(a0)+
    move.b  d0,(a0)+
    move.b  d0,(a0)+
    move.b  d0,(a0)
    movem.l (sp)+,d3-d5
.done:
    rts

; The map has four fixed trees. Their placement limits the view to four trees.
; Each entry gives X, Z, and canopy height.
sc_grove:
    dc.w -16,-16,24
    dc.w -19,-31,18
    dc.w 25,2,23
    dc.w 44,-18,24
sc_grove_end:
SC_GROVE_COUNT equ (sc_grove_end-sc_grove)/6

; Sample the ground at each fixed tree position. The height does not depend on the
; camera.
; The terrain footprint test still runs each frame.
sc_seed_prop_heights:
    moveq   #SC_HOUSE_X,d0
    moveq   #SC_HOUSE_Z,d2
    bsr.w   sc_ground_height
    move.w  d1,sc_house_ground
    lea     sc_grove(pc),a1
    lea     sc_grove_ground,a3
    moveq   #SC_GROVE_COUNT-1,d3
.next:
    move.w  (a1)+,d0
    move.w  (a1)+,d2
    bsr.w   sc_ground_height
    move.w  d1,(a3)+
    addq.l  #2,a1
    dbra    d3,.next
    rts

sc_scenery_grove:
    move.l  a5,-(sp)
    lea     sc_grove(pc),a4
    lea     sc_grove_ground,a5
    moveq   #SC_GROVE_COUNT-1,d4
.next:
    movem.w (a4),d0-d2
    move.w  (a5)+,d3
    bsr     sc_tree
    addq.l  #6,a4
    dbra    d4,.next
    movea.l (sp)+,a5
    rts

; Build terrain, tanks, scenery, and the tracer for the current camera position.
sc_make_scene:
    movem.l d2-d4/a3-a4,-(sp)
    ; The terrain pass assigns all grid flags. Clear only the model flags here.
    lea     sc_needed+SC_GRID_POINTS(a2),a0
    moveq   #0,d0
    move.w  #(SC_MAX_VERTICES-SC_GRID_POINTS)/4-1,d1
.clear:
    move.l  d0,(a0)+
    dbra    d1,.clear
    ifne SC_MAX_VERTICES&3
    rept SC_MAX_VERTICES&3
    move.b d0,(a0)+
    endr
    endif
    move.w  sc_tank(a2),d0
    sub.w   sc_camera_dx(a2),d0
    move.w  d0,sc_camx(a2)
    move.w  sc_tank+4(a2),d0
    sub.w   sc_camera_dz(a2),d0
    move.w  d0,sc_camz(a2)
    move.w  sc_tank+2(a2),d0
    addi.w  #SC_EYE_HEIGHT,d0
    move.w  d0,sc_camy(a2)
    bsr     sc_terrain
    move.w  sc_face_count(a2),sc_terrain_faces(a2)
    bsr     sc_house
    moveq   #0,d0
    bsr     sc_model
    moveq   #1,d0
    bsr     sc_model
    move.b  sc_face_count+1(a2),sc_tree_first_face(a2)
    bsr     sc_scenery_grove
    move.b  sc_face_count+1(a2),sc_tree_end_face(a2)

    bsr.w   sc_draw_tracer
    movem.l (sp)+,d2-d4/a3-a4
    rts

; ------------------------------------------------------------------------
; Turret aim and tracer motion
; ------------------------------------------------------------------------

; The simulation sets turret aim. The raster and FPS timer do not affect it.
SC_TURRET_STEP  equ 4                 ; Limit turret yaw change to four units per tick.
SC_TRACER_TICKS equ 12                ; Expire the tracer before the next launch.
SC_LEAD_FIRE    equ 8                 ; Stagger launches so one tracer record is enough.
SC_OTHER_FIRE   equ 24

; Sample the ground at both tank positions. Then update turret aim and the active
; tracer.
sc_ground_and_aim:
    move.w  sc_tank(a2),d0
    move.w  sc_tank+4(a2),d2
    bsr.w   sc_ground_height
    move.w  d1,sc_tank+2(a2)
    move.w  sc_tank+6(a2),d0
    move.w  sc_tank+10(a2),d2
    bsr.w   sc_ground_height
    move.w  d1,sc_tank+8(a2)
    movem.l d4-d7,-(sp)
    move.w  sc_tank+6(a2),d0
    sub.w   sc_tank(a2),d0
    move.w  sc_tank+10(a2),d1
    sub.w   sc_tank+4(a2),d1
    bsr.s   sc_target_yaw
    move.b  d0,d6
    addi.b  #128,d0                   ; Use the reverse sight line for the second turret.
    move.b  d0,d7
    tst.l   sc_tick(a2)
    beq.s   .reset
    lea     sc_turret_yaw(a2),a1
    move.b  d6,d0
    bsr.w   sc_slew_yaw
    move.b  d7,d0
    bsr.w   sc_slew_yaw

    tst.w   sc_tracer_life(a2)
    beq.s   .fire
    subq.w  #1,sc_tracer_life(a2)
    beq.s   .fire
    move.w  sc_tracer_dx(a2),d0
    add.w   d0,sc_tracer_x(a2)
    move.w  sc_tracer_dz(a2),d0
    add.w   d0,sc_tracer_z(a2)
.fire:
    move.w  sc_tick+2(a2),d0
    andi.w  #31,d0
    cmpi.w  #SC_LEAD_FIRE,d0
    beq.s   .lead
    cmpi.w  #SC_OTHER_FIRE,d0
    bne.s   .done
    moveq   #1,d0
    bsr.w   sc_launch_tracer
    bra.s   .done
.lead:
    moveq   #0,d0
    bsr.w   sc_launch_tracer
    bra.s   .done
.reset:
    lea     sc_turret_yaw(a2),a1
    moveq   #sc_turret_bytes/2-1,d0
.clear:
    clr.w   (a1)+
    dbra    d0,.clear
    move.b  d6,sc_turret_yaw(a2)
    move.b  d7,sc_turret_yaw+1(a2)
.done:
    movem.l (sp)+,d4-d7
    rts

; D0.W contains the X delta and D1.W contains the Z delta. Return yaw in D0.B, with
; zero along positive Z.
; Use the first-octant ratio to index the table. Apply angle symmetry to cover the
; full turn.
sc_target_yaw:
    move.w  d0,d2
    move.w  d1,d3
    tst.w   d2
    bpl.s   .positive_x
    neg.w   d0
.positive_x:
    tst.w   d3
    bpl.s   .positive_z
    neg.w   d1
.positive_z:
    lea     sc_yaw_atan(pc),a0
    moveq   #0,d4
    cmp.w   d1,d0
    bls.s   .ratio
    exg     d0,d1
    moveq   #-1,d4
.ratio:
    tst.w   d1
    beq.s   .done
    andi.l  #$ffff,d0
    lsl.w   #6,d0
    divu.w  d1,d0
    move.b  (a0,d0.w),d0
    tst.w   d4
    beq.s   .quadrant_z
    neg.b   d0
    addi.b  #64,d0
.quadrant_z:
    tst.w   d3
    bpl.s   .quadrant_x
    neg.b   d0
    addi.b  #128,d0
.quadrant_x:
    tst.w   d2
    bpl.s   .done
    neg.b   d0
.done:
    rts

; D0.B contains the target yaw and A1 points to the current yaw. Signed byte
; subtraction selects the shorter turn.
sc_slew_yaw:
    sub.b   (a1),d0
    cmpi.b  #SC_TURRET_STEP,d0
    bgt.s   .clockwise
    cmpi.b  #-SC_TURRET_STEP,d0
    bge.s   .apply
    moveq   #-SC_TURRET_STEP,d0
    bra.s   .apply
.clockwise:
    moveq   #SC_TURRET_STEP,d0
.apply:
    add.b   d0,(a1)+
    rts

; D0.W selects the source tank. Start the tracer at the center of the barrel end.
; Match the prism rounding at launch. Use the Q7 heading for subsequent movement.
sc_launch_tracer:
    move.w  d0,sc_tracer_tank(a2)
    lea     sc_turret_yaw(a2),a0
    moveq   #0,d5
    move.b  (a0,d0.w),d5
    move.w  d5,sc_tracer_yaw(a2)
    lea     sc_tank(a2),a1
    moveq   #sc_muzzle_lead,d4
    tst.w   d0
    beq.s   .muzzle
    moveq   #sc_muzzle_other,d4
    addq.l  #6,a1
.muzzle:
    move.w  2(a1),d0
    addi.w  #sc_barrel_y,d0
    move.w  d0,sc_tracer_y(a2)
    lea     sc_sin_q7(a2),a0
    add.w   d5,d5
    move.w  (a0,d5.w),d6
    addi.w  #128,d5
    andi.w  #510,d5
    move.w  (a0,d5.w),d7
    move.w  d6,d0
    muls.w  d4,d0
    bsr.w   sc_div128
    add.w   (a1),d0
    lsl.w   #7,d0
    move.w  d0,sc_tracer_x(a2)
    move.w  d7,d0
    muls.w  d4,d0
    bsr.w   sc_div128
    add.w   4(a1),d0
    lsl.w   #7,d0
    move.w  d0,sc_tracer_z(a2)
    SC_TIMES3_W d6,d0
    SC_TIMES3_W d7,d0
    add.w   d6,d6
    add.w   d7,d7
    move.w  d6,sc_tracer_dx(a2)
    move.w  d7,sc_tracer_dz(a2)
    move.w  #SC_TRACER_TICKS,sc_tracer_life(a2)
    rts

; Draw the tracer only inside the terrain footprint. This test does not change the
; simulation.
sc_draw_tracer:
    tst.w   sc_tracer_life(a2)
    beq.s   .done
    move.w  sc_tracer_x(a2),d1
    asr.w   #7,d1
    cmp.w   sc_axis_x(a2),d1
    blt.s   .done
    cmp.w   sc_axis_x+SC_PROP_X_END(a2),d1
    bgt.s   .done
    move.w  sc_tracer_z(a2),d0
    asr.w   #7,d0
    cmp.w   sc_axis_z(a2),d0
    blt.s   .done
    cmp.w   sc_axis_z+SC_PROP_Z_END(a2),d0
    bgt.s   .done
    move.w  d0,-(sp)
    move.w  sc_tracer_y(a2),-(sp)
    move.w  d1,-(sp)
    movea.l sp,a3
    lea     sc_spark_box(pc),a4
    move.w  sc_tracer_yaw(a2),d0
    bsr.w   sc_prism
    addq.l  #6,sp
.done:
    rts

; round(256 * atan(i / 64) / (2*pi)), i=0..64.
sc_yaw_atan:
    dc.b 0,1,1,2,3,3,4,4,5,6,6,7,8,8,9,9
    dc.b 10,11,11,12,12,13,13,14,15,15,16,16,17,17,18,18
    dc.b 19,19,20,20,21,21,22,22,23,23,24,24,25,25,25,26
    dc.b 26,27,27,27,28,28,29,29,29,30,30,30,31,31,31,32
    dc.b 32
    even

    xdef tb_scene_prepare_draw,tb_scene_emit_draw

; ------------------------------------------------------------------------
; Model transforms and terrain projection
; ------------------------------------------------------------------------

    ; Test near-plane exclusion on a sign-extended Q4 camera depth.
    macro SC_COARSE_NEAR
    moveq   #0,\2
    cmpi.l  #SC_NEAR,\1
    bge.s   .sides\@
    moveq   #1,\2
.sides\@:
    endm

    macro SC_COARSE_LR
    ; Use twice the camera depth for each side limit.
    add.l   \1,\1
    cmp.l   \1,\2
    ble.s   .not_right\@
    ori.b   #4,\3
.not_right\@:
    neg.l   \1
    cmp.l   \1,\2
    bge.s   .not_left\@
    ori.b   #2,\3
.not_left\@:
    endm

    macro SC_COARSE_TB
    ; Scale Y by four and compare it with the limits at five times the camera depth.
    lsl.l   #2,\2
    cmp.l   \1,\2
    ble.s   .not_above\@
    ori.b   #16,\3
.not_above\@:
    neg.l   \1
    cmp.l   \1,\2
    bge.s   .done\@
    ori.b   #8,\3
.done\@:
    endm

; D4.W and D1.W contain projected X and Y. A4 points to the outcode byte.
; Set bit 5 when the point requires the general viewport path.
    macro SC_TAG_VIEWPORT
    subi.w  #9,d4                     ; Allow for endpoint rounding at the left edge.
    cmpi.w  #5103,d4
    bhi.s   .unpacked\@
    move.w  d1,d4
    subi.w  #889,d4
    cmpi.w  #2319,d4
    bls.s   .inside\@
.unpacked\@:
    bset    #5,(a4)
.inside\@:
    endm

; Use the reciprocal table for eligible model points. A0 and A1 hold the fixed screen
; origins.
    macro SC_ALIGNED_MODEL_POINT
    tst.w   d1
    bgt.s   \2                        ; Use the general projector for points above the eye.
    lsr.w   #3,d2
    cmpi.w  #1022,d2
    bhi.s   \1
    move.w  sc_reciprocal(a2,d2.w),d4
    move.w  d4,d2
    asr.w   #4,d0
    asr.w   #4,d1
    neg.w   d1                        ; Use positive height below the eye.
    ; Use the small integer as the MULS source to reduce Booth transitions.
    muls.w  d0,d4
    muls.w  d1,d2
    move.l  d4,d0
    bpl.s   .positive\@
    addi.l  #255,d0
.positive\@:
    asr.l   #8,d0
    ; Both factors of the vertical product are nonnegative.
    asr.l   #8,d2
    ; Add the fixed screen origins.
    add.l   a0,d0
    move.l  d2,d1
    add.l   a1,d1
    endm

; A2 contains the scene address. Transform marked model vertices and record their
; frustum outcodes.
; The face cull marks vertices again for projection. Terrain stays in the separate
; axis and height arrays.
sc_transform_scene:
    movem.l d2-d7/a3-a6,-(sp)
    lea     sc_world_vertices(a2),a3
    lea     sc_camera_vertices(a2),a4
    lea     sc_needed(a2),a5
    move.w  sc_vertex_count(a2),d6
    ; Skip the terrain prefix in each model array.
    lea     6*SC_GRID_POINTS(a3),a3
    lea     6*SC_GRID_POINTS(a4),a4
    move.w  sc_camx(a2),d4
    move.w  sc_camy(a2),d5
    lsl.w   #4,d5
    move.w  sc_camz(a2),d7
    lea     SC_GRID_POINTS(a5),a5
    subi.w  #SC_GRID_POINTS+1,d6
    bmi.s   .models_done
    ; D4.W and D7.W contain camera X and Z. D5.W contains camera Y in Q4.
    lea     sc_outcode+SC_GRID_POINTS(a2),a0
.model_vertex:
    tst.b   (a5)+
    beq.s   .unneeded_model
    move.w  d4,d0
    sub.w   (a3),d0
    lsl.w   #4,d0
    move.w  2(a3),d1
    lsl.w   #4,d1
    sub.w   d5,d1
    move.w  d7,d2
    sub.w   4(a3),d2
    lsl.w   #4,d2
    movem.w d0-d2,(a4)
    ; Use the packed Q4 coordinates for the outcode. Remove the input mark before the
    ; face cull restores it.
    clr.b   -1(a5)
    ext.l   d2
    movea.l d2,a1
    SC_COARSE_NEAR d2,d3
    ext.l   d0
    SC_COARSE_LR d2,d0,d3
    neg.l   d2
    add.l   d2,d2
    add.l   a1,d2
    ext.l   d1
    SC_COARSE_TB d2,d1,d3
    move.b  d3,(a0)+
.advance_model:
    addq.l  #6,a3
    addq.l  #6,a4
    dbra    d6,.model_vertex
    bra.s   .models_done
.unneeded_model:
    move.b  #31,(a0)+
    bra.s   .advance_model
.models_done:
    movem.l (sp)+,d2-d7/a3-a6
    rts

    ; D4.W contains terrain height, D3.W contains camera Y, and D0.W/D6.L hold the row
    ; coefficients.
    ; Return the exact screen Y in D1.L. Set D5.W to the height so the next point can
    ; test for reuse.
    macro SC_TYPED_ELEVATION
    move.w  d4,d5
    move.w  d3,d1
    sub.w   d4,d1
    lsl.w   #6,d1
    mulu.w  d0,d1
    add.l   d6,d1
    swap    d1
    ext.l   d1
    endm

    ; Project the marked terrain points. Argument 0 skips viewport tags for a row
    ; inside the raster.
    macro SC_ELEVATION_POINTS
    moveq   #SC_GRID_WIDTH-1,d7
.point\@:
    tst.b   (a5)+
    ifne \1
    beq.s   .skip_elevation_suffix
    else
    beq.s   .skip\@
    endif
    ; The row recurrence supplies exact X. Terrain depth is at least 96, so near-plane
    ; clipping is unnecessary.
    ; Rows that need a viewport test use D4.W for the X and Y tests.
    ifne \1
    moveq   #0,d4
    endif
    move.b  (a3),d4
    cmp.w   d5,d4
    bne.s   .height\@
    move.l  a1,d1
    bra.s   .store\@
.height\@:
    SC_TYPED_ELEVATION
    movea.l d1,a1
.store\@:
    move.l  d1,4(a6)
    ifne \1
    move.w  2(a6),d4
    SC_TAG_VIEWPORT
    endif
.skip\@:
    ifne \1
    addq.l  #1,a4
    endif
    addq.l  #1,a3
    addq.l  #8,a6
    dbra    d7,.point\@
    endm

    ; A mark in the final slot proves that the entire prefix fills the row.
    ; This loop handles full far rows and does not write viewport tags.
    macro SC_ELEVATION_FULL_POINT
    move.b  \1(a3),d4
    cmp.w   d5,d4
    beq.s   .store\@                  ; D1.L still holds Y for this height.
    SC_TYPED_ELEVATION
.store\@:
    move.l  d1,4+8*\1(a6)
    endm

; Prepare the scene and order its faces. At entry, 4(SP) holds the scene address and
; 8(SP) holds the projection mode.
; Start the last plane clear after scene construction. Transform and sort while it
; runs.
tb_scene_prepare_draw:
    movem.l d2-d7/a2-a6,-(sp)
    movea.l 48(sp),a2
    move.l  52(sp),sc_draw_mode(a2)
    bsr     sc_make_scene
    ; Scene construction overlaps the preceding plane clear.
    bsr.w   play_clear_final
    move.l  sc_draw_mode(a2),d3
    bsr     sc_transform_scene
    ; The minimum terrain depth is 96. With heights [0, 21] and eye heights [44, 65],
    ; the coarse frustum cannot reject terrain.
    ; Set the viewport outcode after projection.
    lea     sc_outcode(a2),a4
    moveq   #SC_GRID_POINTS/4-1,d7
.strip_outcode:
    clr.l   (a4)+
    dbra    d7,.strip_outcode

    lea     sc_strip_row_counts+SC_GRID_DEPTH-1(a2),a3
    lea     sc_order(a2),a6
    moveq   #0,d7
    moveq   #SC_GRID_DEPTH-2,d0
    ; Save each admitted row end for the painter merge.
    lea     -SC_TERRAIN_ROW_END_BYTES(sp),sp
    movea.l sp,a1
.strip_row:
    ; Each unrolled slot occupies four bytes. Jump back by four bytes for each
    ; admitted cell.
    ; D2.W starts with the first face ID of the physical row.
    moveq   #0,d1
    move.b  -(a3),d1
    neg.w   d1
    lsl.w   #2,d1
    move.w  d7,d2
    jmp     (.strip_ids_end,pc,d1.w)
.strip_ids_first:
    rept SC_GRID_WIDTH-1
    move.w  d2,(a6)+
    addq.w  #1,d2
    endr
.strip_ids_end:
    ifne .strip_ids_end-.strip_ids_first-4*(SC_GRID_WIDTH-1)
    fail "Recheck counted terrain row dispatch slot width"
    endif
    addi.w  #SC_GRID_WIDTH-1,d7
.next_strip:
    move.l  a6,(a1)+
    dbra    d0,.strip_row
    move.l  a6,d0
    sub.l   a2,d0
    subi.w  #sc_order,d0
    lsr.w   #1,d0
    move.w  d0,sc_draw_count(a2)
    move.l  a6,-(sp)                  ; Save the end of the admitted terrain IDs.
    move.w  sc_grid_z(a2),d6
    andi.w  #-SC_TILE_SIZE,d6
    ; Reuse the camera Z term for both face sort keys.
    lea     sc_camera_vertices+4(a2),a1
    lea     sc_sort_work(a2),a0
    move.w  sc_camz(a2),d4
    sub.w   d6,d4
    move.w  d4,d6
    ; Scale four copies of camera Z minus grid origin to Q4.
    lsl.w   #6,d6
    lea     sc_faces+12*SC_CLASS_TERRAIN_FACES(a2),a3
    lea     sc_outcode(a2),a4
    lea     sc_needed(a2),a5
.cull_face:
    tst.b   8(a3)                     ; Reject a padding slot.
    beq.w   .skip_face
    movem.w (a3),d0-d3
    move.b  (a4,d0.w),d4
    and.b   (a4,d1.w),d4
    and.b   (a4,d2.w),d4
    and.b   (a4,d3.w),d4
    bne.w   .skip_face
    move.b  #1,(a5,d0.w)
    move.b  #1,(a5,d1.w)
    move.b  #1,(a5,d2.w)
    move.b  #1,(a5,d3.w)
    ; The face cull marks only model vertices that belong to a surviving face.
    move.w  d0,d4
    add.w   d0,d0
    add.w   d4,d0
    add.w   d0,d0
    move.w  d1,d4
    add.w   d1,d1
    add.w   d4,d1
    add.w   d1,d1
    move.w  d2,d4
    add.w   d2,d2
    add.w   d4,d2
    add.w   d2,d2
    move.w  d3,d4
    add.w   d3,d3
    add.w   d4,d3
    add.w   d3,d3
    ; Sum four camera depths in Q4. The scene bounds keep this sum in a signed word.
    ; Subtract that sum from the common camera term to get the distance from the first
    ; grid band.
    move.w  (a1,d0.w),d0
    add.w   (a1,d1.w),d0
    add.w   (a1,d2.w),d0
    add.w   (a1,d3.w),d0
    move.w  d6,d5
    sub.w   d0,d5                     ; Calculate four Q4 distances from the grid origin.
    bpl.s   .scale_band_q4
    moveq   #0,d5
.scale_band_q4:
    lsr.w   #8,d5
    lsr.w   #SC_TILE_SHIFT-2,d5
    moveq   #SC_LAST_ROW,d4
    sub.w   d5,d4
    bpl.s   .band_q4
    moveq   #0,d4
.band_q4:
    move.w  d7,d5
    add.w   d5,d5
    move.w  d4,(a0,d5.w)
    ; All four depths are multiples of 16. Divide by four without a rounding
    ; correction.
    asr.w   #2,d0
    move.w  d0,10(a3)
    move.w  d7,(a6)+
    addq.w  #1,sc_draw_count(a2)
.skip_face:
    lea     12(a3),a3
    addq.w  #1,d7
    cmp.w   sc_face_count(a2),d7
    blo     .cull_face

    bsr.w   sc_project_grid_x
    ; Keep camera Y in D3.W until the model pass uses D3 for the projection mode.
    move.w  sc_camy(a2),d3
    lea     sc_strip_heights(a2),a3
    pea     sc_grid_z(a2)
    lea     sc_projected(a2),a6
    lea     sc_elevation_magic-8*SC_FOOT_NEAR,a0
    moveq   #SC_GRID_DEPTH-1,d2
.elevation_row:
    ; All points in a row share camera depth. Even padding has a valid depth in [96,
    ; 304].
    ; Load the two row coefficients once and reuse them for all 12 slots.
    movea.l (sp),a1
    move.w  sc_camz(a2),d4
    sub.w   (a1)+,d4
    move.l  a1,(sp)
    lsl.w   #3,d4
    moveq   #-1,d5                    ; Set a height sentinel for the new row.
    move.w  (a0,d4.w),d0
    move.l  4(a0,d4.w),d6
    ifne (SC_CX-2560)|(SC_CAMERA_ORIGIN_Y-1216)|(SC_FOCUS_Q4-4096)|(SC_EYE_HEIGHT-44)|(SC_FOOT_WEST-56)|(SC_FOOT_EAST-100)
    fail "Recheck far terrain row tag bounds after camera or footprint changes"
    endif
    ; For depth 161 or greater, screen X stays in [16, 4010] Q4 and screen Y stays in
    ; [1216, 2870] Q4.
    ; Neither margin test can set bit 5 in this range.
    cmpi.w  #8*161,d4
    bge.s   .far_elevation
    SC_ELEVATION_POINTS 1
.near_elevation_done:
    bra.w   .next_elevation
.skip_elevation_suffix:
    ; A5 points after the first zero mark. The continuous prefix proves all following
    ; slots are inactive.
    ; D7.W contains the number of slots after the first zero.
    adda.w  d7,a5
    addq.w  #1,d7
    adda.w  d7,a3
    adda.w  d7,a4
    lsl.w   #3,d7
    adda.w  d7,a6
    bra.s   .near_elevation_done
.far_elevation:
    ; Initialize the upper byte. No viewport test changes this word.
    moveq   #0,d4
    ifne SC_GRID_WIDTH-12
    fail "Full far path requires four groups of three lattice points"
    endif
    tst.b   SC_GRID_WIDTH-1(a5)
    beq.w   .partial_far_elevation
    moveq   #SC_GRID_WIDTH/3-1,d7
.full_far_group:
    SC_ELEVATION_FULL_POINT 0
    SC_ELEVATION_FULL_POINT 1
    SC_ELEVATION_FULL_POINT 2
    addq.l  #3,a3
    lea     24(a6),a6
    dbra    d7,.full_far_group
    lea     SC_GRID_WIDTH(a5),a5
    bra.s   .far_elevation_done
.partial_far_elevation:
    SC_ELEVATION_POINTS 0
.far_elevation_done:
    lea     SC_GRID_WIDTH(a4),a4
.next_elevation:
    dbra    d2,.elevation_row

    addq.l  #4,sp
    lea     sc_camera_vertices+6*SC_GRID_POINTS(a2),a3
    move.w  sc_vertex_count(a2),d7
    subi.w  #SC_GRID_POINTS+1,d7
    bmi.w   .points_done
    ; Use reciprocal projection for model points within its limits. Use the general
    ; projector for the other points.
    move.l  sc_draw_mode(a2),d3
    movea.w #SC_CX,a0
    movea.w #SC_CAMERA_ORIGIN_Y,a1
    ; A5, A4, A3, and A6 point to vertex marks, outcodes, camera coordinates, and
    ; screen coordinates.
.typed_next:
    tst.b   (a5)+
    beq.s   .typed_skip
    movem.w (a3),d0-d2
    SC_ALIGNED_MODEL_POINT .typed_restore_depth,.typed_ordinary
.typed_store:
    move.l  d0,(a6)
    move.l  d1,4(a6)
    move.w  d0,d4
    SC_TAG_VIEWPORT
.typed_skip:
    addq.l  #1,a4
    addq.l  #6,a3
    addq.l  #8,a6
    dbra    d7,.typed_next
    bra.s   .points_done
.typed_restore_depth:
    lsl.w   #3,d2                     ; Restore Q4 depth before the general call.
.typed_ordinary:
    bsr.w   sc_project
    movea.w #SC_CAMERA_ORIGIN_Y,a1
    bra.s   .typed_store
.points_done:

    movea.l (sp)+,a5
    bsr     sc_order_faces
    lea     SC_TERRAIN_ROW_END_BYTES(sp),sp
    movem.l (sp)+,d2-d7/a2-a6
    rts

; ------------------------------------------------------------------------
; Depth-ordered model and terrain submissions
; ------------------------------------------------------------------------

; Camera yaw is fixed. Greater world Z puts a row nearer the camera.
; Within a row, greater world X puts a tile farther from the camera.
SC_LAST_ROW equ SC_GRID_DEPTH-2
SC_BUCKET_STRIDE equ 2*(SC_MAX_FACES-SC_CLASS_TERRAIN_FACES)
SC_DEPTH_SHADOW_BYTES equ SC_BUCKET_STRIDE
    ifne SC_TILE_SIZE-16
    fail "Revise the painter bands and regenerate the terrain X table."
    endif
SC_BUCKET_CURSOR_BYTES equ 4*(SC_LAST_ROW+1)
SC_BUCKET_BYTES equ (SC_LAST_ROW+1)*SC_BUCKET_STRIDE+SC_BUCKET_CURSOR_BYTES

; A2 points to the scene. A5 points past the admitted terrain face IDs.
; The caller puts the row-end pointers immediately above the return address.
; This routine writes the final order to sc_sort_work.
; This routine can change D0-D7 and A0-A6. The caller saves A2.
sc_order_faces:
    move.w  sc_draw_count(a2),d6
    beq.w   .empty
    lea     sc_order(a2),a3
    add.w   d6,d6
    lea     (a3,d6.w),a6
    ; Put each model face ID in its depth band.
    ; Within a band, sort by depth and keep source order for equal depths.
    lea     -SC_DEPTH_SHADOW_BYTES(sp),sp
    lea     -2*SC_CLASS_TERRAIN_FACES(sp),a1
    lea     -SC_BUCKET_BYTES(sp),sp
    lea     SC_BUCKET_CURSOR_BYTES(sp),a0
    movea.l sp,a3
    moveq   #SC_LAST_ROW,d2
.init:
    move.l  a0,(a3)+
    lea     SC_BUCKET_STRIDE(a0),a0
    dbra    d2,.init
    ; Save the end of the admitted terrain face IDs.
    move.l  a5,d7
    lea     sc_sort_work(a2),a5
    lea     sc_faces+10(a2),a3
    movea.l d7,a0
    ; The base is the camera depth relative to the aligned grid origin.
    ; Each interior band covers 16 world units.
    ; In that band, increasing low-byte (base - depth) gives descending depth.
    move.w  sc_camz(a2),d6
    move.w  sc_grid_z(a2),d4
    andi.w  #-SC_TILE_SIZE,d4
    sub.w   d4,d6
    lsl.w   #4,d6
.scatter:
    cmpa.l  a6,a0
    beq.s   .sort_bands
    move.w  (a0)+,d5
    move.w  d5,d0
    add.w   d0,d0
    move.w  d0,d2
    add.w   d2,d2
    add.w   d0,d2
    ; D2 is now the byte offset of the face record.
    add.w   d2,d2
    moveq   #SC_LAST_ROW,d1
    sub.w   (a5,d0.w),d1
    add.w   d1,d1
    add.w   d1,d1
    movea.l (sp,d1.w),a4
    move.w  d1,d4
    subq.w  #4,d4
    cmpi.w  #4*(SC_LAST_ROW-1),d4
    bhs.s   .full_depth
    move.w  d6,d4
    sub.w   (a3,d2.w),d4
    move.b  d4,(a4)+
    move.b  d5,(a4)+
.commit:
    move.l  a4,(sp,d1.w)
    bra.s   .scatter
; Bands at the limits can span more than 16 units.
; Keep their full signed depths in the stack array.
.full_depth:
    move.w  (a3,d2.w),(a1,d0.w)
    move.w  d5,(a4)+
    bra.s   .commit
.sort_bands:
    movea.l sp,a6
    lea     SC_BUCKET_CURSOR_BYTES(sp),a0
    moveq   #SC_LAST_ROW,d3
.band:
    move.l  (a6)+,d2
    lea     2(a0),a3
    cmpa.l  d2,a3
    bhs.s   .advance_band
    cmpi.w  #SC_LAST_ROW,d3
    beq.s   .item
    tst.w   d3
    beq.s   .item
    ; This interior bucket contains at least two faces.
    ; Thus the preceding bucket cannot contain all the model faces.
    ; Use its last word for a zero sentinel. This removes the bounds test.
    clr.w   -2(a0)
.packed_item:
    move.w  (a3),d5
    movea.l a3,a4
    cmp.w   -2(a4),d5
    bhs.s   .packed_insert
.packed_shift:
    move.w  -2(a4),(a4)
    subq.l  #2,a4
    ; Equal depths have ascending face IDs in the input.
    ; Compare the packed words as unsigned values to keep this order.
    cmp.w   -2(a4),d5
    blo.s   .packed_shift
.packed_insert:
    move.w  d5,(a4)
    addq.l  #2,a3
    cmpa.l  d2,a3
    blo.s   .packed_item
    bra.s   .advance_band
.item:
    move.w  (a3),d5
    move.w  d5,d0
    add.w   d0,d0
    move.w  (a1,d0.w),d4
    movea.l a3,a4
.compare:
    move.w  -2(a4),d0
    move.w  d0,d1
    add.w   d1,d1
    cmp.w   (a1,d1.w),d4
    ble.s   .insert
    move.w  d0,(a4)
    subq.l  #2,a4
    cmpa.l  a0,a4
    bhi.s   .compare
.insert:
    move.w  d5,(a4)
    addq.l  #2,a3
    cmpa.l  d2,a3
    blo.s   .item
.advance_band:
    lea     SC_BUCKET_STRIDE(a0),a0
    dbra    d3,.band

    lea     sc_order(a2),a3
    lea     sc_sort_work(a2),a0
    lea     SC_BUCKET_BYTES+SC_DEPTH_SHADOW_BYTES+4(sp),a2
    moveq   #SC_LAST_ROW,d7
    movea.l sp,a1
    lea     SC_BUCKET_CURSOR_BYTES(sp),a5
.row:
    movea.l (a2)+,a4
    ; Save the start of the next row.
    move.l  a4,d4
    ; The row has at most SC_GRID_WIDTH-1 consecutive face IDs.
    ; Use the negative byte count as the offset into the two-byte copies.
    ; Copy the terrain IDs backward, then add this band's model IDs.
    move.l  a3,d0
    sub.l   a4,d0
    jmp     .object(pc,d0.w)
.copy_quad:
    rept SC_GRID_WIDTH-1
    move.w  -(a4),(a0)+
    endr
.object:
    ifne .object-.copy_quad-2*(SC_GRID_WIDTH-1)
    fail "Terrain row jump requires fixed two-byte copies."
    endif
    movea.l (a1)+,a6
    movea.l a5,a4
.copy_object:
    cmpa.l  a6,a4
    beq.s   .advance
    move.w  (a4)+,d0
    andi.w  #255,d0
    move.w  d0,(a0)+
    bra.s   .copy_object
.advance:
    movea.l d4,a3
    lea     SC_BUCKET_STRIDE(a5),a5
    dbra    d7,.row
    lea     SC_BUCKET_BYTES+SC_DEPTH_SHADOW_BYTES(sp),sp
.empty:
    rts

; Check one side of a projected rail.
; A0 points to the seam X word. D7 holds the seam Y value.
; Argument 1 gives the corner offset. Argument 2 gives the X direction.
; On the first side, argument 3 is 1. Keep the signed Y difference in D4.
; On the second side, argument 3 is 0. Check the vertical direction.
    macro SLOPE_RAIL
    move.w  4+\1(a0),d3
    sub.w   d7,d3
    move.w  d3,d5
    bpl.s   .rail_abs\@
    neg.w   d5
.rail_abs\@:
    ifeq \2-1
    move.w  \1(a0),d2
    sub.w   (a0),d2
    else
    move.w  (a0),d2
    sub.w   \1(a0),d2
    endif
    ble.w   .slope_no
    move.w  d5,a1
    add.w   d5,d5
    add.w   a1,d5
    cmp.w   d5,d2
    blo.w   .slope_no
    ifeq \3-1
    move.w  d3,d4
    else
    tst.w   d3
    beq.s   .rail_monotone\@
    tst.w   d4
    beq.s   .rail_monotone\@
    eor.w   d4,d3
    bpl.w   .slope_no
.rail_monotone\@:
    endif
    endm

; Check one more corner against a rail that passed the first check.
; A0 points to the original seam X word.
; Argument 1 gives the offset to the far endpoint Y word.
; Argument 2 gives the branch target if the check fails.
    macro TRIPLE_EXTEND_RAIL
    ; Calculate the X gap for the new corner.
    move.w  -16(a0),d2
    sub.w   -8(a0),d2
    ble.w   \2
    move.w  -4(a0),d5
    move.w  -12(a0),d3
    sub.w   d5,d3
    beq.s   .rail_end\@
    ; Use the two endpoints to find the direction of the old rail.
    sub.w   \1(a0),d5
    beq.s   .same_dir\@
    eor.w   d3,d5
    bmi.w   \2
.same_dir\@:
    move.w  d3,d5
    bpl.s   .abs_dy\@
    neg.w   d5
.abs_dy\@:
    move.w  d5,d3
    add.w   d5,d5
    add.w   d3,d5
    cmp.w   d5,d2
    blo.w   \2
.rail_end\@:
    endm

; ------------------------------------------------------------------------
; Ordered drawing and terrain joins
; ------------------------------------------------------------------------

; The first stack argument is the scene. The second is the back page.
; Draw the ordered faces. Poll input at the scheduled face slots.
; This routine preserves D2-D7 and A2-A6.
tb_scene_emit_draw:
    movem.l d2-d7/a2-a6,-(sp)
    movea.l 48(sp),a2
    movea.l 52(sp),a6
    lea     sc_sort_work(a2),a3
    move.w  sc_draw_count(a2),d6
    beq.w   .done
    lea     sc_wedge_cache,a0
    ; This cache key cannot occur at an authored world point.
    move.l  #$80008000,d0
    rept    32
    move.l  d0,(a0)
    addq.l  #8,a0
    endr
    ; D6 counts the slots after the current slot and before the next poll.
    ; The first group can be short. Each later group has 32 slots.
    ; Keep the end pointer separate from the poll count.
    ; A tree pair can cross a poll without changing the final slot.
    move.w  d6,d0
    add.w   d0,d0
    pea     (a3,d0.w)
    subq.w  #1,d6
    andi.w  #31,d6
.face:
    move.w  (a3)+,d0
    cmpi.w  #SC_CLASS_TERRAIN_FACES,d0
    bhs.w   .model
    ; Keep the face ID while D0 changes to the grid node.
    move.w  d0,d7
    add.w   d0,d0
    lea     sc_strip(a2),a4
    adda.w  d0,a4
    lea     sc_strip_top(pc),a1
    ; Read the top-left grid node for this face ID.
    move.w  (a1,d0.w),d0
    cmpi.b  #4,(a4)
    bne.w   .diagonal
    ; The sorter emits descending terrain IDs within each row.
    ; The sorter then emits that band's model IDs and advances to the next row.
    ; Thus the next slot can contain ID-1 only in the same terrain row.
    tst.w   d6
    beq.s   .ordinary_quad
    move.w  d7,d1
    subq.w  #1,d1
    cmp.w   (a3),d1
    bne.s   .ordinary_quad
    move.w  (a4),d3
    cmp.w   -2(a4),d3
    bne.s   .ordinary_quad
    cmpi.b  #8,d3
    bhs.s   .ordinary_quad
    bsr.w   .slope_admit
    bne.s   .union
.ordinary_quad:
    bsr.w   tb_terrain_quad_scene
    beq.w   .rejected_quad
    ; The writer preserves the cursor, count, and A6.
    ; Restore the scene pointer after an accepted quad.
    movea.l 52(sp),a2
    bra.w   .next
.union:
    cmpi.w  #2,d2
    beq.s   .triple
    bhi.s   .four_run
    ; The join cannot cross a poll. Check the poll at the second slot.
    subq.w  #1,d6
    addq.l  #2,a3
    bsr.w   .outer_quad
    movea.l 52(sp),a2
    bra.w   .next
.triple:
    ; The join cannot cross either skipped slot's poll.
    ; Check the poll at the third slot.
    subq.w  #2,d6
    addq.l  #4,a3
    bsr.w   tb_terrain_outer_eight
    movea.l 52(sp),a2
    bra.w   .next
.four_run:
    ; The join cannot cross any of the three skipped slots' polls.
    subq.w  #3,d6
    addq.l  #6,a3
    bsr.w   tb_long_4
    movea.l 52(sp),a2
    bra.w   .next
.rejected_quad:
    ; A4 still points to the strip record.
    ; Get the grid node again to make the fallback face record.
    move.w  d0,d7
    lea     sc_strip(a2),a1
    move.l  a4,d0
    sub.l   a1,d0
    lea     sc_strip_top(pc),a1
    move.w  (a1,d0.w),d0
    bsr.s   .face_record
    ; Keep the fallback face record even when it covers no scanlines.
    tst.w   d7
    bmi.s   .next
    bsr.w   sc_emit_face
    bra.s   .next
.diagonal:
    bsr.s   .face_record
    bsr.w   sc_emit_wedge_face
    bra.s   .next
.model:
    move.w  d0,d7
    SC_TIMES3_W d0,d1
    lsl.w   #2,d0
    lea     sc_faces(a2),a4
    adda.w  d0,a4
    ; Each tree has two consecutive source faces.
    ; Join them only when they occupy consecutive slots in the original order.
    move.b  d7,d0
    sub.b   sc_tree_first_face(a2),d0
    blo.s   .ordinary_model
    cmp.b   sc_tree_end_face(a2),d7
    bhs.s   .ordinary_model
    btst    #0,d0
    bne.s   .ordinary_model
    cmpa.l  (sp),a3
    beq.s   .ordinary_model
    addq.w  #1,d7
    cmp.w   (a3),d7
    bne.s   .ordinary_model
    bsr.w   tb_tree_pair_scene
    tst.b   d0
    beq.s   .ordinary_model
    addq.l  #2,a3
    ; Poll here if the first slot has a scheduled poll.
    tst.w   d6
    bne.s   .tree_second_slot
    bsr.w   play_poll_input
    ; The second slot starts the next group.
    moveq   #32,d6
.tree_second_slot:
    subq.w  #1,d6
    bra.s   .next
.ordinary_model:
    bsr.w   tb_model_poly_scene
    tst.b   d0
    bne.s   .next
    bsr.w   sc_emit_face
.next:
    dbra    d6,.face
    ; Poll during drawing so the keyboard can complete its handshake.
    bsr.w   play_poll_input
    cmpa.l  (sp),a3
    beq.s   .end_slots
    moveq   #31,d6
    bra.w   .face
.end_slots:
    addq.l  #4,sp
.done:
    movem.l (sp)+,d2-d7/a2-a6
    rts

; D0 gives the top-left node. A4 points to the two-byte strip record.
; Write TL, BL, BR, TR and copy the kind and ink into the fallback record.
; Return the address of the record in A4.
.face_record:
    move.w  (a4),d1
    lea     sc_strip_fallback(a2),a4
    move.w  d0,(a4)
    add.w   #SC_GRID_WIDTH,d0
    move.w  d0,2(a4)
    addq.w  #1,d0
    move.w  d0,4(a4)
    sub.w   #SC_GRID_WIDTH,d0
    move.w  d0,6(a4)
    move.w  d1,8(a4)
    rts

; D0 gives the top-left grid node. D6 holds the poll count.
; The caller checks the first pair for adjacent slots and equal solid inks.
; Check that all six projected corners are inside the viewport.
; The result in D2 is the number of extra tiles. Zero rejects the join.
; On rejection, preserve D0, D6, A2, A3, A4, and A6.
.slope_admit:
    lea     sc_outcode(a2),a0
    adda.w  d0,a0
    move.b  -1(a0),d2
    or.b    (a0),d2
    or.b    1(a0),d2
    or.b    SC_GRID_WIDTH-1(a0),d2
    or.b    SC_GRID_WIDTH(a0),d2
    or.b    SC_GRID_WIDTH+1(a0),d2
    andi.b  #$21,d2
    bne.w   .slope_no

    move.w  d0,d2
    lsl.w   #3,d2
    lea     sc_projected+2(a2),a0
    adda.w  d2,a0
    ; All three columns must change Y in the same direction.
    ; The rails can overlap in Y.
    move.w  4(a0),d7
    move.w  4+SC_GRID_WIDTH*8(a0),d3
    move.w  d3,d1
    sub.w   d7,d1
    beq.w   .slope_no
    bmi.s   .reverse_slope
    move.w  4+SC_GRID_WIDTH*8-8(a0),d2
    cmp.w   -4(a0),d2
    ble.w   .slope_no
    move.w  4+SC_GRID_WIDTH*8+8(a0),d2
    cmp.w   12(a0),d2
    ble.w   .slope_no
    bra.s   .check_slope
.reverse_slope:
    move.w  4+SC_GRID_WIDTH*8-8(a0),d2
    cmp.w   -4(a0),d2
    bge.w   .slope_no
    move.w  4+SC_GRID_WIDTH*8+8(a0),d2
    cmp.w   12(a0),d2
    bge.w   .slope_no
    neg.w   d1
.check_slope:
    move.w  d7,d2
    addq.w  #7,d2
    addq.w  #7,d3
    lsr.w   #4,d2
    lsr.w   #4,d3
    cmp.w   d2,d3
    beq.w   .slope_no
    add.w   d1,d1
    move.w  SC_GRID_WIDTH*8(a0),d2
    sub.w   (a0),d2
    bpl.s   .seam_abs
    neg.w   d2
.seam_abs:
    cmp.w   d1,d2
    bhi.w   .slope_no

    ; The seam has an absolute slope of at most two X units per Y unit.
    ; The X gap must be at least three times the absolute Y difference.
    ; The resulting separation exceeds the combined error of the two Q16 edges.
    SLOPE_RAIL    -8,1,1
    SLOPE_RAIL     8,-1,0
    lea     SC_GRID_WIDTH*8(a0),a0
    move.w  4(a0),d7
    SLOPE_RAIL    -8,1,1
    SLOPE_RAIL     8,-1,0

; A0 points to the lower seam. D0 still holds the top-left grid node.
; Keep the three columns that passed the pair check.
.extend_first:
    ; Do not extend the pair if the second slot has a poll.
    ; Also require the next slot to contain the adjacent terrain ID.
    cmpi.w  #1,d6
    beq.w   .keep_pair
    move.w  (a3),d1
    subq.w  #1,d1
    cmp.w   2(a3),d1
    bne.w   .keep_pair
    move.w  (a4),d1
    cmp.w   -4(a4),d1
    bne.w   .keep_pair
    lea     sc_outcode-2(a2),a1
    adda.w  d0,a1
    move.b  (a1),d1
    or.b    SC_GRID_WIDTH(a1),d1
    andi.b  #$21,d1
    bne.w   .keep_pair

    ; The left column of the pair is the new seam.
    ; The new outside column must have the same vertical direction.
    move.w  -4(a0),d7
    move.w  -4-SC_GRID_WIDTH*8(a0),d3
    move.w  -12(a0),d5
    sub.w   -12-SC_GRID_WIDTH*8(a0),d5
    beq.w   .keep_pair
    move.w  d7,d1
    sub.w   d3,d1
    eor.w   d1,d5
    bmi.w   .keep_pair
    tst.w   d1
    bpl.s   .positive_height
    neg.w   d1
.positive_height:
    ; A difference of 16 Q4 units or more always gives a sample.
    cmpi.w  #16,d1
    bhs.s   .nonempty_seam
    addq.w  #7,d3
    addq.w  #7,d7
    lsr.w   #4,d3
    lsr.w   #4,d7
    cmp.w   d3,d7
    beq.w   .keep_pair
.nonempty_seam:
    add.w   d1,d1
    move.w  -8(a0),d2
    sub.w   -8-SC_GRID_WIDTH*8(a0),d2
    bpl.s   .positive_width
    neg.w   d2
.positive_width:
    cmp.w   d1,d2
    bhi.w   .keep_pair

    ; Check only the new side against the direction of the full old rail.
    ; Equal Y values at an inner step do not permit a reversal.
    TRIPLE_EXTEND_RAIL 12,.keep_pair
    lea     -SC_GRID_WIDTH*8(a0),a0
    TRIPLE_EXTEND_RAIL 12,.keep_pair

    ; Save the original top seam in A5.
    ; Use it for the three-tile outline if the last check fails.
.extend_four:
    movea.l a0,a5
    cmpi.w  #2,d6
    beq.w   .keep_three
    move.w  2(a3),d1
    subq.w  #1,d1
    cmp.w   4(a3),d1
    bne.w   .keep_three
    move.w  (a4),d1
    cmp.w   -6(a4),d1
    bne.w   .keep_three
    lea     sc_outcode-3(a2),a1
    adda.w  d0,a1
    move.b  (a1),d1
    or.b    SC_GRID_WIDTH(a1),d1
    andi.b  #$21,d1
    bne.w   .keep_three

    ; Move one node left. This column becomes the seam.
    ; Check only the new adjacent column.
    lea     -8(a0),a0
    move.w  -4(a0),d3
    move.w  -4+SC_GRID_WIDTH*8(a0),d7
    move.w  -12+SC_GRID_WIDTH*8(a0),d5
    sub.w   -12(a0),d5
    beq.w   .keep_three
    move.w  d7,d1
    sub.w   d3,d1
    eor.w   d1,d5
    bmi.w   .keep_three
    tst.w   d1
    bpl.s   .four_positive_height
    neg.w   d1
.four_positive_height:
    cmpi.w  #16,d1
    bhs.s   .four_nonempty_seam
    addq.w  #7,d3
    addq.w  #7,d7
    lsr.w   #4,d3
    lsr.w   #4,d7
    cmp.w   d3,d7
    beq.w   .keep_three
.four_nonempty_seam:
    add.w   d1,d1
    move.w  -8+SC_GRID_WIDTH*8(a0),d2
    sub.w   -8(a0),d2
    bpl.s   .four_positive_width
    neg.w   d2
.four_positive_width:
    cmp.w   d1,d2
    bhi.w   .keep_three
    TRIPLE_EXTEND_RAIL 20,.keep_three
    lea     SC_GRID_WIDTH*8(a0),a0
    TRIPLE_EXTEND_RAIL 20,.keep_three
    ; A0 points to the top-left point of the four-tile outline.
    lea     -24(a5),a0
    moveq   #3,d2
    rts
.keep_three:
    lea     -16(a5),a0
    moveq   #2,d2
    rts
.keep_pair:
    moveq   #1,d2
    rts

.slope_no:
    moveq   #0,d2
    rts

.outer_quad:
    ; The pair starts one column before the grid node in D0.
    ; The writer reads the six projected X and Y pairs directly.
    lsl.w   #3,d0
    lea     sc_projected+2-8(a2),a0
    adda.w  d0,a0
    bra.w   tb_terrain_outer_six

; Convert a terrain face ID to its top-left grid node.
sc_strip_top:
strip_node set 0
    rept SC_GRID_DEPTH-1
    rept SC_GRID_WIDTH-1
    dc.w strip_node
strip_node set strip_node+1
    endr
strip_node set strip_node+1
    endr

; ------------------------------------------------------------------------
; Exact X projection for terrain grid rows
; ------------------------------------------------------------------------

; The grid row has one camera depth. Start with the first quotient and remainder.
; For each full tile, subtract the X-step quotient and remainder.
; If the remainder becomes negative, add the depth and decrement the quotient.
; Use separate runs for nonnegative and negative numerators to match DIVS.

; The X axis can have a partial tile at each end and repeat its last point.
; Use DIVS at each partial endpoint. Copy the last point into the padding.
; If two consecutive rows have the same depth, copy the first row's X values.
; Skip rows with a camera depth below SC_NEAR.
SC_X_PREVIOUS equ 0
SC_X_POSITIVE equ 2
SC_X_PADDING  equ 4
SC_X_ENDS     equ 6
SC_X_LOW_NUM  equ 8
SC_X_HIGH_NUM equ 12
SC_X_NEGATIVE equ 16
SC_X_BYTES    equ 18

; Use camera X in D6.W and the world X operand to calculate the numerator in D0.L.
    macro SC_X_NUMERATOR
    move.w  d6,d0
    sub.w   \1,d0
    swap    d0
    clr.w   d0
    endm

; Divide D0.L by D2.W. Return the floor quotient in D1.W and the remainder in D0.W.
    macro SC_X_ANCHOR
    divs.w  d2,d0
    move.w  d0,d1
    swap    d0
    tst.w   d0
    bpl.s   .floor\@
    add.w   d2,d0
    subq.w  #1,d1
.floor\@:
    endm

; Add the screen center to the quotient in D6.W.
; Store the X value as a signed longword and advance A6.
    macro SC_X_SCREEN
    addi.w  #SC_CX,d6
    ext.l   d6
    move.l  d6,(a6)
    addq.l  #8,a6
    endm

; The floor quotient matches DIVS for nonnegative numerators.
; The ceiling quotient matches DIVS for negative numerators.
; Keep ceiling remainder + D2 - 1 so both runs use the same correction.
    macro SC_X_COMPLEMENT
    tst.w   d0
    beq.s   .exact\@
    addq.w  #1,d1
    bra.s   .adjust\@
.exact\@:
    move.w  d2,d0
.adjust\@:
    subq.w  #1,d0
    endm

    macro SC_X_RAIL_STEP
    sub.w   d4,d1
    sub.w   d3,d0
    bpl.s   \1
    add.w   d2,d0
    subq.w  #1,d1
    endm

; Store the signed X value in D1.W and advance A6. The value includes the screen center.
    macro SC_X_RAIL_STORE
    move.w  d1,d6
    ext.l   d6
    move.l  d6,(a6)
    addq.l  #8,a6
    endm

; For a partial endpoint, use the signed DIVS quotient directly.
; Do not convert the quotient and remainder to the form for the full tiles.
    macro SC_X_PARTIAL
    divs.w  d2,d0
    move.w  d0,d6
    SC_X_SCREEN
    endm

; A2 points to the scene. Write the Q4 X longword of each projected grid point.
; This routine preserves A2, A4, and A5. It can change D0-D7, A0-A1, A3, and A6.
sc_project_grid_x:
    movem.l a4-a5,-(sp)
    lea     -SC_X_BYTES(sp),sp
    clr.w   SC_X_PREVIOUS(sp)
    ; Bits 0 and 1 mark the low and high partial tiles.
    moveq   #0,d3
    move.w  sc_camx(a2),d6
    lea     sc_grid_x(a2),a0
    move.w  2(a0),d0
    sub.w   (a0),d0
    ; A zero first gap identifies an axis with one repeated point.
    beq.s   .low_ready
    cmpi.w  #SC_TILE_SIZE,d0
    beq.s   .low_ready
    SC_X_NUMERATOR (a0)
    move.l  d0,SC_X_LOW_NUM(sp)
    addq.l  #2,a0
    moveq   #1,d3
.low_ready:
    SC_X_NUMERATOR (a0)
    ; Keep the same numerator for the first full-tile point in each row.
    movea.l d0,a4
    lea     sc_grid_x+SC_GRID_X_END(a2),a1
    move.w  (a1),d1
    moveq   #0,d5
.trim:
    cmpa.l  a0,a1
    bls.s   .high_ready
    cmp.w   -2(a1),d1
    bne.s   .last_gap
    subq.l  #2,a1
    addq.w  #1,d5
    bra.s   .trim
.last_gap:
    sub.w   -2(a1),d1
    cmpi.w  #SC_TILE_SIZE,d1
    beq.s   .high_ready
    SC_X_NUMERATOR (a1)
    move.l  d0,SC_X_HIGH_NUM(sp)
    subq.l  #2,a1
    bset    #1,d3
.high_ready:
    move.w  d5,SC_X_PADDING(sp)
    move.w  d3,SC_X_ENDS(sp)
    move.l  a1,d0
    sub.l   a0,d0
    lsr.w   #1,d0
    ; Each full tile adds 16 world units to X.
    ; Calculate the sign boundary once for all rows.
    move.w  d6,d1
    sub.w   (a0),d1
    asr.w   #SC_TILE_SHIFT,d1
    addq.w  #1,d1
    bpl.s   .positive_bound
    moveq   #0,d1
.positive_bound:
    move.w  d0,d3
    addq.w  #1,d3
    cmp.w   d3,d1
    ble.s   .split_ready
    move.w  d3,d1
.split_ready:
    sub.w   d1,d0
    move.w  d0,SC_X_NEGATIVE(sp)
    subq.w  #1,d1
    move.w  d1,SC_X_POSITIVE(sp)

    lea     sc_elevation_magic-8*SC_FOOT_NEAR,a5
    lea     sc_grid_z(a2),a3
    lea     sc_projected(a2),a6
    moveq   #SC_GRID_DEPTH-1,d7
.row:
    move.w  sc_camz(a2),d2
    sub.w   (a3)+,d2
    lsl.w   #4,d2
    cmpi.w  #SC_NEAR,d2
    blt.w   .next_row
    cmp.w   SC_X_PREVIOUS(sp),d2
    beq.w   .repeat_depth
    move.w  d2,SC_X_PREVIOUS(sp)
    move.w  d2,d0
    lsr.w   #1,d0
    move.l  (a5,d0.w),d4
    move.w  d4,d3
    swap    d4
    lsr.w   #6,d4
    btst    #0,SC_X_ENDS+1(sp)
    beq.s   .seed
    move.l  SC_X_LOW_NUM(sp),d0
    SC_X_PARTIAL
.seed:
    move.l  a4,d0
    SC_X_ANCHOR
    addi.w  #SC_CX,d1
    move.w  SC_X_POSITIVE(sp),d5
    bmi.s   .negative_seed
    bra.s   .positive_out
.positive_step:
    SC_X_RAIL_STEP .positive_out
.positive_out:
    SC_X_RAIL_STORE
    dbra    d5,.positive_step
    move.w  SC_X_NEGATIVE(sp),d5
    bmi.s   .rail_done
    ; Convert at the last nonnegative point before the first negative step.
    ; Apply the exact correction when the remainder is zero.
    SC_X_COMPLEMENT
.negative_step:
    SC_X_RAIL_STEP .negative_out
.negative_out:
    SC_X_RAIL_STORE
    dbra    d5,.negative_step
.rail_done:
    btst    #1,SC_X_ENDS+1(sp)
    beq.s   .padding
    move.l  SC_X_HIGH_NUM(sp),d0
    SC_X_PARTIAL
.padding:
    move.w  SC_X_PADDING(sp),d5
    beq.s   .depth
    subq.w  #1,d5
.repeat_x:
    move.l  d6,(a6)
    addq.l  #8,a6
    dbra    d5,.repeat_x
    bra.s   .depth
.negative_seed:
    move.w  SC_X_NEGATIVE(sp),d5
    SC_X_COMPLEMENT
    bra.s   .negative_out
.repeat_depth:
    lea     -8*SC_GRID_WIDTH(a6),a0
    moveq   #SC_GRID_WIDTH-1,d5
.copy_x:
    move.l  (a0),(a6)
    addq.l  #8,a0
    addq.l  #8,a6
    dbra    d5,.copy_x
    bra.s   .depth
.next_row:
    clr.w   SC_X_PREVIOUS(sp)
    lea     8*SC_GRID_WIDTH(a6),a6
.depth:
    dbra    d7,.row
    lea     SC_X_BYTES(sp),sp
    movem.l (sp)+,a4-a5
    rts

; ------------------------------------------------------------------------
; Fallback polygon projection and clipping
; ------------------------------------------------------------------------

; A2 points to the scene. A4 points to a face. A6 points to the back page.
; Copy the projected points if all vertices are on or in front of the near plane.
; Otherwise, clip the edges and store their projected points on the stack.
; This routine preserves D2-D7 and A2-A6.
sc_emit_face:
    movem.l d2-d7/a3-a4,-(sp)
    lea     -24(sp),sp
    movea.l sp,a3
    moveq   #0,d7
    move.b  8(a4),d7
    move.w  d7,d6
    subq.w  #1,d6
    move.w  d6,d0
    add.w   d0,d0
    ; Start with the last point to include the closing edge.
    move.w  (a4,d0.w),d5
    lea     sc_outcode(a2),a0
    movem.w (a4),d0-d3
    move.b  (a0,d0.w),d4
    or.b    (a0,d1.w),d4
    or.b    (a0,d2.w),d4
    or.b    (a0,d3.w),d4
    btst    #0,d4
    bne.s   .near_clip
    lea     sc_projected(a2),a0
    movea.l a4,a1
.copy:
    move.w  (a1)+,d0
    lsl.w   #3,d0
    move.w  2(a0,d0.w),(a3)+
    move.w  6(a0,d0.w),(a3)+
    dbra    d6,.copy
    bra     .paint

.near_clip:
    ; Start the output point count at zero.
    moveq   #0,d7
.edge:
    move.w  (a4)+,d4
    lea     sc_camera_vertices(a2),a0
    move.w  d5,d0
    SC_TIMES3_W d0,d1
    add.w   d0,d0
    ; A1 points to the previous camera vertex.
    lea     (a0,d0.w),a1
    move.w  d4,d0
    SC_TIMES3_W d0,d1
    add.w   d0,d0
    ; A0 points to the current camera vertex.
    lea     (a0,d0.w),a0
    move.w  4(a1),d2
    move.w  4(a0),d5
    move.w  d2,d0
    cmpi.w  #SC_NEAR,d0
    slt     d0
    move.w  d5,d1
    cmpi.w  #SC_NEAR,d1
    slt     d1
    cmp.b   d1,d0
    beq.s   .maybe_current

    ; Start interpolation at the endpoint with the smaller Z.
    ; This gives both faces on the edge the same signed division result.
    move.w  d5,-(sp)
    cmp.w   d5,d2
    ble.s   .calculate_edge
    exg     a0,a1
    exg     d2,d5
.calculate_edge:
    ; D5 holds the positive Z difference along the edge.
    sub.w   d2,d5
    move.w  #SC_NEAR,d1
    ; D1 holds the Z distance from the lower endpoint to the near plane.
    sub.w   d2,d1
    move.w  (a0),d0
    sub.w   (a1),d0
    muls.w  d1,d0
    divs.w  d5,d0
    add.w   (a1),d0
    move.w  2(a0),d2
    sub.w   2(a1),d2
    muls.w  d1,d2
    divs.w  d5,d2
    add.w   2(a1),d2
    move.w  d2,d1
    move.w  #SC_NEAR,d2
    move.l  sc_draw_mode(a2),d3
    ; Read the face base from the save area below the saved endpoint.
    movea.l 54(sp),a0
    cmpi.w  #SC_GRID_POINTS,(a0)
    bhs.s   .clip_project
    moveq   #0,d3
.clip_project:
    bsr     sc_project
    move.w  d0,(a3)+
    move.w  d1,(a3)+
    addq.w  #1,d7
    move.w  (sp)+,d5
.maybe_current:
    cmpi.w  #SC_NEAR,d5
    blt.s   .advance
    lea     sc_projected(a2),a0
    move.w  d4,d0
    lsl.w   #3,d0
    move.w  2(a0,d0.w),(a3)+
    move.w  6(a0,d0.w),(a3)+
    addq.w  #1,d7
.advance:
    move.w  d4,d5
    dbra    d6,.edge
    ; A4 advanced over the source points.
    ; Restore the face base to read its ink at offset 9.
    movea.l 52(sp),a4
.paint:
    cmpi.w  #3,d7
    blo.s   .done
    moveq   #0,d0
    move.b  9(a4),d0
    cmpi.w  #16,d0
    blo.s   .solid
    bset    #8,d0
.solid:
    movea.l sp,a0
    ; A0 points to the Q4 points. D7.W gives the count.
    ; D0 gives the ink code. A6 points to the back page.
    ; The span writer preserves A2, A5, and A6.
    bsr.w   tb_span_poly_scene
.done:
    lea     24(sp),sp
    movem.l (sp)+,d2-d7/a3-a4
    rts

; ------------------------------------------------------------------------
; Terrain tiles on the foreground boundary
; ------------------------------------------------------------------------

; Convert a top-left grid node to the even byte offsets in the X and Z axes.
sc_wedge_axes:
.wr set 0
    rept SC_GRID_DEPTH
.wc set 0
    rept SC_GRID_WIDTH
    dc.b 2*.wc,2*.wr
.wc set .wc+1
    endr
.wr set .wr+1
    endr

sc_wedge_xz macro
    ifne (\1=6)|(\1=6*SC_GRID_WIDTH+6)
    move.w  22(sp),d0
    else
    move.w  20(sp),d0
    endif
    ifge \1-6*SC_GRID_WIDTH
    move.w  26(sp),d2
    else
    move.w  24(sp),d2
    endif
    endm

sc_wedge_side macro
    sc_wedge_xz \1
    move.w  d2,d3
    add.w   d3,d3
    add.w   d0,d3
    sub.w   sc_front_dx(a2),d3
    endm

; Visit one corner. Argument 1 is 0 for constant Z or 1 for constant X.
sc_wedge_corner macro
    ; Kind 5 has its top-left corner inside the boundary.
    ; Its bottom-right corner is outside the boundary.
    ; Keep a corner on the boundary without adding an intersection.
    ifeq \3-2
    ; Skip the projected index for the outside bottom-right corner.
    addq.l  #2,a4
    else
    move.w  (a4)+,d6
    endif
    ifeq \3
    ; Read the inside top-left coordinates only for an intersection.
    tst.w   d4
    ble.s   .keep\@
    sc_wedge_side \2
    endif
    ifeq \3-1
    ; Keep the signed side for use at the bottom-right corner.
    sc_wedge_side \2
    tst.w   d3
    ble.s   .keep\@
    endif
    ifeq \3-2
    ; Read the outside bottom-right coordinates only for an intersection.
    tst.w   d5
    bge.s   .next\@
    sc_wedge_side \2
    endif
    ifeq \3-3
    ; Reuse the signed side of the top-right corner.
    move.w  d4,d3
    bgt.s   .next\@
    beq.s   .keep\@
    sc_wedge_xz \2
    endif
    ; The top and bottom edges have constant Z.
    ; The left and right edges have constant X.
    ifne \1
    move.w  d3,d1
    asr.w   #1,d1
    sub.w   d1,d2
    else
    sub.w   d3,d0
    endif
    ; Select the cache entry by the fixed edge coordinate and coarse cell.
    ; Compare both X and Z before use.
    ifne \1
    move.w  d0,d1
    else
    move.w  d2,d1
    endif
    andi.w  #$f0,d1
    lsr.w   #1,d1
    ifeq \1
    addi.w  #128,d1
    endif
    lea     sc_wedge_cache,a0
    adda.w  d1,a0
    move.w  d0,d1
    swap    d1
    move.w  d2,d1
    cmp.l   (a0),d1
    bne.s   .cache_miss\@
    move.l  4(a0),(a3)+
    addq.w  #1,d7
    bra.s   .no_intersection\@
.cache_miss\@:
    move.l  d1,(a0)
    bsr.w   .project_world
    move.l  -4(a3),4(a0)
.no_intersection\@:
    ifeq \3-1
    ; The bottom-left corner is outside. Keep only the intersection.
    bra.s   .next\@
    endif
    ifne \3-2
.keep\@:
    move.w  d6,d0
    lsl.w   #3,d0
    lea     sc_projected(a2),a0
    move.w  2(a0,d0.w),(a3)+
    move.w  6(a0,d0.w),(a3)+
    addq.w  #1,d7
    endif
.next\@:
    ifeq \3-1
    move.w  d3,d5
    endif
    endm

; A2 points to the scene. A4 points to a boundary face. A6 is the back page.
; Intersect the tile with the foreground line. Emit the three to five points.
; Use the existing projections for the original corners.
; Sample each intersection height at its world X and Z.
; This routine preserves D2-D7 and A2-A6.
sc_emit_wedge_face:
    movem.l d2-d7/a3-a4,-(sp)
    lea     -28(sp),sp
    movea.l sp,a3
    moveq   #0,d7
    ; The face record gives TL, BL, BR, TR in order.
    ; Each corner offset is relative to TL.
    move.w  (a4),d3
    add.w   d3,d3
    lea     sc_wedge_axes(pc),a1
    moveq   #0,d0
    moveq   #0,d2
    move.b  (a1,d3.w),d0
    addq.w  #1,d3
    move.b  (a1,d3.w),d2
    lea     sc_grid_x(a2),a1
    ; Save the two X coordinates.
    move.l  (a1,d0.w),20(sp)
    lea     sc_grid_z(a2),a1
    ; Save the two Z coordinates.
    move.l  (a1,d2.w),24(sp)
    ; Calculate the signed distance for the top-right corner first.
    sc_wedge_side 6
    move.w  d3,d4
    sc_wedge_corner 0,0,0
    sc_wedge_corner 1,6*SC_GRID_WIDTH,1
    sc_wedge_corner 0,6*SC_GRID_WIDTH+6,2
    sc_wedge_corner 1,6,3
    cmpi.w  #3,d7
    blo.s   .done
    moveq   #0,d0
    move.b  1(a4),d0
    cmpi.w  #16,d0
    blo.s   .ink
    bset    #8,d0
.ink:
    movea.l sp,a0
    bsr.w   tb_span_poly_scene
.done:
    lea     28(sp),sp
    movem.l (sp)+,d2-d7/a3-a4
    rts

; D0 and D2 give world X and Z. Append the projected Q4 pair at A3.
; Advance A3 and increment the point count in D7.
.project_world:
    bsr.w   sc_ground_height
    neg.w   d2
    add.w   sc_camz(a2),d2
    lsl.w   #4,d2
    neg.w   d0
    add.w   sc_camx(a2),d0
    ; Integer rounding keeps the intersection within its edge endpoints.
    ; Depth stays within 96 to 304 units. Terrain height stays within 0 to 21.
    ; Use the terrain elevation table for the intersection.
    ; Scale the signed world X difference by 65536.
    swap    d0
    clr.w   d0
    divs.w  d2,d0
    addi.w  #SC_CX,d0
    sub.w   sc_camy(a2),d1
    neg.w   d1
    ; Convert the height below the eye to Q6.
    lsl.w   #6,d1
    ; Convert the Q4 depth to an eight-byte table offset.
    lsr.w   #1,d2
    lea     sc_elevation_magic-8*SC_FOOT_NEAR,a1
    mulu.w  (a1,d2.w),d1
    add.l   4(a1,d2.w),d1
    swap    d1
    move.w  d0,(a3)+
    move.w  d1,(a3)+
    addq.w  #1,d7
    rts

    section bss,bss
sc_wedge_cache: ds.l 32*2
sc_house_ground: ds.w 1
sc_grove_ground: ds.w SC_GROVE_COUNT
    section code,code

    ifgt SC_NEAR-16*SC_FOOT_NEAR
    fail "Typed strip requires every terrain vertex beyond the near plane"
    endif
    ifne (SC_FOCUS_Q4-4096)|(SC_CAMERA_ORIGIN_Y-1216)|(SC_EYE_HEIGHT-44)|(SC_GROUND_MAX-21)|(SC_FOOT_NEAR-96)|(SC_FOOT_FAR-304)
    fail "Regenerate exact elevation coefficients for updated camera bounds"
    endif
    section elevation_magic,data

; ------------------------------------------------------------------------
; Exact terrain projection table
; ------------------------------------------------------------------------

; tools/make_elevation_magic.py generates one eight-byte record per depth.
; The first word is the Y slope. Its upper ten bits also give the X-step quotient.
; The second word is the remainder for the X step. The longword is the Y bias.
; Calculate screen Y in Q4 as (height_below_eye_q6 * slope + bias) >> 16.
sc_elevation_magic:
    dc.w 43690,1024
    dc.l 79704512  ; Z = 96
    dc.w 43240,976
    dc.l 79692480  ; Z = 97
    dc.w 42799,1152
    dc.l 79692480  ; Z = 98
    dc.w 42366,1552
    dc.l 79692928  ; Z = 99
    dc.w 41943,576
    dc.l 79693120  ; Z = 100
    dc.w 41527,1408
    dc.l 79693632  ; Z = 101
    dc.w 41120,832
    dc.l 79694784  ; Z = 102
    dc.w 40721,448
    dc.l 79693056  ; Z = 103
    dc.w 40329,256
    dc.l 79696832  ; Z = 104
    dc.w 39945,256
    dc.l 79699136  ; Z = 105
    dc.w 39568,448
    dc.l 79695296  ; Z = 106
    dc.w 39199,832
    dc.l 79692288  ; Z = 107
    dc.w 38836,1408
    dc.l 79693376  ; Z = 108
    dc.w 38479,432
    dc.l 79694720  ; Z = 109
    dc.w 38130,1376
    dc.l 79692416  ; Z = 110
    dc.w 37786,736
    dc.l 79693824  ; Z = 111
    dc.w 37449,256
    dc.l 79696832  ; Z = 112
    dc.w 37117,1744
    dc.l 79692096  ; Z = 113
    dc.w 36792,1600
    dc.l 79692736  ; Z = 114
    dc.w 36472,1616
    dc.l 79691968  ; Z = 115
    dc.w 36157,1792
    dc.l 79695488  ; Z = 116
    dc.w 35848,256
    dc.l 79701952  ; Z = 117
    dc.w 35544,736
    dc.l 79696576  ; Z = 118
    dc.w 35246,1376
    dc.l 79693248  ; Z = 119
    dc.w 34952,256
    dc.l 79695552  ; Z = 120
    dc.w 34663,1200
    dc.l 79693568  ; Z = 121
    dc.w 34379,352
    dc.l 79694272  ; Z = 122
    dc.w 34100,1600
    dc.l 79692608  ; Z = 123
    dc.w 33825,1024
    dc.l 79692864  ; Z = 124
    dc.w 33554,576
    dc.l 79693632  ; Z = 125
    dc.w 33288,256
    dc.l 79692736  ; Z = 126
    dc.w 33026,64
    dc.l 79694336  ; Z = 127
    dc.w 32768,0
    dc.l 79724480  ; Z = 128
    dc.w 32513,64
    dc.l 79697088  ; Z = 129
    dc.w 32263,256
    dc.l 79695808  ; Z = 130
    dc.w 32017,576
    dc.l 79694080  ; Z = 131
    dc.w 31775,1024
    dc.l 79692800  ; Z = 132
    dc.w 31536,1600
    dc.l 79694272  ; Z = 133
    dc.w 31300,160
    dc.l 79693632  ; Z = 134
    dc.w 31068,976
    dc.l 79694144  ; Z = 135
    dc.w 30840,1920
    dc.l 79694784  ; Z = 136
    dc.w 30615,800
    dc.l 79692480  ; Z = 137
    dc.w 30393,1984
    dc.l 79693696  ; Z = 138
    dc.w 30174,1072
    dc.l 79693504  ; Z = 139
    dc.w 29959,256
    dc.l 79693312  ; Z = 140
    dc.w 29746,1792
    dc.l 79693952  ; Z = 141
    dc.w 29537,1184
    dc.l 79693120  ; Z = 142
    dc.w 29330,672
    dc.l 79694848  ; Z = 143
    dc.w 29127,256
    dc.l 79695680  ; Z = 144
    dc.w 28926,2256
    dc.l 79689216  ; Z = 145
    dc.w 28728,2048
    dc.l 79692480  ; Z = 146
    dc.w 28532,1936
    dc.l 79694144  ; Z = 147
    dc.w 28339,1920
    dc.l 79694656  ; Z = 148
    dc.w 28149,2000
    dc.l 79694144  ; Z = 149
    dc.w 27962,2176
    dc.l 79692224  ; Z = 150
    dc.w 27776,32
    dc.l 79695808  ; Z = 151
    dc.w 27594,384
    dc.l 79693760  ; Z = 152
    dc.w 27413,832
    dc.l 79693312  ; Z = 153
    dc.w 27235,1376
    dc.l 79694656  ; Z = 154
    dc.w 27060,2016
    dc.l 79691584  ; Z = 155
    dc.w 26886,256
    dc.l 79693888  ; Z = 156
    dc.w 26715,1072
    dc.l 79692544  ; Z = 157
    dc.w 26546,1984
    dc.l 79692288  ; Z = 158
    dc.w 26379,448
    dc.l 79693504  ; Z = 159
    dc.w 26214,1536
    dc.l 79699392  ; Z = 160
    dc.w 26051,144
    dc.l 79693056  ; Z = 161
    dc.w 25890,1408
    dc.l 79694272  ; Z = 162
    dc.w 25731,160
    dc.l 79693184  ; Z = 163
    dc.w 25575,1600
    dc.l 79692608  ; Z = 164
    dc.w 25420,496
    dc.l 79691584  ; Z = 165
    dc.w 25266,2112
    dc.l 79694080  ; Z = 166
    dc.w 25115,1152
    dc.l 79693312  ; Z = 167
    dc.w 24966,256
    dc.l 79693568  ; Z = 168
    dc.w 24818,2128
    dc.l 79692416  ; Z = 169
    dc.w 24672,1376
    dc.l 79692736  ; Z = 170
    dc.w 24528,688
    dc.l 79692224  ; Z = 171
    dc.w 24385,64
    dc.l 79693568  ; Z = 172
    dc.w 24244,2272
    dc.l 79692352  ; Z = 173
    dc.w 24105,1792
    dc.l 79692288  ; Z = 174
    dc.w 23967,1376
    dc.l 79692928  ; Z = 175
    dc.w 23831,1024
    dc.l 79695424  ; Z = 176
    dc.w 23696,736
    dc.l 79693760  ; Z = 177
    dc.w 23563,512
    dc.l 79693504  ; Z = 178
    dc.w 23431,352
    dc.l 79694976  ; Z = 179
    dc.w 23301,256
    dc.l 79694336  ; Z = 180
    dc.w 23172,224
    dc.l 79695296  ; Z = 181
    dc.w 23045,256
    dc.l 79693888  ; Z = 182
    dc.w 22919,352
    dc.l 79694080  ; Z = 183
    dc.w 22795,512
    dc.l 79693504  ; Z = 184
    dc.w 22671,736
    dc.l 79695104  ; Z = 185
    dc.w 22550,1024
    dc.l 79691776  ; Z = 186
    dc.w 22429,1376
    dc.l 79692544  ; Z = 187
    dc.w 22310,1792
    dc.l 79692736  ; Z = 188
    dc.w 22192,2272
    dc.l 79692224  ; Z = 189
    dc.w 22075,2816
    dc.l 79692608  ; Z = 190
    dc.w 21959,368
    dc.l 79695680  ; Z = 191
    dc.w 21845,1024
    dc.l 79703552  ; Z = 192
    dc.w 21732,1744
    dc.l 79694144  ; Z = 193
    dc.w 21620,2528
    dc.l 79692096  ; Z = 194
    dc.w 21509,256
    dc.l 79710400  ; Z = 195
    dc.w 21399,1152
    dc.l 79694144  ; Z = 196
    dc.w 21290,2112
    dc.l 79694720  ; Z = 197
    dc.w 21183,3136
    dc.l 79692352  ; Z = 198
    dc.w 21076,1040
    dc.l 79692352  ; Z = 199
    dc.w 20971,2176
    dc.l 79694336  ; Z = 200
    dc.w 20867,160
    dc.l 79692032  ; Z = 201
    dc.w 20763,1408
    dc.l 79694592  ; Z = 202
    dc.w 20661,2720
    dc.l 79692736  ; Z = 203
    dc.w 20560,832
    dc.l 79693248  ; Z = 204
    dc.w 20460,2256
    dc.l 79692096  ; Z = 205
    dc.w 20360,448
    dc.l 79694016  ; Z = 206
    dc.w 20262,1984
    dc.l 79692736  ; Z = 207
    dc.w 20164,256
    dc.l 79696832  ; Z = 208
    dc.w 20068,1904
    dc.l 79691840  ; Z = 209
    dc.w 19972,256
    dc.l 79696704  ; Z = 210
    dc.w 19878,2016
    dc.l 79692544  ; Z = 211
    dc.w 19784,448
    dc.l 79693504  ; Z = 212
    dc.w 19691,2320
    dc.l 79692864  ; Z = 213
    dc.w 19599,832
    dc.l 79693632  ; Z = 214
    dc.w 19508,2816
    dc.l 79692480  ; Z = 215
    dc.w 19418,1408
    dc.l 79693120  ; Z = 216
    dc.w 19328,32
    dc.l 79695808  ; Z = 217
    dc.w 19239,2176
    dc.l 79694080  ; Z = 218
    dc.w 19152,880
    dc.l 79692224  ; Z = 219
    dc.w 19065,3136
    dc.l 79692992  ; Z = 220
    dc.w 18978,1920
    dc.l 79694272  ; Z = 221
    dc.w 18893,736
    dc.l 79692800  ; Z = 222
    dc.w 18808,3152
    dc.l 79693504  ; Z = 223
    dc.w 18724,2048
    dc.l 79697984  ; Z = 224
    dc.w 18641,976
    dc.l 79692352  ; Z = 225
    dc.w 18558,3552
    dc.l 79693312  ; Z = 226
    dc.w 18477,2560
    dc.l 79692096  ; Z = 227
    dc.w 18396,1600
    dc.l 79692480  ; Z = 228
    dc.w 18315,672
    dc.l 79694464  ; Z = 229
    dc.w 18236,3456
    dc.l 79692864  ; Z = 230
    dc.w 18157,2608
    dc.l 79691520  ; Z = 231
    dc.w 18078,1792
    dc.l 79695424  ; Z = 232
    dc.w 18001,1008
    dc.l 79692992  ; Z = 233
    dc.w 17924,256
    dc.l 79696704  ; Z = 234
    dc.w 17848,3296
    dc.l 79692992  ; Z = 235
    dc.w 17772,2624
    dc.l 79694144  ; Z = 236
    dc.w 17697,1984
    dc.l 79693696  ; Z = 237
    dc.w 17623,1376
    dc.l 79691840  ; Z = 238
    dc.w 17549,800
    dc.l 79693568  ; Z = 239
    dc.w 17476,256
    dc.l 79694656  ; Z = 240
    dc.w 17403,3600
    dc.l 79673024  ; Z = 241
    dc.w 17331,3136
    dc.l 79692992  ; Z = 242
    dc.w 17260,2704
    dc.l 79691968  ; Z = 243
    dc.w 17189,2304
    dc.l 79694912  ; Z = 244
    dc.w 17119,1936
    dc.l 79692992  ; Z = 245
    dc.w 17050,1600
    dc.l 79692032  ; Z = 246
    dc.w 16980,1296
    dc.l 79692352  ; Z = 247
    dc.w 16912,1024
    dc.l 79694272  ; Z = 248
    dc.w 16844,784
    dc.l 79692352  ; Z = 249
    dc.w 16777,576
    dc.l 79691520  ; Z = 250
    dc.w 16710,400
    dc.l 79692672  ; Z = 251
    dc.w 16644,256
    dc.l 79692480  ; Z = 252
    dc.w 16578,144
    dc.l 79693504  ; Z = 253
    dc.w 16513,64
    dc.l 79693056  ; Z = 254
    dc.w 16448,16
    dc.l 79693760  ; Z = 255
    dc.w 16384,0
    dc.l 79724480  ; Z = 256
    dc.w 16320,16
    dc.l 79693760  ; Z = 257
    dc.w 16256,64
    dc.l 79695808  ; Z = 258
    dc.w 16194,144
    dc.l 79691328  ; Z = 259
    dc.w 16131,256
    dc.l 79696000  ; Z = 260
    dc.w 16070,400
    dc.l 79691200  ; Z = 261
    dc.w 16008,576
    dc.l 79694528  ; Z = 262
    dc.w 15947,784
    dc.l 79695104  ; Z = 263
    dc.w 15887,1024
    dc.l 79693760  ; Z = 264
    dc.w 15827,1296
    dc.l 79693696  ; Z = 265
    dc.w 15768,1600
    dc.l 79689664  ; Z = 266
    dc.w 15709,1936
    dc.l 79691264  ; Z = 267
    dc.w 15650,2304
    dc.l 79694272  ; Z = 268
    dc.w 15592,2704
    dc.l 79692480  ; Z = 269
    dc.w 15534,3136
    dc.l 79693248  ; Z = 270
    dc.w 15477,3600
    dc.l 79692736  ; Z = 271
    dc.w 15420,4096
    dc.l 79694272  ; Z = 272
    dc.w 15363,256
    dc.l 79716032  ; Z = 273
    dc.w 15307,800
    dc.l 79694080  ; Z = 274
    dc.w 15252,1376
    dc.l 79690560  ; Z = 275
    dc.w 15196,1984
    dc.l 79693504  ; Z = 276
    dc.w 15141,2624
    dc.l 79694912  ; Z = 277
    dc.w 15087,3296
    dc.l 79693696  ; Z = 278
    dc.w 15033,4000
    dc.l 79693696  ; Z = 279
    dc.w 14979,256
    dc.l 79693952  ; Z = 280
    dc.w 14926,1008
    dc.l 79692544  ; Z = 281
    dc.w 14873,1792
    dc.l 79692864  ; Z = 282
    dc.w 14820,2608
    dc.l 79693120  ; Z = 283
    dc.w 14768,3456
    dc.l 79693248  ; Z = 284
    dc.w 14716,4336
    dc.l 79693504  ; Z = 285
    dc.w 14665,672
    dc.l 79693312  ; Z = 286
    dc.w 14614,1600
    dc.l 79692480  ; Z = 287
    dc.w 14563,2560
    dc.l 79697024  ; Z = 288
    dc.w 14513,3552
    dc.l 79691712  ; Z = 289
    dc.w 14463,4576
    dc.l 79690496  ; Z = 290
    dc.w 14413,976
    dc.l 79693696  ; Z = 291
    dc.w 14364,2048
    dc.l 79691840  ; Z = 292
    dc.w 14315,3152
    dc.l 79691392  ; Z = 293
    dc.w 14266,4288
    dc.l 79693056  ; Z = 294
    dc.w 14217,736
    dc.l 79695360  ; Z = 295
    dc.w 14169,1920
    dc.l 79694656  ; Z = 296
    dc.w 14122,3136
    dc.l 79691776  ; Z = 297
    dc.w 14074,4384
    dc.l 79694144  ; Z = 298
    dc.w 14027,880
    dc.l 79693824  ; Z = 299
    dc.w 13981,2176
    dc.l 79691776  ; Z = 300
    dc.w 13934,3504
    dc.l 79693376  ; Z = 301
    dc.w 13888,32
    dc.l 79693760  ; Z = 302
    dc.w 13842,1408
    dc.l 79693056  ; Z = 303
    dc.w 13797,2816
    dc.l 79693632  ; Z = 304
        section code,code

; ------------------------------------------------------------------------
; Planar rasterizer and span dispatch
; ------------------------------------------------------------------------

TB_R_PLANES equ 3

; Rasterize exact Q4 coverage on a 320 by 200 surface with three bitplanes.
; The polygon routines use the register interfaces below.

tb_r_sample_floor macro
        ext.l   d0
        addq.l  #7,d0
        asr.l   #4,d0
        endm

; Advance the surface pointer by 40 bytes for each row.
; The first argument is a row in 0..200. This macro changes it to 32 * row.
TB_ROW40_ADDRESS macro
        lsl.w   #3,\1
        adda.w  \1,\2
        add.w   \1,\1
        add.w   \1,\1
        adda.w  \1,\2
        endm

; Select a span writer once for each polygon.
; D7 is the ink. A0 is the surface base. Return the writer in A1.
; Each writer takes the row in A0 and the left and exclusive right X in
; D0.W and D1.W. All writers preserve D6-D7 and A2-A6.
tb_r_writer:
        btst    #8,d7
        bne.w   tb_r_choose_dither
        move.l  a0,d2
        btst    #0,d2
        bne.s   .odd
        move.w  d7,d2
        andi.w  #15,d2
        add.w   d2,d2
        lea     tb_r_colors(pc),a1
        move.w  (a1,d2.w),d2
        adda.w  d2,a1
        rts
.odd:
        lea     tb_r_bytes(pc),a1
        rts

; Use byte writes on odd addresses to prevent an address error.
tb_r_bytes:
        movem.l d6-d7/a2,-(sp)
        movea.l a0,a2
        move.w  d0,d2
        move.w  d1,d3
        sub.w   d2,d3
        subq.w  #1,d3
.one:
        move.w  d2,d0
        move.w  d2,d1
        lsr.w   #3,d0
        not.w   d1
        move.w  d7,d4
        lea     (a2,d0.w),a0
        moveq   #(TB_R_PLANES-1),d5
.plane:
        lsr.b   #1,d4
        bcc.s   .clear
        bset    d1,(a0)
        bra.s   .next
.clear:
        bclr    d1,(a0)
.next:
        lea     8000(a0),a0
        dbra    d5,.plane
        addq.w  #1,d2
        dbra    d3,.one
        movem.l (sp)+,d6-d7/a2
        rts

        ; Each entry holds the mask and the byte offset. The offset is the low word.
        ; Subtract 2 from the right offset so adjacent words give a zero distance.
        ; Use the exclusive right X as an index. The last valid index is 320.
tb_r_coord_table:
span_x set 0
        rept 321
        dc.w ($ffff>>(span_x&15)),((span_x>>4)<<1)
        ifeq span_x
        dc.w 0,-2                  ; The empty prefix has a seam offset of zero.
        else
        dc.w ($ffff<<(15-((span_x-1)&15)))&$ffff,(((span_x-1)>>4)<<1)-2
        endif
span_x set span_x+1
        endr

tb_r_colors:
        dc.w tb_r_color0-tb_r_colors,tb_r_color1-tb_r_colors
        dc.w tb_r_color2-tb_r_colors,tb_r_color3-tb_r_colors
        dc.w tb_r_color4-tb_r_colors,tb_r_color5-tb_r_colors
        dc.w tb_r_color6-tb_r_colors,tb_r_color7-tb_r_colors
        dc.w tb_r_color8-tb_r_colors,tb_r_color9-tb_r_colors
        dc.w tb_r_color10-tb_r_colors,tb_r_color11-tb_r_colors
        dc.w tb_r_color12-tb_r_colors,tb_r_color13-tb_r_colors
        dc.w tb_r_color14-tb_r_colors,tb_r_color15-tb_r_colors

; Generate one writer for each ink. Each writer uses a fixed operation for each plane.
; A one-word span uses a word mask. A two-word span uses a longword mask.
; Longer spans use two masked endpoints and paired longword stores.
; The row address is even. Argument 4 is the full destination address expression.
tb_r_lane macro
        ifne    (\1&\2)
        or.\3   d4,\4
        else
        and.\3  d5,\4
        endif
        endm

tb_r_middle macro
        ifne    (\1&\2)
        moveq   #-1,d4
        else
        moveq   #0,d4
        endif
        lea     \3+2(a0),a1
        ; Reuse D0 after the endpoint writes. Preserve the polygon walker's row count in D3.
        move.w  d2,d0
        lsr.w   #1,d0
        bcc.s   .even\@
        move.w  d4,(a1)+
.even\@:
        ; Select a suffix of the nine longword stores for at most 18 interior words.
        ; Each store occupies two code bytes. The byte displacement is -2 * the store count.
        add.w   d0,d0
        neg.w   d0
        jmp     .filled\@(pc,d0.w)
        rept 9
        move.l  d4,(a1)+
        endr
.filled\@:
        endm

TB_R_COLOR_INDEX_ENTRY equ 8

tb_r_color macro
        ; A0 holds the row. D0/D1 hold the endpoints. Clobber D2-D5.
.normal_x\@:
        lsl.w   #3,d0
        lsl.w   #3,d1
        lea     tb_r_coord_table(pc),a1
.index_x\@:
        ifne .index_x\@-.normal_x\@-TB_R_COLOR_INDEX_ENTRY
        fail "Solid painter index entry no longer matches the callback offset"
        endif
        move.l  (a1,d0.w),d4
        move.l  4(a1,d1.w),d5
        move.w  d4,d2
        adda.w  d2,a0
        move.w  d5,d1
        swap    d5
        sub.w   d2,d1
        beq.w   .adjacent\@
        bmi.w   .single\@
        ; A0 points to the first word. D1 holds the biased distance. D4/D5 hold the endpoint masks.
        ; Model inks 4 and 6 use this entry for spans longer than two words.
        ifeq (\1-4)*(\1-6)
tb_r_color_model_prepared\1 equ *
        endif
        cmpi.w  #2,d1
        beq.w   .three\@
        addq.w  #2,d1              ; Recover the actual distance.
        ; For a wide span, A0 points to the first word. D1 holds the actual byte distance.
        ; D4 holds the original packed left entry. D5.W holds the right prefix mask.
tb_r_color_wide\1 equ *
        swap    d4
        move.w  d5,d0              ; Keep the right mask during the left writes.
        move.w  d4,d5
        not.w   d5
        tb_r_lane \1,1,w,(a0)
        tb_r_lane \1,2,w,8000(a0)
        tb_r_lane \1,4,w,16000(a0)
        adda.w  d1,a0
        move.w  d0,d4
        move.w  d0,d5
        not.w   d5
        tb_r_lane \1,1,w,(a0)
        tb_r_lane \1,2,w,8000(a0)
        tb_r_lane \1,4,w,16000(a0)
        suba.w  d1,a0
        lsr.w   #1,d1
        subq.w  #1,d1
        move.w  d1,d2
        tb_r_middle \1,1,0
        tb_r_middle \1,2,8000
        tb_r_middle \1,4,16000
        lea     tb_r_coord_table(pc),a1  ; Restore the table after the wide write.
        rts
.single\@:
        swap    d4
        and.w   d5,d4
        move.w  d4,d5
        not.w   d5
        tb_r_lane \1,1,w,(a0)
        tb_r_lane \1,2,w,8000(a0)
        tb_r_lane \1,4,w,16000(a0)
        rts
.adjacent\@:
        move.w  d5,d4
        move.l  d4,d5
        not.l   d5
        tb_r_lane \1,1,l,(a0)
        tb_r_lane \1,2,l,8000(a0)
        tb_r_lane \1,4,l,16000(a0)
        rts
.three\@:
        ; Write the left endpoint and full middle word as a longword.
        ; Use a separate masked write for the right endpoint.
        move.w  d5,d0
        move.w  #-1,d4
        move.l  d4,d5
        not.l   d5
        tb_r_lane \1,1,l,(a0)
        tb_r_lane \1,2,l,8000(a0)
        tb_r_lane \1,4,l,16000(a0)
        move.w  d0,d4
        move.w  d0,d5
        not.w   d5
        tb_r_lane \1,1,w,4(a0)
        tb_r_lane \1,2,w,8004(a0)
        tb_r_lane \1,4,w,16004(a0)
        rts
        endm

tb_r_color0:  tb_r_color 0
tb_r_color1:  tb_r_color 1
tb_r_color2:  tb_r_color 2
tb_r_color3:  tb_r_color 3
tb_r_color4:  tb_r_color 4
tb_r_color5:  tb_r_color 5
tb_r_color6:  tb_r_color 6
tb_r_color7:  tb_r_color 7
tb_r_color8:  tb_r_color 8
tb_r_color9:  tb_r_color 9
tb_r_color10: tb_r_color 10
tb_r_color11: tb_r_color 11
tb_r_color12: tb_r_color 12
tb_r_color13: tb_r_color 13
tb_r_color14: tb_r_color 14
tb_r_color15: tb_r_color 15

; Accumulate the minimum and maximum crossings in one longword for each sampled row.
; This fallback supports non-monotone polygons and variable vertex counts.
tb_r_sum       equ -800
tb_r_surface   equ -804
tb_r_painter   equ -812
tb_r_minrow    equ -814
tb_r_endrow    equ -816
tb_r_view      equ -818
tb_r_edge_stop equ -820
tb_r_stepx     equ -824
tb_r_x         equ -832
tb_r_rem       equ -836
tb_r_edgelo    equ -838
tb_r_edgehi    equ -840
tb_r_edge_dy   equ -844
tb_r_top       equ -848
tb_r_draw_lane equ tb_r_top  ; Reuse the top slot after segment entry.
tb_r_base      equ -852
tb_r_limit     equ -856
tb_r_forward   equ -860
tb_r_back      equ -864
tb_r_fstop     equ -874
tb_r_bstop     equ -876
tb_r_fcorrect  equ -880
tb_r_bcorrect  equ -884
tb_r_seg_end   equ -888
tb_r_row       equ -890
tb_r_packed_ok equ -900
tb_r_inside_x  equ -906
tb_r_dither    equ -904

; ------------------------------------------------------------------------
; Screen-anchored dither writers
; ------------------------------------------------------------------------

; Bits 3:0 and 7:4 select the inks for even and odd (X + Y).
; Bit 8 selects dither. A0 advances 40 bytes for each row.
; Bit 3 of (row address XOR surface base) gives Y parity, also for odd bases.
tb_r_choose_dither:
        move.w  d7,d2
        andi.w  #$ff,d2
        lsl.w   #4,d2
        lea     tb_r_dither_patterns(pc),a1
        lea     (a1,d2.w),a1
        move.l  a1,tb_r_dither(a6)
        move.l  a0,d2
        btst    #0,d2
        bne.s   .odd
        move.w  d7,d2
        andi.w  #$ff,d2
        add.w   d2,d2
        lea     tb_r_dither_dispatch(pc),a1
        adda.w  (a1,d2.w),a1
        rts
.odd:
        lea     tb_r_dither_bytes(pc),a1
        rts

tb_r_dither_bytes:
        move.l  a0,d2
        move.l  tb_r_surface(a6),d3
        eor.w   d3,d2
        andi.w  #8,d2
        move.w  d0,d3
        andi.w  #1,d3
        lsl.w   #3,d3
        eor.w   d3,d2
        movem.l d6-d7/a2,-(sp)
        movea.l a0,a2
        move.l  tb_r_dither(a6),d7     ; Find the ink from its pattern address.
        lea     tb_r_dither_patterns(pc),a1
        sub.l   a1,d7
        lsr.w   #4,d7
        tst.w   d2
        beq.s   .phase
        ror.b   #4,d7
.phase:
        move.w  d0,d2
        move.w  d1,d3
        sub.w   d2,d3
        subq.w  #1,d3
.one:
        move.w  d2,d0
        move.w  d2,d1
        lsr.w   #3,d0
        not.w   d1
        move.w  d7,d4
        lea     (a2,d0.w),a0
        moveq   #(TB_R_PLANES-1),d5
.plane:
        lsr.b   #1,d4
        bcc.s   .clear
        bset    d1,(a0)
        bra.s   .next
.clear:
        bclr    d1,(a0)
.next:
        lea     8000(a0),a0
        dbra    d5,.plane
        ror.b   #4,d7
        addq.w  #1,d2
        dbra    d3,.one
        movem.l (sp)+,d6-d7/a2
        rts

; Use masked writes to preserve adjacent pixels. Store full interior words directly.
; Argument 2 is the full destination address expression.
tb_r_dither_lane macro
        move.w  (a1)+,d2
        ifc \1,l
        swap    d2
        move.w  -2(a1),d2
        endif
        and.\1  d4,d2
        move.\1 \2,d3
        and.\1  d5,d3
        or.\1   d2,d3
        move.\1 d3,\2
        endm

tb_r_dither_bounds macro
        lea     tb_r_coord_table(pc),a1
        lsl.w   #3,d0
        lsl.w   #3,d1
        move.l  (a1,d0.w),d4
        move.l  4(a1,d1.w),d5
        swap    d4
        move.l  d4,d2
        swap    d2
        adda.w  d2,a0
        move.w  d5,d3
        swap    d5
        sub.w   d2,d3
        endm

; Return zero or eight in D0 for the row phase.
tb_r_dither_phase macro
        ; Subtract the first word's byte offset in D2 to recover the row address in A0.
        move.l  a0,d0
        sub.w   d2,d0
        move.l  tb_r_surface(a6),d1
        eor.w   d1,d0
        andi.w  #8,d0
        endm

tb_r_dither_row:
        tb_r_dither_bounds
        movea.l tb_r_dither(a6),a1
        tb_r_dither_phase
        adda.w  d0,a1
        tst.w   d3
        beq.w   .adjacent_words
        bmi.s   .single_word
        bra.w   tb_r_dither_wide
.single_word:
        and.w   d5,d4
        move.w  d4,d5
        not.w   d5
        tb_r_dither_lane w,(a0)
        tb_r_dither_lane w,8000(a0)
        tb_r_dither_lane w,16000(a0)
        rts
.adjacent_words:
        swap    d4
        move.w  d5,d4
        move.l  d4,d5
        not.l   d5
        tb_r_dither_lane l,(a0)
        tb_r_dither_lane l,8000(a0)
        tb_r_dither_lane l,16000(a0)
        rts
tb_r_dither_wide:
        addq.w  #2,d3              ; Recover the actual distance.
        cmpi.w  #4,d3
        beq.w   .triple
        ; Reuse the masks and width for each plane. Keep the mask table in A1.
        ; Advance A0 by one plane size after each lane.
        move.l  d6,-(sp)
        moveq   #(TB_R_PLANES-1),d6
.plane:
        move.w  (a1)+,d1
        move.w  d4,d2
        not.w   d2
        and.w   (a0),d2
        move.w  d1,d0
        and.w   d4,d0
        or.w    d0,d2
        move.w  d2,(a0)
        move.w  d5,d2
        not.w   d2
        and.w   (a0,d3.w),d2
        move.w  d1,d0
        and.w   d5,d0
        or.w    d0,d2
        move.w  d2,(a0,d3.w)
        move.w  d3,d0
.middle:
        subq.w  #2,d0
        move.w  d1,(a0,d0.w)
        cmpi.w  #2,d0
        bne.s   .middle
        lea     8000(a0),a0
        dbra    d6,.plane
        move.l  (sp)+,d6
        rts
.triple:
        ; Write the left endpoint and full interior word as a longword.
        ; Keep the right endpoint in D0 until all plane writes are complete.
        move.w  d5,d0
        swap    d4
        move.w  #-1,d4
        move.l  d4,d5
        not.l   d5
        tb_r_dither_lane l,(a0)
        tb_r_dither_lane l,8000(a0)
        tb_r_dither_lane l,16000(a0)
        addq.l  #4,a0
        subq.l  #2*TB_R_PLANES,a1
        move.w  d0,d4
        move.w  d0,d5
        not.w   d5
        tb_r_dither_lane w,(a0)
        tb_r_dither_lane w,8000(a0)
        tb_r_dither_lane w,16000(a0)
        rts

; Use short-span writers for the selected terrain inks.
; Use the common writer for other inks and spans of three or more words.
; Argument 5 is the full destination address expression.
tb_r_dither_known_lane macro
        ifne (\1&\3)
        ifne (\2&\3)
        or.\4   d4,\5
        else
        move.\4 \5,d1
        and.\4  d5,d1
        or.\4   d2,d1
        move.\4 d1,\5
        endif
        else
        ifne (\2&\3)
        move.\4 \5,d1
        and.\4  d5,d1
        or.\4   d3,d1
        move.\4 d1,\5
        else
        and.\4  d5,\5
        endif
        endif
        endm

tb_r_dither_split macro
        move.\1 d4,d2
        ifc \1,l
        andi.l  #$aaaaaaaa,d2
        else
        andi.w  #$aaaa,d2
        endif
        move.\1 d4,d3
        eor.\1  d2,d3
        tst.w   d0
        beq.s   .even\@
        exg     d2,d3
.even\@:
        endm

tb_r_dither_known macro
        tb_r_dither_bounds
        tb_r_dither_phase
        tst.w   d3
        beq.s   .adjacent\@
        bmi.s   .single\@
        movea.l tb_r_dither(a6),a1
        adda.w  d0,a1
        bra.w   tb_r_dither_wide
.single\@:
        and.w   d5,d4
        move.w  d4,d5
        not.w   d5
        tb_r_dither_split w
        tb_r_dither_known_lane \1,\2,1,w,(a0)
        tb_r_dither_known_lane \1,\2,2,w,8000(a0)
        tb_r_dither_known_lane \1,\2,4,w,16000(a0)
        rts
.adjacent\@:
        swap    d4
        move.w  d5,d4
        move.l  d4,d5
        not.l   d5
        tb_r_dither_split l
        tb_r_dither_known_lane \1,\2,1,l,(a0)
        tb_r_dither_known_lane \1,\2,2,l,8000(a0)
        tb_r_dither_known_lane \1,\2,4,l,16000(a0)
        rts
        endm

tb_r_dither_b1: tb_r_dither_known TP_B1_EVEN,TP_B1_ODD
tb_r_dither_43: tb_r_dither_known TP_43_EVEN,TP_43_ODD
tb_r_dither_54: tb_r_dither_known TP_54_EVEN,TP_54_ODD
tb_r_dither_65: tb_r_dither_known TP_65_EVEN,TP_65_ODD
tb_r_dither_46: tb_r_dither_known TP_46_EVEN,TP_46_ODD
tb_r_dither_c7: tb_r_dither_known TP_C7_EVEN,TP_C7_ODD

        ; Generate fixed plane operations for the authored tank track inks.
tb_r_dither_40: tb_r_dither_known 0,4
tb_r_dither_42: tb_r_dither_known 2,4

tb_r_dither_dispatch:
tb_r_ink_select set 0
        rept 256
        ifeq (tb_r_ink_select-$40)
        dc.w tb_r_dither_40-tb_r_dither_dispatch
        else
        ifeq (tb_r_ink_select-$42)
        dc.w tb_r_dither_42-tb_r_dither_dispatch
        else
        ifeq (tb_r_ink_select-TP_B1_CODE)
        dc.w tb_r_dither_b1-tb_r_dither_dispatch
        else
        ifeq (tb_r_ink_select-TP_43_CODE)
        dc.w tb_r_dither_43-tb_r_dither_dispatch
        else
        ifeq (tb_r_ink_select-TP_54_CODE)
        dc.w tb_r_dither_54-tb_r_dither_dispatch
        else
        ifeq (tb_r_ink_select-TP_65_CODE)
        dc.w tb_r_dither_65-tb_r_dither_dispatch
        else
        ifeq (tb_r_ink_select-TP_46_CODE)
        dc.w tb_r_dither_46-tb_r_dither_dispatch
        else
        ifeq (tb_r_ink_select-TP_C7_CODE)
        dc.w tb_r_dither_c7-tb_r_dither_dispatch
        else
        dc.w tb_r_dither_row-tb_r_dither_dispatch
        endif
        endif
        endif
        endif
        endif
        endif
        endif
        endif
tb_r_ink_select set tb_r_ink_select+1
        endr

; Generate the entries from palette indices. Use four words for even Y,
; then four for odd Y. Keep the fourth word in the table stride.
; This renderer reads only the first three plane words for each phase.
tb_r_dither_patterns:
tb_r_ink set 0
        rept 256
tb_r_phase set $aaaa
        rept 2
tb_r_plane_bit set 1
        rept 4
tb_r_ink_word set 0
        ifne (tb_r_ink&tb_r_plane_bit)
tb_r_ink_word set tb_r_phase
        endif
        ifne (tb_r_ink&(tb_r_plane_bit<<4))
tb_r_ink_word set (tb_r_ink_word|($ffff^tb_r_phase))
        endif
        dc.w tb_r_ink_word
tb_r_plane_bit set tb_r_plane_bit<<1
        endr
tb_r_phase set $5555
        endr
tb_r_ink set tb_r_ink+1
        endr

; Private polygon interface: A0 points to Q4 vertices. D7.W holds the vertex count.
; D0 holds the ink. A6 points to the surface. Preserve A2, A5 and A6.
; The caller saves the outer face loop before clipping.
tb_span_poly_scene:
        moveq   #56,d1

tb_r_poly_reg:
        cmpi.w  #3,d7
        blo.w   tb_r_no_poly
        move.l  a6,d2
        link    a6,#-906
        movem.l a2/a5,-(sp)
        move.w  d1,tb_r_view(a6)
        move.l  d2,tb_r_surface(a6)
        movea.l a0,a5
        movea.l a0,a2
        move.l  a0,tb_r_base(a6)
        moveq   #0,d6
        move.w  d7,d6
        move.l  d0,d7

        ; D2/D3 hold the minimum and maximum Y. D4/D5 hold the minimum and maximum X.
        move.w  (a5),d4
        move.w  d4,d5
        move.w  2(a5),d2
        move.w  d2,d3
        lea     4(a5),a0
        move.l  d6,d0
        subq.l  #1,d0
.bounds:
        move.w  (a0)+,d1
        cmp.w   d4,d1
        bge.s   .no_min_x
        move.w  d1,d4
.no_min_x:
        cmp.w   d5,d1
        ble.s   .no_max_x
        move.w  d1,d5
.no_max_x:
        move.w  (a0)+,d1
        cmp.w   d2,d1
        bge.s   .no_min_y
        move.w  d1,d2
        lea     -4(a0),a2
.no_min_y:
        cmp.w   d3,d1
        ble.s   .no_max_y
        move.w  d1,d3
.no_max_y:
        subq.l  #1,d0
        bne.s   .bounds
        move.l  a2,tb_r_top(a6)
        move.l  a0,tb_r_limit(a6)
        ; Use floor((interpolated X + 8 - epsilon) / 16) to sample X.
        ; Endpoints in [-7,5128] keep both chains in 0..320 pixels.
        ; Only the fused solid loop uses the inside flag.
        clr.b   tb_r_inside_x(a6)
        cmpi.w  #-7,d4
        blt.s   .edge_clip
        cmpi.w  #5128,d5
        sle     tb_r_inside_x(a6)
.edge_clip:
        clr.w   tb_r_packed_ok(a6)
        cmpi.w  #-16000,d4
        blt.s   .skip_fast
        cmpi.w  #16000,d5
        bgt.s   .skip_fast
        move.w  d3,d0
        sub.w   d2,d0
        bmi.s   .skip_fast
        move.w  #1,tb_r_packed_ok(a6)
.skip_fast:
        move.w  d2,d0
        tb_r_sample_floor
        cmp.w   tb_r_view(a6),d0
        bge.s   .min_visible
        move.w  tb_r_view(a6),d0
.min_visible:
        move.w  d0,tb_r_minrow(a6)
        move.w  d3,d0
        tb_r_sample_floor
        cmpi.w  #200,d0
        ble.s   .end_visible
        move.w  #200,d0
.end_visible:
        move.w  d0,tb_r_endrow(a6)
        cmp.w   tb_r_minrow(a6),d0
        ble.w   .reject

        movea.l tb_r_surface(a6),a0
        bsr.w   tb_r_writer
        move.l  a1,tb_r_painter(a6)
        tst.w   tb_r_packed_ok(a6)
        beq.s   .general
        move.l  tb_r_surface(a6),d0
        btst    #0,d0
        bne.s   .general
        ; A positive sampled height excludes a flat triangle.
        cmpi.w  #3,d6
        beq.s   .fused
        cmpi.w  #4,d6
        bne.s   .generic_monotone

        ; A cyclic quad is not Y-monotone if the vertex opposite the first minimum
        ; has a strictly smaller Y than both its neighbours.
        ; Rotate the four vertex offsets to start at the first minimum.
        movea.l tb_r_base(a6),a0
        move.l  tb_r_top(a6),d0
        sub.l   a0,d0
        eori.w  #8,d0
        move.w  2(a0,d0.w),d1       ; Load Y opposite the minimum.
        addq.w  #4,d0
        andi.w  #12,d0
        cmp.w   2(a0,d0.w),d1
        bge.s   .fused
        eori.w  #8,d0
        cmp.w   2(a0,d0.w),d1
        blt.s   .general
        bra.s   .fused
.generic_monotone:
        bsr.w   tb_r_monotone
        tst.w   d0
        beq.s   .general
.fused:
        bsr.w   tb_r_fused
        bra.w   .success
.general:
        lea     tb_r_sum(a6),a0
        move.w  tb_r_minrow(a6),d0
        lsl.w   #2,d0
        adda.w  d0,a0
        move.w  tb_r_endrow(a6),d0
        sub.w   tb_r_minrow(a6),d0
        subq.w  #1,d0
        move.l  #$7fff8000,d1
.init_rows:
        move.l  d1,(a0)+
        dbra    d0,.init_rows
        movea.l a5,a4
        subq.l  #1,d6
.edges:
        movea.l a4,a0
        addq.l  #4,a4
        movea.l a4,a1
        bsr.w   tb_r_accumulate
        subq.l  #1,d6
        bne.s   .edges
        movea.l a4,a0
        movea.l a5,a1
        bsr.w   tb_r_accumulate
        movea.l tb_r_surface(a6),a4
        move.w  tb_r_minrow(a6),d0
        TB_ROW40_ADDRESS d0,a4
        lea     tb_r_sum(a6),a5
        move.w  tb_r_minrow(a6),d0
        lsl.w   #2,d0
        adda.w  d0,a5
        move.w  tb_r_endrow(a6),d6
        sub.w   tb_r_minrow(a6),d6
        subq.w  #1,d6
        movea.l tb_r_painter(a6),a3
.draw:
        move.w  (a5)+,d0
        move.w  (a5)+,d1
        tst.w   d0
        bpl.s   .clip_hi
        moveq   #0,d0
.clip_hi:
        cmpi.w  #320,d1
        ble.s   .visible
        move.w  #320,d1
.visible:
        cmp.w   d0,d1
        ble.s   .skip
        movea.l a4,a0
        jsr     (a3)
.skip:
        lea     40(a4),a4
        dbra    d6,.draw
.success:
        moveq   #1,d0
        bra.s   .return
.reject:
        moveq   #0,d0
.return:
        movea.l (sp)+,a2
        movea.l (sp)+,a5
        unlk    a6
        rts

tb_r_no_poly:
        moveq   #0,d0
        rts

; A0 and A1 point to the edge endpoints in either order.
; Clobber D0-D5 and A0-A3. Preserve the outer edge iteration registers.
tb_r_accumulate:
        move.w  2(a0),d0
        move.w  2(a1),d1
        cmp.w   d0,d1
        beq.w   .done
        bgt.s   .sorted
        exg     a0,a1
        exg     d0,d1
.sorted:
        move.w  d0,tb_r_edgelo(a6)
        move.w  d1,tb_r_edgehi(a6)
        sub.w   d0,d1
        andi.l  #$ffff,d1
        move.l  d1,tb_r_edge_dy(a6)
        move.w  tb_r_edgehi(a6),d0
        tb_r_sample_floor
        cmp.w   tb_r_endrow(a6),d0
        ble.s   .set_stop
        move.w  tb_r_endrow(a6),d0
.set_stop:
        move.w  d0,tb_r_edge_stop(a6)
        move.w  tb_r_edgelo(a6),d0
        tb_r_sample_floor
        cmp.w   tb_r_minrow(a6),d0
        bge.s   .set_start
        move.w  tb_r_minrow(a6),d0
.set_start:
        move.w  tb_r_edge_stop(a6),d5
        sub.w   d0,d5
        ble.w   .done
        subq.w  #1,d5
        lea     tb_r_sum(a6),a2
        move.w  d0,d2
        lsl.w   #2,d2
        adda.w  d2,a2

        ; Compute x0 * (dy - sample) + x1 * sample with unsigned weights.
        ; Correct MULS for unsigned weights over the full signed 16-bit coordinate range.
        lsl.w   #4,d0
        addq.w  #8,d0
        sub.w   tb_r_edgelo(a6),d0
        move.w  (a0),d3
        move.w  (a1),d4
        move.w  d1,d2
        sub.w   d0,d2
        move.w  d2,d1
        muls.w  d3,d2
        tst.w   d1
        bpl.s   .left_product
        move.w  d3,d1
        swap    d1
        clr.w   d1
        add.l   d1,d2
.left_product:
        move.w  d0,d1
        muls.w  d4,d0
        tst.w   d1
        bpl.s   .right_product
        move.w  d4,d1
        swap    d1
        clr.w   d1
        add.l   d1,d0
.right_product:
        add.l   d2,d0
        move.l  tb_r_edge_dy(a6),d1
        bsr.w   tb_r_div_floor
        addq.l  #8,d0
        subq.l  #1,d2
        bpl.s   .bias
        add.l   d1,d2
        subq.l  #1,d0
.bias:
        move.l  d0,tb_r_x(a6)
        move.l  d2,tb_r_rem(a6)
        ; Skip the Y step for one sampled row. With two or more rows, dy > 16.
        ; With abs(dx) <= 65535, the DIVU quotient then fits in a word.
        tst.w   d5
        beq.s   .single
        ext.l   d4
        ext.l   d3
        move.l  d4,d0
        sub.l   d3,d0
        lsl.l   #4,d0
        bsr.w   tb_r_div_floor
        move.l  d0,tb_r_stepx(a6)
        move.l  d2,d4
        move.l  tb_r_x(a6),d3
        move.l  tb_r_rem(a6),d2
.loop:
        move.l  d3,d0
        asr.l   #4,d0
        cmp.w   (a2),d0
        bge.s   .left
        move.w  d0,(a2)
.left:
        cmp.w   2(a2),d0
        ble.s   .right
        move.w  d0,2(a2)
.right:
        addq.l  #4,a2
        add.l   tb_r_stepx(a6),d3
        add.l   d4,d2
        cmp.l   d1,d2
        blo.s   .advanced
        sub.l   d1,d2
        addq.l  #1,d3
.advanced:
        dbra    d5,.loop
.done:
        rts
.single:
        asr.l   #4,d0
        cmp.w   (a2),d0
        bge.s   .single_hi
        move.w  d0,(a2)
.single_hi:
        cmp.w   2(a2),d0
        ble.s   .done
        move.w  d0,2(a2)
        rts

; D0 is the signed numerator. D1 is a positive unsigned word denominator.
; Return the floor quotient in D0.L and the nonnegative remainder in D2.L.
; The caller's convex blend or multi-row step keeps the DIVU quotient in range.
tb_r_div_floor:
        tst.l   d0
        bmi.s   .negative
        divu.w  d1,d0
        moveq   #0,d2
        swap    d0
        move.w  d0,d2
        clr.w   d0
        swap    d0
        rts
.negative:
        neg.l   d0
        divu.w  d1,d0
        moveq   #0,d2
        swap    d0
        move.w  d0,d2
        clr.w   d0
        swap    d0
        neg.l   d0
        tst.w   d2
        beq.s   .done
        neg.l   d2
        add.l   d1,d2
        subq.l  #1,d0
.done:
        rts

; The fast path needs exactly two cyclic Y direction changes.
; Equal Y values do not start or stop a chain.
; Use minimum and maximum accumulation for non-monotone faces.
tb_r_monotone:
        ; Start at the known first minimum. The caller excludes a flat interval.
        ; A rise after the first strict fall is a third cyclic direction change.
        ; Ignore equal Y values.
        movea.l tb_r_top(a6),a0
        movea.l tb_r_limit(a6),a1
        move.w  d6,d4
        subq.w  #2,d4
        move.w  2(a0),d1
        addq.l  #4,a0
.rising:
        cmpa.l  a1,a0
        bne.s   .read_up
        movea.l tb_r_base(a6),a0
.read_up:
        move.w  2(a0),d0
        addq.l  #4,a0
        cmp.w   d1,d0
        blt.s   .first_fall
        move.w  d0,d1
        dbra    d4,.rising
.accept:
        moveq   #-1,d0
        rts
.first_fall:
        move.w  d0,d1
        dbra    d4,.falling
        bra.s   .accept
.falling:
        cmpa.l  a1,a0
        bne.s   .read_down
        movea.l tb_r_base(a6),a0
.read_down:
        move.w  2(a0),d0
        addq.l  #4,a0
        cmp.w   d1,d0
        bgt.s   .reject
        move.w  d0,d1
        dbra    d4,.falling
        bra.s   .accept
.reject:
        moveq   #0,d0
        rts

tb_r_advance_pair macro
        ; Use the sign of the longword sum to test the sign of the biased remainder.
        add.l   a2,d6
        bpl.s   .step_back\@
        add.l   tb_r_fcorrect(a6),d6
.step_back\@:
        add.l   a3,d7
        bpl.s   .step_done\@
        add.l   tb_r_bcorrect(a6),d7
.step_done\@:
        lea     40(a4),a4
        ifc '\1','reg_end'
        cmpa.l  a5,a4
        else
        ifnc '\1','solid_count'
        cmpa.l  tb_r_seg_end(a6),a4
        endif
        endif
        endm

; A4 points to the current row. Select the ink once for each segment.
; Keep the coordinate table and the segment end live across rows.
tb_r_solid_model macro
        lea     tb_r_coord_table(pc),a1
        movea.l a0,a5               ; Keep the exclusive segment end.
.model_row\@:
        move.l  d6,d0
        move.l  d7,d1
        ; The inside guard makes the biased sample nonnegative.
        ; Quantize and scale together: floor(Xq4 / 16) * 8 = (Xq4 AND $fff0) / 2.
        andi.w  #$7ff0,d0
        andi.w  #$7ff0,d1
        lsr.w   #1,d0
        lsr.w   #1,d1
        cmp.w   d0,d1
        beq.w   .model_step\@
        bgt.s   .model_ordered\@
        exg     d0,d1
.model_ordered\@:
        move.l  (a1,d0.w),d4
        move.l  4(a1,d1.w),d5
        move.w  d4,d2
        move.w  d5,d3
        swap    d5
        sub.w   d2,d3
        movea.l a4,a0
        beq.s   .model_two\@
        bmi.s   .model_one\@
        adda.w  d2,a0
        move.w  d3,d1              ; Keep the existing width bias.
        bsr.w   tb_r_color_model_prepared\1
        ; The three-word writer preserves A1. The wide writer restores A1.
        bra.s   .model_step\@
.model_one\@:
        adda.w  d2,a0
        swap    d4
        and.w   d5,d4
        move.w  d4,d5
        not.w   d5
        tb_r_lane \1,1,w,(a0)
        tb_r_lane \1,2,w,8000(a0)
        tb_r_lane \1,4,w,16000(a0)
        bra.s   .model_step\@
.model_two\@:
        adda.w  d2,a0
        move.w  d5,d4
        move.l  d4,d5
        not.l   d5
        tb_r_lane \1,1,l,(a0)
        tb_r_lane \1,2,l,8000(a0)
        tb_r_lane \1,4,l,16000(a0)
.model_step\@:
        tb_r_advance_pair reg_end
        blo.w   .model_row\@
        movea.l tb_r_painter(a6),a5
        bra.w   .next_segment
        endm

tb_r_inside_endpoints macro
        ; The backward edge is usually on the left.
        ; Handle both windings and empty rows. Keep the right endpoint exclusive.
        move.l  d7,d0
        move.l  d6,d1
        ifc '\3','index'
        ; The inside guard makes Xq4 nonnegative. Compute floor(Xq4 / 16) * 8.
        andi.w  #$7ff0,d0
        andi.w  #$7ff0,d1
        lsr.w   #1,d0
        lsr.w   #1,d1
        else
        add.w   d0,d0
        add.w   d1,d1
        lsr.w   #5,d0
        lsr.w   #5,d1
        endif
        cmp.w   d0,d1
        bgt.s   \1
        beq.s   \2
        exg     d0,d1
        endm

tb_r_make_seg_end macro
        move.w  d0,tb_r_row(a6)
        movea.l tb_r_surface(a6),a0
        TB_ROW40_ADDRESS d0,a0
        endm

; D6/D7 hold [signed Xq4 | remainder + 32768 - dy]. A2/A3 hold the packed steps.
; For 1 <= dy <= 32767, the step cannot carry out of the low word.
; Its sign bit becomes set when the remainder needs correction.
; Add 65536 - dy to correct the remainder and increment X.
; The typed path instead uses [remainder + 32768 - dy | Xq4 + 32768].
; It adds a signed step and uses correction 1 - (dy << 16).
; The chain produces this representation directly.
        ; A0 points to the top vertex. D0.W is the first row. D7 is the ink.
        ; A4 points to the page. Save only the active state of the shared edge walker.
        macro TB_R_FUSED_START
        btst    #8,d7
        beq.s   .plain_painter\@
        neg.b   tb_r_inside_x(a6)
.plain_painter\@:
        move.l  a0,tb_r_forward(a6)
        move.l  a0,tb_r_back(a6)
        move.w  d0,tb_r_row(a6)
        move.w  d0,tb_r_fstop(a6)
        move.w  d0,tb_r_bstop(a6)
        TB_ROW40_ADDRESS d0,a4
        endm

tb_r_fused:
        movea.l tb_r_top(a6),a0
        move.w  tb_r_minrow(a6),d0
        movea.l tb_r_surface(a6),a4
        movea.l tb_r_painter(a6),a5
        TB_R_FUSED_START
tb_r_fused_segment:
        ; A4 points to the current row. A5 holds the writer.
        ; Both chains start at the first shared row and use the same walker.
        ; Keep the writer and its inside/dither classification when a chain restarts.
        tst.b   tb_r_inside_x(a6)
        beq.s   .choose_colour
        bpl.s   .choose_inside
        lea     tb_r_color4(pc),a1
        cmpa.l  a1,a5
        beq.s   .choose_model4
        lea     tb_r_color6(pc),a1
        cmpa.l  a1,a5
        beq.s   .choose_model6
        lea     .solid_prep(pc),a1
        bra.s   .lane_ready
.choose_colour:
        lea     .colour_prep(pc),a1
        bra.s   .lane_ready
.choose_inside:
        lea     .inside_prep(pc),a1
        bra.s   .lane_ready
.choose_model4:
        lea     .model_color4(pc),a1
        bra.s   .lane_ready
.choose_model6:
        lea     .model_color6(pc),a1
.lane_ready:
        move.l  a1,tb_r_draw_lane(a6)
.segment:
        move.w  tb_r_row(a6),d0
.segment_row_ready:
.begin_forward:
        ; Both stops initially equal the current row.
        ; A segment tail chooses which edge to restart.
        movea.l tb_r_forward(a6),a0
        move.w  d0,d2
        bsr.w   tb_r_chain_edge_forward
        move.l  a0,tb_r_forward(a6)
        move.l  d0,d6
        movea.l d1,a2
        move.w  d3,tb_r_fstop(a6)
        move.l  d2,tb_r_fcorrect(a6)
        move.w  tb_r_row(a6),d0      ; Reload the row after the forward call.
.reverse_row_ready:
        cmp.w   tb_r_bstop(a6),d0
        bne.s   .segment_end
.begin_backward:
        movea.l tb_r_back(a6),a0
        move.w  d0,d2
        bsr.w   tb_r_chain_edge_back
        move.l  a0,tb_r_back(a6)
        move.l  d0,d7
        movea.l d1,a3
        move.w  d3,tb_r_bstop(a6)
        move.l  d2,tb_r_bcorrect(a6)
.segment_end:
        move.w  tb_r_fstop(a6),d0
        cmp.w   tb_r_bstop(a6),d0
        ble.s   .finish
        move.w  tb_r_bstop(a6),d0
.finish:
        movea.l tb_r_draw_lane(a6),a1
        jmp     (a1)
.solid_prep:
        move.w  d0,d3
        sub.w   tb_r_row(a6),d3
        subq.w  #1,d3               ; The solid writer preserves the row count.
        move.w  d0,tb_r_row(a6)
        lea     tb_r_coord_table(pc),a1
        addq.l  #TB_R_COLOR_INDEX_ENTRY,a5
.solid_inside:
        tb_r_inside_endpoints .solid_ordered,.solid_step,index
.solid_ordered:
        movea.l a4,a0
        jsr     (a5)
.solid_step:
        tb_r_advance_pair solid_count
        dbra    d3,.solid_inside
        subq.l  #TB_R_COLOR_INDEX_ENTRY,a5
        bra.w   .next_segment
.inside_prep:
        tb_r_make_seg_end
        move.l  a0,tb_r_seg_end(a6) ; The dither writer changes D3.
.inside:
        tb_r_inside_endpoints .inside_ordered,.inside_step
.inside_ordered:
        movea.l a4,a0
        jsr     (a5)
.inside_step:
        tb_r_advance_pair
        blo.s   .inside
        bra.w   .next_segment
.colour_prep:
        tb_r_make_seg_end
        move.l  a0,tb_r_seg_end(a6)
.colour:
        move.l  d6,d0
        move.l  d7,d1
        eori.w  #$8000,d0
        eori.w  #$8000,d1
        asr.w   #4,d0
        asr.w   #4,d1
        cmp.w   d0,d1
        bge.s   .colour_left
        exg     d0,d1
.colour_left:
        tst.w   d0
        bpl.s   .colour_right
        moveq   #0,d0
.colour_right:
        cmpi.w  #320,d1
        ble.s   .visible
        move.w  #320,d1
.visible:
        cmp.w   d0,d1
        ble.s   .colour_step
        movea.l a4,a0
        jsr     (a5)
.colour_step:
        tb_r_advance_pair
        blo.s   .colour
.next_segment:
        move.w  tb_r_row(a6),d0
        cmp.w   tb_r_endrow(a6),d0
        bhs.s   .end_polygon
        cmp.w   tb_r_fstop(a6),d0
        bne.w   .begin_backward
        bra.w   .begin_forward
.end_polygon:
        rts
.model_color4:
        tb_r_make_seg_end
        tb_r_solid_model 4
.model_color6:
        tb_r_make_seg_end
        tb_r_solid_model 6

; Pack the corrected DIVS result as [nonnegative remainder | signed floor quotient].
; The first sample lies within the edge. The X guard bounds its quotient to +/-32001.
; Two sampled rows imply dy >= 17 and bound the step quotient to +/-30118.
; The general accumulator uses DIVU.
TB_R_PACKED_EDGE_DIV macro
        divs.w  d1,d0
        tst.l   d0
        bpl.s   .nonnegative\@
        subq.w  #1,d0
        swap    d0
        add.w   d1,d0
        swap    d0
.nonnegative\@:
        endm

; A0 points to the previous vertex. D2.W holds the current row.
; Each direction entry walks the packed Q4 vertices in its own direction.
; Return the next vertex in A0, packed X and remainder in D0, packed step in D1,
; correction in D2 and stop row in D3. Preserve D6-D7 and A2-A5 for the other edge.
tb_r_chain_edge_forward:
        moveq   #4,d5
        ; Only a Y after the current pixel centre can reach a later sample row.
        move.w  d2,d3
        lsl.w   #4,d3
        addq.w  #8,d3
tb_r_chain_forward_walk:
        lea     4(a0),a1
        cmpa.l  tb_r_limit(a6),a1
        blo.s   tb_r_chain_bounds
        movea.l tb_r_base(a6),a1
        bra.s   tb_r_chain_bounds
tb_r_chain_edge_back:
        moveq   #-4,d5
        move.w  d2,d3
        lsl.w   #4,d3
        addq.w  #8,d3
tb_r_chain_back_walk:
        lea     -4(a0),a1
        cmpa.l  tb_r_base(a6),a1
        bhs.s   tb_r_chain_bounds
        movea.l tb_r_limit(a6),a1
        subq.l  #4,a1
tb_r_chain_bounds:
        move.w  2(a1),d1
        cmp.w   d3,d1              ; Test (Y + 7) >> 4 > row.
        bgt.s   .active
        movea.l a1,a0
        tst.w   d5
        bpl.s   tb_r_chain_forward_walk
        bra.s   tb_r_chain_back_walk
.active:
        ; D3 holds the nonnegative sample Y. Only Y > D3 reaches this code.
        ; Y + 7 fits in an unsigned word, including when Y is $7fff.
        move.w  d1,d0
        addq.w  #7,d0
        lsr.w   #4,d0
        cmp.w   tb_r_endrow(a6),d0
        ble.s   .stop
        move.w  tb_r_endrow(a6),d0
.stop:
        exg     d0,d3              ; Put the sampled Y in D0 and stop row in D3.
        sub.w   d3,d2              ; Keep the negative row count until the step test.
        move.w  2(a0),d5           ; Reuse D5 for Y0, which gives dy and phase.
        sub.w   d5,d1              ; Compute positive dy.
        sub.w   d5,d0              ; The first sample offset is in [0, dy).
        move.w  (a0),d4
        move.w  (a1),d5
        sub.w   d4,d5              ; The X limits keep dx within a signed word.
        addi.w  #$8008,d4          ; Apply the unsigned bias and sample offset.
        tst.w   d5
        beq.s   .integral_start
        tst.w   d0
        beq.s   .integral_start
        muls.w  d5,d0
        subq.l  #1,d0
        TB_R_PACKED_EDGE_DIV
        add.w   d4,d0
        move.l  d0,d4
        cmpi.w  #-1,d2
        beq.s   .single
.step:
        move.w  d5,d0
        ext.l   d0
        lsl.l   #4,d0
        ; Pack the result as (nonnegative remainder << 16) + signed quotient.
        divs.w  d1,d0
        tst.l   d0
        bmi.s   .negative_remainder
        tst.w   d0
        bpl.s   .done
        subi.l  #$10000,d0        ; Cancel the borrow from the signed quotient.
        bra.s   .done
.negative_remainder:
        swap    d0
        subq.w  #1,d0
        add.w   d1,d0
        swap    d0
        subq.w  #1,d0
        bra.s   .done
.integral_start:
        subq.w  #1,d4             ; Use floor(-1 / dy) = -1 and remainder dy - 1.
        swap    d4
        move.w  d1,d4
        subq.w  #1,d4
        swap    d4
        tst.w   d5
        beq.s   .single
        cmpi.w  #-1,d2
        bne.s   .step
.single:
        moveq   #0,d0
.done:
        ; Return [remainder + 32768 - dy | X + 32768], with 1 <= dy <= 32767.
        swap    d4
        sub.w   d1,d4
        eori.w  #$8000,d4
        swap    d4
        move.w  d1,d2
        neg.w   d2
        swap    d2
        move.w  #1,d2             ; Set the correction to 1 - (dy << 16).
        move.l  d0,d1
        move.l  d4,d0
        movea.l a1,a0
        rts

; ------------------------------------------------------------------------
; Terrain quad edge walker and span dispatch
; ------------------------------------------------------------------------

; Rasterize the regular terrain lattice without changing the producer or painter order.
; Use the general renderer for geometry outside the fast path limits.
; Ordinals 0, 2, 4 and 6 index the source offsets in winding order.

; ------------------------------------------------------------------------
; Terrain solid span writers
; ------------------------------------------------------------------------

tb_q_solid_step macro
        add.l   a2,d6
        add.l   a3,d7
        lea     40(a4),a4
        dbra    d3,\1
        rts
        endm

; D6/D7 hold the two Q16 edge states. A2/A3 hold their increments.
; A4 points to the first row and D3 holds the row count minus one.
; Keep the coordinate table live. A5 retains the logical next row.
; Each material has fixed set and clear operations for the three planes.
; One- and two-word spans account for most rows. Give each a local loop tail
; to avoid a branch on both common paths.
tb_q_solid macro
        lea     tb_r_coord_table(pc),a1
.solid_row\@:
        ; The backward edge is usually on the left. Compare both edges and swap
        ; only for the opposite winding.
        move.l  d7,d0
        move.l  d6,d1
        swap    d0
        swap    d1
        cmp.w   d0,d1
        bhi.s   .solid_ordered\@
        beq.w   .solid_step\@
        exg     d0,d1
.solid_ordered\@:
        lsl.w   #3,d0
        lsl.w   #3,d1
        move.l  (a1,d0.w),d4
        move.l  4(a1,d1.w),d5
        movea.l a4,a0
        adda.w  d4,a0
        sub.w   d4,d5              ; Compute the physical word separation.
        beq.s   .solid_two\@
        bmi.s   .solid_one\@
        subq.w  #2,d5
        beq.s   .solid_three\@
        ifeq (\1-2)*(\1-5)*(\1-6)
        subq.w  #2,d5
        beq.w   .solid_four\@
        endif
        ifeq (\1-2)*(\1-5)
        subq.w  #2,d5
        beq.w   .solid_five\@
        subq.w  #2,d5
        beq.w   .solid_six\@
        endif
        ; The width tests leave the tested bias in D5.W. Both table layouts put the
        ; right mask in D5.H. Join the endpoint and interior writer after its width tests.
        move.w  d5,d1
        ifeq (\1-2)*(\1-5)
        addi.w  #10,d1
        else
        ifeq \1-6
        addq.w  #6,d1
        else
        addq.w  #4,d1
        endif
        endif
        swap    d5
        ; The packed wide writer preserves D3 and restores A1.
        bsr.w   tb_r_color_wide\1
        bra.s   .solid_step\@
.solid_one\@:
        swap    d4
        swap    d5
        and.w   d5,d4
        move.w  d4,d5
        not.w   d5
        tb_q_solid_lanes \1,w,0,d5
        tb_q_solid_step .solid_row\@
.solid_two\@:
        swap    d5
        move.w  d5,d4
        move.l  d4,d5
        not.l   d5
        tb_q_solid_lanes \1,l,0,d5
        tb_q_solid_step .solid_row\@
.solid_three\@:
        ; Keep the right prefix mask in D5 while D2 complements the first longword.
        move.w  #-1,d4
        move.l  d4,d2
        not.l   d2
        tb_q_solid_lanes \1,l,0,d2
        swap    d5
        move.w  d5,d4
        not.w   d5
        tb_q_solid_lanes \1,w,4,d5
.solid_step\@:
        tb_q_solid_step .solid_row\@
        ifeq (\1-2)*(\1-5)*(\1-6)
.solid_four\@:
        ; Keep the right prefix mask until the second [full word, prefix] write.
        move.w  #-1,d4
        move.l  d4,d2
        not.l   d2
        tb_q_solid_lanes \1,l,0,d2
        swap    d5
        swap    d4
        move.w  d5,d4
        move.l  d4,d5
        not.l   d5
        tb_q_solid_lanes \1,l,4,d5
        tb_q_solid_step .solid_row\@
        endif
        ifeq (\1-2)*(\1-5)
.solid_five\@:
        tb_q_solid_mid_caps \1,w,6
        tb_q_solid_step .solid_row\@
.solid_six\@:
        tb_q_solid_mid_caps \1,l,8
        tb_q_solid_step .solid_row\@
        endif
        endm

; Argument 4 is the full destination address expression.
tb_q_solid_lane macro
        ifne    (\1&\2)
        or.\3   d4,\4
        else
        and.\3  \5,\4
        endif
        endm

tb_q_solid_lanes macro
        ifne \3
        tb_q_solid_lane \1,1,\2,\3(a0),\4
        else
        tb_q_solid_lane \1,1,\2,(a0),\4
        endif
        tb_q_solid_lane \1,2,\2,8000+\3(a0),\4
        tb_q_solid_lane \1,4,\2,16000+\3(a0),\4
        endm

; For five or six words, write [suffix, full word] and [full word, prefix],
; with one or two full interior words between. Use the known width to select
; the instruction size and right endpoint offset at assembly time.
tb_q_solid_mid_caps macro
        move.w  #-1,d4
        move.l  d4,d2
        not.l   d2
        tb_q_solid_lanes \1,l,0,d2
        moveq   #0,d0
        moveq   #-1,d2
        ifne \1&1
        move.\2 d2,4(a0)
        else
        move.\2 d0,4(a0)
        endif
        ifne \1&2
        move.\2 d2,8004(a0)
        else
        move.\2 d0,8004(a0)
        endif
        ifne \1&4
        move.\2 d2,16004(a0)
        else
        move.\2 d0,16004(a0)
        endif
        swap    d5
        swap    d4
        move.w  d5,d4
        move.l  d4,d5
        not.l   d5
        tb_q_solid_lanes \1,l,\3,d5
        endm

tb_q_solid0:  tb_q_solid 0
tb_q_solid1:  tb_q_solid 1
tb_q_solid2:  tb_q_solid 2
tb_q_solid3:  tb_q_solid 3
tb_q_solid4:  tb_q_solid 4
tb_q_solid5:  tb_q_solid 5
tb_q_solid6:  tb_q_solid 6
tb_q_solid7:  tb_q_solid 7

tb_q_solid_table:
        dc.w tb_q_solid0-tb_q_paint_base,tb_q_solid1-tb_q_paint_base
        dc.w tb_q_solid2-tb_q_paint_base,tb_q_solid3-tb_q_paint_base
        dc.w tb_q_solid4-tb_q_paint_base,tb_q_solid5-tb_q_paint_base
        dc.w tb_q_solid6-tb_q_paint_base,tb_q_solid7-tb_q_paint_base
; Index the table of word displacements by scanline or segment height.
tb_q_row_offsets:
tb_q_row_n set 0
        rept 201
        dc.w tb_q_row_n*40
tb_q_row_n set tb_q_row_n+1
        endr
tb_q_add_rows macro
        add.w   \1,\1
        lea     tb_q_row_offsets(pc),a1
        adda.w  (a1,\1.w),\2
        endm

tb_q_frame_painter  equ -4
tb_q_frame_base     equ -8
tb_q_frame_endrow   equ -10
; Keep the two words adjacent. Put the backward word first.
tb_q_frame_fstop    equ -12
tb_q_frame_bstop    equ -14
tb_q_frame_fcorrect equ -18
tb_q_frame_bcorrect equ -22

        ; The first four words select the starting corner.
        ; The repeated three-word tail lets each cursor finish without wrapping.
tb_q_forward_offsets:
        dc.w 0,SC_GRID_WIDTH*8,(SC_GRID_WIDTH+1)*8,8
        dc.w 0,SC_GRID_WIDTH*8,(SC_GRID_WIDTH+1)*8
tb_q_reverse_offsets:
        dc.w 0,8,(SC_GRID_WIDTH+1)*8,SC_GRID_WIDTH*8
        dc.w 0,8,(SC_GRID_WIDTH+1)*8
        ; Relocate these addresses at load time. Each cursor starts after the minimum.
tb_q_initial_cursors:
        dc.l tb_q_forward_offsets+2,tb_q_reverse_offsets+2
        dc.l tb_q_forward_offsets+4,tb_q_reverse_offsets+8
        dc.l tb_q_forward_offsets+6,tb_q_reverse_offsets+6
        dc.l tb_q_forward_offsets+8,tb_q_reverse_offsets+4
tb_q_fcursor equ tb_q_frame_fcorrect
tb_q_bcursor equ tb_q_frame_bcorrect

tb_q_extrema macro
        cmp.w   d1,\1
        bge.s   .maximum\@
        move.w  \1,d1
        moveq   #\2,d0
        bra.s   .extrema_done\@
.maximum\@:
        cmp.w   a1,\1
        ble.s   .extrema_done\@
        movea.w \1,a1
.extrema_done\@:
        endm

; Private quad interface: A2 points to the scene, A4 to the strip record, and A6 to the page.
; On acceptance, return D0 = 1 and clear Z. Preserve D6, A3 and A6.
; On rejection, return D0 = 0 and set Z. Preserve A2, A4, A5 and D7.
        macro tb_q_inline_edge
        movea.l tb_q_frame_base(a6),a1
        move.w  -2(a0),d2
.advance\@:
        move.w  (a0)+,d4
        ; Keep raw projected Y in D3 and test the rounded stop in D1.
        move.w  4(a1,d4.w),d3
        move.w  d3,d1
        addq.w  #7,d1
        lsr.w   #4,d1
        cmp.w   a5,d1
        bgt.s   .active\@
        move.w  d4,d2
        bra.s   .advance\@
.active\@:
        ; EXG puts the rounded stop in D3 and the raw Y in D1.
        ; Use D1.W for dy before replacing the full register.
        exg     d1,d3
        move.w  4(a1,d2.w),d0
        sub.w   d0,d1
        ; Restart a chain at the corner's sampled row.
        ; Skipped corners on a Y-monotone chain have that same sample row.
        moveq   #15,d5             ; Index code cells by the raw Y fraction.
        and.w   d0,d5
        move.w  (a1,d2.w),d0
        move.w  (a1,d4.w),d4
        sub.w   d0,d4
        addq.w  #8,d0
        ; The 2319-unit Y guard bounds positive dy.
        ; Use exact signed division for the short one-row edges.
        cmpi.w  #4,d1
        blo.w   .tiny\@
        add.w   d1,d1
        add.w   d1,d1
        lea     tb_q_slope_table(pc),a1
        ; Keep the shift count in the six low bits of D2.
        ; Use dX as the MULS source. Traced dX values typically have fewer bit transitions.
        move.l  (a1,d1.w),d2
        move.l  d2,d1
        swap    d1
        muls.w  d4,d1
        asr.l   d2,d1              ; Convert to Q16 pixels per row.
        move.l  d1,d4
        ; The viewport margin makes the biased X nonnegative.
        swap    d0
        clr.w   d0
        lsr.l   #4,d0
        ; Compute floor(step * first sample offset / 16) for the first sample.
        ; The raw Y fraction indexes 16-byte code cells.
        ; Their order gives phase = (8 - Y) AND 15 without a subtraction.
        ; Each cell computes floor(step * phase / 16). Phase zero skips the add.
        lsl.w   #4,d5
        jmp     .phase8\@(pc,d5.w)
.phase8\@:
        asr.l   #1,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase8\@),0
.phase7\@:
        move.l  d4,d2
        lsl.l   #3,d4
        sub.l   d2,d4
        asr.l   #4,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase7\@),0
.phase6\@:
        move.l  d4,d2
        lsl.l   #2,d4
        sub.l   d2,d4
        asr.l   #3,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase6\@),0
.phase5\@:
        move.l  d4,d2
        lsl.l   #2,d4
        add.l   d2,d4
        asr.l   #4,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase5\@),0
.phase4\@:
        asr.l   #2,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase4\@),0
.phase3\@:
        move.l  d4,d2
        lsl.l   #2,d4
        sub.l   d2,d4
        asr.l   #4,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase3\@),0
.phase2\@:
        asr.l   #3,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase2\@),0
.phase1\@:
        asr.l   #4,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase1\@),0
.phase0\@:
        bra.w   .slope_ready\@
        dcb.b   16-(*-.phase0\@),0
.phase15\@:
        move.l  d4,d2
        lsl.l   #4,d4
        sub.l   d2,d4
        asr.l   #4,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase15\@),0
.phase14\@:
        move.l  d4,d2
        lsl.l   #3,d4
        sub.l   d2,d4
        asr.l   #3,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase14\@),0
.phase13\@:
        move.l  d4,d2
        add.l   d4,d4
        add.l   d2,d4
        lsl.l   #2,d4
        add.l   d2,d4
        asr.l   #4,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase13\@),0
.phase12\@:
        move.l  d4,d2
        lsl.l   #2,d4
        sub.l   d2,d4
        asr.l   #2,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase12\@),0
.phase11\@:
        move.l  d4,d2
        add.l   d4,d4
        add.l   d2,d4
        lsl.l   #2,d4
        sub.l   d2,d4
        asr.l   #4,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase11\@),0
.phase10\@:
        move.l  d4,d2
        lsl.l   #2,d4
        add.l   d2,d4
        asr.l   #3,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase10\@),0
.phase9\@:
        move.l  d4,d2
        lsl.l   #3,d4
        add.l   d2,d4
        asr.l   #4,d4
        bra.w   .phase_add\@
        dcb.b   16-(*-.phase9\@),0
.phase_add\@:
        add.l   d4,d0
.slope_ready\@:
        subq.l  #1,d0               ; Keep the exclusive tie rule after quantization.
        bra.w   .inline_end\@
.tiny\@:
        ; Use the actual phase for short edges, not the raw table index.
        neg.w   d5
        addq.w  #8,d5
        andi.w  #15,d5
        muls.w  d4,d5
        subq.l  #1,d5
        exg     d0,d5
        TB_R_PACKED_EDGE_DIV
        add.w   d5,d0
        swap    d0
        clr.w   d0
        lsr.l   #4,d0
        moveq   #0,d1              ; dy < 4 permits only one sampled row.
        bra.w   .inline_end\@
.inline_end\@:
        endm

        xdef tb_terrain_quad_scene
; Return Z set if no sample rows are drawable within the viewport.
; Return a negative D0 to distinguish this case from other rejections.
tb_q_empty:
        moveq   #-1,d0
        cmp.b   d0,d0
        rts

; A0 points to the first outer node's X word. A4 points to its solid ink record.
; A6 points to the page. Use the source grid, not a packed copy.
; The outline is TL, BL, BM, BR, TR, TM. Return as for an accepted quad.
TB_SIX_BL equ SC_GRID_WIDTH*8
TB_SIX_BM equ TB_SIX_BL+8
TB_SIX_BR equ TB_SIX_BL+16
tb_terrain_outer_six:
        ; The checked rails are monotone. Only the four outside corners set the sample limits.
        ; Either end of a minimum plateau gives the same active edges.
        moveq   #0,d0
        move.w  4(a0),d1
        movea.w d1,a1
        move.w  TB_SIX_BL+4(a0),d2
        tb_q_extrema d2,2
        move.w  TB_SIX_BR+4(a0),d2
        tb_q_extrema d2,6
        move.w  16+4(a0),d2
        tb_q_extrema d2,8
        move.w  d1,d2
        move.w  a1,d3
        addq.w  #7,d2
        addq.w  #7,d3
        lsr.w   #4,d2
        lsr.w   #4,d3
        move.l  a6,d1
        link    a6,#-22
        movem.l d6/a3,-(sp)
        move.l  a0,tb_q_frame_base(a6)
        lsl.w   #2,d0
        lea     tb_six_initial_cursors(pc),a1
        move.l  (a1,d0.w),tb_q_fcursor(a6)
        move.l  4(a1,d0.w),tb_q_bcursor(a6)
        move.w  d2,tb_q_frame_fstop(a6)
        move.w  d2,tb_q_frame_bstop(a6)
        move.w  d3,tb_q_frame_endrow(a6)
        moveq   #0,d0
        move.b  1(a4),d0
        add.w   d0,d0
        lea     tb_q_solid_table(pc),a0
        move.w  (a0,d0.w),tb_q_frame_painter(a6)
        movea.l d1,a4
        movea.w d2,a5
        tb_q_add_rows d2,a4
        bra.w   tb_q_begin_segment
tb_six_forward:
        dc.w 0,TB_SIX_BL,TB_SIX_BM,TB_SIX_BR,16,8,0,TB_SIX_BL,TB_SIX_BM,TB_SIX_BR,16
tb_six_reverse:
        dc.w 0,8,16,TB_SIX_BR,TB_SIX_BM,TB_SIX_BL,0,8,16,TB_SIX_BR,TB_SIX_BM
tb_six_initial_cursors:
        dc.l tb_six_forward+2,tb_six_reverse+2
        dc.l tb_six_forward+4,tb_six_reverse+12
        dc.l tb_six_forward+6,tb_six_reverse+10
        dc.l tb_six_forward+8,tb_six_reverse+8
        dc.l tb_six_forward+10,tb_six_reverse+6
        dc.l tb_six_forward+12,tb_six_reverse+4
tb_terrain_outer_eight:
        moveq   #0,d0
        move.w  4(a0),d1
        movea.w d1,a1
        move.w  SC_GRID_WIDTH*8+0+4(a0),d2
        tb_q_extrema d2,2
        move.w  SC_GRID_WIDTH*8+24+4(a0),d2
        tb_q_extrema d2,8
        move.w  24+4(a0),d2
        tb_q_extrema d2,10
        move.w  d1,d2
        move.w  a1,d3
        addq.w  #7,d2
        addq.w  #7,d3
        lsr.w   #4,d2
        lsr.w   #4,d3
        move.l  a6,d1
        link    a6,#-22
        movem.l d6/a3,-(sp)
        move.l  a0,tb_q_frame_base(a6)
        lsl.w   #2,d0
        lea     tb_eight_initial_cursors(pc),a1
        move.l  (a1,d0.w),tb_q_fcursor(a6)
        move.l  4(a1,d0.w),tb_q_bcursor(a6)
        move.w  d2,tb_q_frame_fstop(a6)
        move.w  d2,tb_q_frame_bstop(a6)
        move.w  d3,tb_q_frame_endrow(a6)
        moveq   #0,d0
        move.b  1(a4),d0
        add.w   d0,d0
        lea     tb_q_solid_table(pc),a0
        move.w  (a0,d0.w),tb_q_frame_painter(a6)
        movea.l d1,a4
        movea.w d2,a5
        tb_q_add_rows d2,a4
        bra.w   tb_q_begin_segment
tb_eight_forward:
        dc.w 0,SC_GRID_WIDTH*8+0,SC_GRID_WIDTH*8+8,SC_GRID_WIDTH*8+16,SC_GRID_WIDTH*8+24,24,16,8,0,SC_GRID_WIDTH*8+0,SC_GRID_WIDTH*8+8,SC_GRID_WIDTH*8+16,SC_GRID_WIDTH*8+24,24,16
tb_eight_reverse:
        dc.w 0,8,16,24,SC_GRID_WIDTH*8+24,SC_GRID_WIDTH*8+16,SC_GRID_WIDTH*8+8,SC_GRID_WIDTH*8+0,0,8,16,24,SC_GRID_WIDTH*8+24,SC_GRID_WIDTH*8+16,SC_GRID_WIDTH*8+8
tb_eight_initial_cursors:
        dc.l tb_eight_forward+2,tb_eight_reverse+2
        dc.l tb_eight_forward+4,tb_eight_reverse+16
        dc.l tb_eight_forward+6,tb_eight_reverse+14
        dc.l tb_eight_forward+8,tb_eight_reverse+12
        dc.l tb_eight_forward+10,tb_eight_reverse+10
        dc.l tb_eight_forward+12,tb_eight_reverse+8
        dc.l tb_eight_forward+14,tb_eight_reverse+6
        dc.l tb_eight_forward+16,tb_eight_reverse+4
tb_long_4:
        moveq   #0,d0
        move.w  4(a0),d1
        movea.w d1,a1
        move.w  SC_GRID_WIDTH*8+0+4(a0),d2
        tb_q_extrema d2,2
        move.w  SC_GRID_WIDTH*8+32+4(a0),d2
        tb_q_extrema d2,10
        move.w  32+4(a0),d2
        tb_q_extrema d2,12
        move.w  d1,d2
        move.w  a1,d3
        addq.w  #7,d2
        addq.w  #7,d3
        lsr.w   #4,d2
        lsr.w   #4,d3
        move.l  a6,d1
        link    a6,#-22
        movem.l d6/a3,-(sp)
        move.l  a0,tb_q_frame_base(a6)
        lsl.w   #2,d0
        lea     tb_long_4_init(pc),a1
        move.l  (a1,d0.w),tb_q_fcursor(a6)
        move.l  4(a1,d0.w),tb_q_bcursor(a6)
        move.w  d2,tb_q_frame_fstop(a6)
        move.w  d2,tb_q_frame_bstop(a6)
        move.w  d3,tb_q_frame_endrow(a6)
        moveq   #0,d0
        move.b  1(a4),d0
        add.w   d0,d0
        lea     tb_q_solid_table(pc),a0
        move.w  (a0,d0.w),tb_q_frame_painter(a6)
        movea.l d1,a4
        movea.w d2,a5
        tb_q_add_rows d2,a4
        bra.w   tb_q_begin_segment
tb_long_4_fwd:
        dc.w 0,SC_GRID_WIDTH*8+0,SC_GRID_WIDTH*8+8,SC_GRID_WIDTH*8+16,SC_GRID_WIDTH*8+24,SC_GRID_WIDTH*8+32,32,24,16,8,0,SC_GRID_WIDTH*8+0,SC_GRID_WIDTH*8+8,SC_GRID_WIDTH*8+16,SC_GRID_WIDTH*8+24,SC_GRID_WIDTH*8+32,32,24,16
tb_long_4_rev:
        dc.w 0,8,16,24,32,SC_GRID_WIDTH*8+32,SC_GRID_WIDTH*8+24,SC_GRID_WIDTH*8+16,SC_GRID_WIDTH*8+8,SC_GRID_WIDTH*8+0,0,8,16,24,32,SC_GRID_WIDTH*8+32,SC_GRID_WIDTH*8+24,SC_GRID_WIDTH*8+16,SC_GRID_WIDTH*8+8
tb_long_4_init:
        dc.l tb_long_4_fwd+2,tb_long_4_rev+2
        dc.l tb_long_4_fwd+4,tb_long_4_rev+20
        dc.l tb_long_4_fwd+6,tb_long_4_rev+18
        dc.l tb_long_4_fwd+8,tb_long_4_rev+16
        dc.l tb_long_4_fwd+10,tb_long_4_rev+14
        dc.l tb_long_4_fwd+12,tb_long_4_rev+12
        dc.l tb_long_4_fwd+14,tb_long_4_rev+10
        dc.l tb_long_4_fwd+16,tb_long_4_rev+8
        dc.l tb_long_4_fwd+18,tb_long_4_rev+6
        dc.l tb_long_4_fwd+20,tb_long_4_rev+4

tb_terrain_quad_scene:
        ; D0 is the implicit lattice index. A4 points to the kind and solid ink.
        ; The authored strip uses an aligned back page and solid inks.
        ; Use the general face path for other materials.
        cmpi.b  #8,1(a4)
        bhs.w   tb_r_no_poly
        lea     sc_outcode(a2),a0
        move.b  (a0,d0.w),d1
        or.b    1(a0,d0.w),d1
        lea     SC_GRID_WIDTH(a0),a0
        or.b    (a0,d0.w),d1
        or.b    1(a0,d0.w),d1
        andi.b  #$21,d1             ; Test the near plane and viewport limits.
        bne.w   tb_r_no_poly
        lsl.w   #3,d0
        lea     sc_projected+2(a2),a0
        adda.w  d0,a0
        ; Keep the four raw projected Y values for the opposite corner test.
        moveq   #0,d0              ; Start with corner zero as the first minimum.
        move.w  4(a0),d2
        move.w  4+SC_GRID_WIDTH*8(a0),d3
        move.w  4+(SC_GRID_WIDTH+1)*8(a0),d4
        move.w  4+8(a0),d5
        move.w  d2,d1
        movea.w d2,a1
        tb_q_extrema d3,2
        tb_q_extrema d4,4
        tb_q_extrema d5,6
        ; Check for a strict opposite local minimum.
        ; Select the neighbour registers from the ordinal of the first minimum.
        tst.w   d0
        beq.s   .minimum0
        cmpi.w  #6,d0
        beq.s   .minimum3
        cmpi.w  #2,d0
        beq.s   .minimum1
        cmp.w   d3,d2
        bge.s   .admit
        cmp.w   d5,d2
        blt.w   tb_r_no_poly
        bra.s   .admit
.minimum0:
        cmp.w   d5,d4
        bge.s   .admit
        cmp.w   d3,d4
        blt.w   tb_r_no_poly
        bra.s   .admit
.minimum3:
        cmp.w   d4,d3
        bge.s   .admit
        cmp.w   d2,d3
        blt.w   tb_r_no_poly
        bra.s   .admit
.minimum1:
        cmp.w   d2,d5
        bge.s   .admit
        cmp.w   d4,d5
        blt.w   tb_r_no_poly
.admit:
        move.w  d1,d2
        move.w  a1,d3
        addq.w  #7,d2
        addq.w  #7,d3
        lsr.w   #4,d2
        lsr.w   #4,d3
        cmp.w   d2,d3
        ble.w   tb_q_empty
        move.l  a6,d1
        link    a6,#-22
        movem.l d6/a3,-(sp)
        move.l  a0,tb_q_frame_base(a6)
        lsl.w   #2,d0              ; Convert the corner index to a byte offset.
        lea     tb_q_initial_cursors(pc),a1
        move.l  (a1,d0.w),tb_q_fcursor(a6)
        move.l  4(a1,d0.w),tb_q_bcursor(a6)
        move.w  d2,tb_q_frame_fstop(a6)
        move.w  d2,tb_q_frame_bstop(a6)
        move.w  d3,tb_q_frame_endrow(a6)
        moveq   #0,d0
        move.b  1(a4),d0
        add.w   d0,d0
        lea     tb_q_solid_table(pc),a0
        move.w  (a0,d0.w),tb_q_frame_painter(a6)
        ; Keep the incoming page and first row live during setup.
        movea.l d1,a4
        movea.w d2,a5               ; Initialize the row only once.
        tb_q_add_rows d2,a4
tb_q_begin_segment:
.segment:
.begin_forward:
        ; Start both edge chains at the entry row.
        movea.l tb_q_fcursor(a6),a0
        tb_q_inline_edge
        move.l  a0,tb_q_fcursor(a6)
        move.l  d0,d6
        movea.l d1,a2
        move.w  d3,tb_q_frame_fstop(a6)
.reverse:
        cmpa.w  tb_q_frame_bstop(a6),a5
        bne.w   .segment_end
.begin_backward:
        movea.l tb_q_bcursor(a6),a0
        tb_q_inline_edge
        move.l  a0,tb_q_bcursor(a6)
        move.l  d0,d7
        movea.l d1,a3
        move.w  d3,tb_q_frame_bstop(a6)
.segment_end:
        ; Pass the row count to the writer. Keep the segment end in A5
        ; because the writer consumes D3.
        macro tb_q_render_segment
        move.w  d0,d3
        sub.w   a5,d3
        movea.w d0,a5
        subq.w  #1,d3
        move.w  tb_q_frame_painter(a6),d0
        jsr     tb_q_paint_base(pc,d0.w)
        endm
        movem.w tb_q_frame_bstop(a6),d0/d1
        cmp.w   d0,d1
        blt.s   .forward_first
        bgt.s   .backward_first
        ; Equal stops can end the polygon or restart both edges.
        tb_q_render_segment
        cmpa.w  tb_q_frame_endrow(a6),a5
        bhs.s   .end_polygon
        bra.w   .begin_forward
.forward_first:
        ; An edge stop cannot follow the last polygon sample. If the stops differ,
        ; restart only the edge with the earlier stop.
        ; Do not repeat these tests after the write.
        move.w  d1,d0
        tb_q_render_segment
        bra.w   .begin_forward
.backward_first:
        tb_q_render_segment
        bra.w   .begin_backward
.end_polygon:
        movem.l (sp)+,d6/a3
        unlk    a6
        moveq   #1,d0
        rts

; Keep the painter-table base within an 8-bit displacement.
tb_q_paint_base:
; D0 is the previous ordinal. D5 is the signed ordinal step.
; Walk four regular corners without wrapping the pointer or testing for clip limits.
; Return the next ordinal in A0. Other outputs match tb_r_chain_edge.

; ------------------------------------------------------------------------
; Model raster entry points
; ------------------------------------------------------------------------

; Use the standard edge walker and writers for a prepared inside face.
; Skip the duplicate general polygon setup.

; Load one fixed vertex slot and update the Y limits.
tb_m_point macro
        lsl.w   #3,\1
        move.w  (a0,\1.w),(a1)+
        move.w  4(a0,\1.w),\1
        move.w  \1,(a1)+
        cmp.w   d4,\1
        bge.s   .max\@
        move.w  \1,d4
        moveq   #\2,d0
        bra.s   .done\@
.max\@:
        cmp.w   d5,\1
        ble.s   .done\@
        move.w  \1,d5
.done\@:
        endm

; A2 points to the prepared scene, A4 to the face, and A6 to the page.
; The caller selects the ink writer. Preserve A2-A6 and D6-D7.
; Return D0 = 1 if drawn, or zero to use general clipping.
        xdef tb_model_poly_scene
tb_model_poly_scene:
        move.l  a6,d0
        btst    #0,d0
        bne.w   tb_r_no_poly
        move.b  8(a4),d5
        subq.b  #3,d5
        cmpi.b  #1,d5
        bhi.w   tb_r_no_poly
        lea     sc_outcode(a2),a0
        movem.w (a4),d0-d3
        move.b  (a0,d0.w),d4
        or.b    (a0,d1.w),d4
        or.b    (a0,d2.w),d4
        tst.b   d5
        beq.s   .visible
        or.b    (a0,d3.w),d4
.visible:
        andi.b  #$21,d4            ; Test the near plane and prepared raster bounds.
        bne.w   tb_r_no_poly
        lea     -16(sp),sp
        movea.l sp,a1
        lea     sc_projected+2(a2),a0
        lsl.w   #3,d0
        move.w  (a0,d0.w),(a1)+
        move.w  4(a0,d0.w),d4
        move.w  d4,(a1)+
        move.w  d4,d5
        moveq   #0,d0              ; Start with the first vertex as the minimum.
        tb_m_point d1,4
        tb_m_point d2,8
        cmpi.b  #3,8(a4)
        beq.s   .admit
        tb_m_point d3,12
        ; Only the vertex opposite the first global minimum can be an extra local minimum.
        ; Use the same test as the general quad path.
        move.w  d0,d1
        eori.w  #8,d1
        move.w  2(sp,d1.w),d2
        addq.w  #4,d1
        andi.w  #12,d1
        cmp.w   2(sp,d1.w),d2
        bge.s   .admit
        eori.w  #8,d1
        cmp.w   2(sp,d1.w),d2
        blt.w   .fallback
.admit:
        addq.w  #7,d4
        addq.w  #7,d5
        lsr.w   #4,d4
        lsr.w   #4,d5
        cmp.w   d4,d5
        ble.w   .fallback
        movea.l sp,a0
        move.l  a6,d1
        ; Reserve only active fields below the biased frame pointer.
        ; The 800-byte general scanline array is not needed.
        link    a6,#-106
        lea     800(a6),a6
        movem.l d6-d7/a2-a5,-(sp)
        move.l  d1,tb_r_surface(a6)
        move.l  a0,tb_r_base(a6)
        move.l  a1,tb_r_limit(a6)
        adda.w  d0,a0
        move.l  a0,d0             ; Keep the top vertex during writer selection.
        move.w  d5,tb_r_endrow(a6)
        st      tb_r_inside_x(a6)
        moveq   #0,d7
        move.b  9(a4),d7
        cmpi.w  #16,d7
        blo.s   .ink
        bset    #8,d7
.ink:
        movea.l d1,a0
        bsr.w   tb_r_writer
        movea.l d1,a4              ; Reuse the face register for the page.
        move.l  a1,tb_r_painter(a6) ; Keep the writer for later segments.
        movea.l a1,a5
        movea.l d0,a0
        move.w  d4,d0
        TB_R_FUSED_START
        bsr.w   tb_r_fused_segment
        movem.l (sp)+,d6-d7/a2-a5
        lea     -800(a6),a6
        unlk    a6
        lea     16(sp),sp
        moveq   #1,d0
        rts
.fallback:
        lea     16(sp),sp
        moveq   #0,d0
        rts

; ------------------------------------------------------------------------
; Paired tree raster entry points
; ------------------------------------------------------------------------

; A2 points to the scene, A4 to the first tree face, and A6 to the page.
; The caller verifies that the two faces are adjacent in painter order.
; Preserve A2-A6 and D6-D7. Return D0 = 0 to draw the original triangles.
; D4 holds the union mask. D2 is the word byte offset. A0 points to the destination.
; Split the high bit at the seam. Use the union for both low bits.
tb_tree_word macro
        move.w  d4,d0
        not.w   d0
        and.w   d0,(a0)             ; Clear bit 0 for both shades.
        or.w    d4,8000(a0)         ; Set bit 1 for both shades.
        cmp.w   tb_r_painter(a6),d2
        bhi.s   .only_ink2\@
        blo.s   .only_ink6\@
        move.w  16000(a0),d3
        and.w   d0,d3
        move.w  d4,d0
        and.w   tb_r_painter+2(a6),d0
        or.w    d0,d3
        move.w  d3,16000(a0)
        bra.s   .word_done\@
.only_ink2\@:
        and.w   d0,16000(a0)
        bra.s   .word_done\@
.only_ink6\@:
        or.w    d4,16000(a0)
.word_done\@:
        endm

        xdef tb_tree_pair_scene
tb_tree_pair_scene:
        move.l  a6,d0
        btst    #0,d0
        bne.w   tb_r_no_poly
        cmpi.w  #$0306,8(a4)      ; Require a triangle with ink 6.
        bne.w   tb_r_no_poly
        cmpi.w  #$0302,20(a4)     ; Require a triangle with ink 2.
        bne.w   tb_r_no_poly
        move.w  10(a4),d4
        cmp.w   22(a4),d4
        bne.w   tb_r_no_poly
        ; The authored pair has vertices A, B, C and C, B, D.
        movem.w (a4),d0-d2
        cmp.w   12(a4),d2
        bne.w   tb_r_no_poly
        cmp.w   14(a4),d1
        bne.w   tb_r_no_poly
        move.w  16(a4),d3
        lea     sc_outcode(a2),a0
        move.b  (a0,d0.w),d4
        or.b    (a0,d1.w),d4
        or.b    (a0,d2.w),d4
        or.b    (a0,d3.w),d4
        andi.b  #$21,d4
        bne.w   tb_r_no_poly
        lea     sc_projected+2(a2),a0
        lsl.w   #3,d0
        lsl.w   #3,d1
        lsl.w   #3,d2
        lsl.w   #3,d3
        ; Use hull A, B, D, C. Start both chains at B.
        lea     -16(sp),sp
        move.w  (a0,d0.w),(sp)
        move.w  4(a0,d0.w),2(sp)
        move.w  (a0,d1.w),4(sp)
        move.w  4(a0,d1.w),6(sp)
        move.w  (a0,d3.w),8(sp)
        move.w  4(a0,d3.w),10(sp)
        move.w  (a0,d2.w),12(sp)
        move.w  4(a0,d2.w),14(sp)
        move.w  4(sp),d0           ; Load the shared vertical seam.
        cmp.w   12(sp),d0
        bne.w   .reject
        cmp.w   (sp),d0
        ble.w   .reject
        cmp.w   8(sp),d0
        bge.w   .reject
        move.w  8(sp),d1
        sub.w   (sp),d1
        cmpi.w  #240,d1           ; Allow at most 15 pixels after rounding.
        bhi.w   .reject
        move.w  6(sp),d4
        move.w  14(sp),d5
        cmp.w   2(sp),d4
        bge.w   .reject
        cmp.w   10(sp),d4
        bge.w   .reject
        cmp.w   2(sp),d5
        ble.w   .reject
        cmp.w   10(sp),d5
        ble.w   .reject
        addq.w  #7,d4
        lsr.w   #4,d4
        addq.w  #7,d5
        lsr.w   #4,d5
        cmp.w   d4,d5
        ble.w   .reject
        addq.w  #7,d0
        asr.w   #4,d0
        lsl.w   #3,d0
        lea     tb_r_coord_table(pc),a1
        move.l  4(a1,d0.w),d0      ; Load the packed seam offset and prefix.
        addq.w  #2,d0              ; Remove the right offset bias.
        swap    d0
        movea.l sp,a0
        move.l  a6,d1
        link    a6,#-90
        lea     800(a6),a6
        movem.l d6-d7/a2-a5,-(sp)
        move.l  d1,tb_r_surface(a6)
        move.l  d0,tb_r_painter(a6) ; Save the constant seam in the writer slot.
        move.l  a0,tb_r_base(a6)
        lea     16(a0),a1
        move.l  a1,tb_r_limit(a6)
        addq.l  #4,a0
        move.l  a0,tb_r_forward(a6)
        move.l  a0,tb_r_back(a6)
        move.w  d5,tb_r_endrow(a6)
        move.w  d4,tb_r_row(a6)
        move.w  d4,tb_r_fstop(a6)
        move.w  d4,tb_r_bstop(a6)
        movea.l d1,a4
        TB_ROW40_ADDRESS d4,a4
        bra.s   .segment
.reject:
        lea     16(sp),sp
        moveq   #0,d0
        rts

.segment:
        move.w  tb_r_row(a6),d0
.segment_row_ready:
.begin_forward:
        ; Both stops initially equal the entry row.
        ; The next segment tail chooses which edge to restart.
        movea.l tb_r_forward(a6),a0
        move.w  d0,d2
        bsr.w   tb_r_chain_edge_forward
        move.l  a0,tb_r_forward(a6)
        move.l  d0,d6
        movea.l d1,a2
        move.w  d3,tb_r_fstop(a6)
        move.l  d2,tb_r_fcorrect(a6)
        move.w  tb_r_row(a6),d0      ; Reload the row after the forward call.
.reverse_row_ready:
        cmp.w   tb_r_bstop(a6),d0
        bne.s   .segment_end
.begin_backward:
        movea.l tb_r_back(a6),a0
        move.w  d0,d2
        bsr.w   tb_r_chain_edge_back
        move.l  a0,tb_r_back(a6)
        move.l  d0,d7
        movea.l d1,a3
        move.w  d3,tb_r_bstop(a6)
        move.l  d2,tb_r_bcorrect(a6)
.segment_end:
        move.w  tb_r_fstop(a6),d0
        cmp.w   tb_r_bstop(a6),d0
        ble.s   .finish
        move.w  tb_r_bstop(a6),d0
.finish:
        move.w  d0,tb_r_row(a6)
        movea.l tb_r_surface(a6),a5
        TB_ROW40_ADDRESS d0,a5
        lea     tb_r_coord_table(pc),a1
.row:
        move.l  d7,d0
        move.l  d6,d1
        ; Interior sampling makes X nonnegative. Remove the Q4 fraction.
        ; Scale the result to an eight-byte coordinate-table index.
        andi.w  #$7ff0,d0
        andi.w  #$7ff0,d1
        lsr.w   #1,d0
        lsr.w   #1,d1
        cmp.w   d0,d1
        beq.w   .step
        move.l  (a1,d0.w),d4       ; Load the left suffix and first byte offset.
        move.w  d4,d2
        swap    d4
        move.l  4(a1,d1.w),d5
        move.w  d5,d1
        addq.w  #2,d1
        swap    d5
        lea     (a4,d2.w),a0
        cmp.w   d2,d1
        bne.s   .two
        and.w   d5,d4
        tb_tree_word
        bra.w   .step
.two:
        tb_tree_word
        addq.w  #2,d2
        addq.l  #2,a0
        move.w  d5,d4
        tb_tree_word
.step:
        tb_r_advance_pair reg_end
        blo.w   .row
        move.w  tb_r_row(a6),d0
        cmp.w   tb_r_endrow(a6),d0
        bhs.s   .end_polygon
        cmp.w   tb_r_fstop(a6),d0
        bne.w   .begin_backward
        bra.w   .begin_forward
.end_polygon:
        movem.l (sp)+,d6-d7/a2-a5
        lea     -800(a6),a6
        unlk    a6
        lea     16(sp),sp
        moveq   #1,d0
        rts

; ------------------------------------------------------------------------
; Inset route map
; ------------------------------------------------------------------------

; The inset has 16 x 16 cells. Each cell occupies 2 x 2 pixels.
; On the inset, decreasing world X goes right. Increasing world Z goes down.
; The tank dots and map share the three display bitplanes. No additional DMA is necessary.
TB_MAP_BASE equ 10*PL_ROW_BYTES+2  ; X = 16, Y = 10 in each bitplane.
TB_MAP_CELLS equ 16

; Reset the previous dot positions on both pages. Do not change the map data.
tb_map_init:
        moveq   #-1,d0
        move.l  d0,tb_map_dot_rows
        move.l  d0,tb_map_dot_rows+4
        rts

; Inputs: A3 = scene, A4 = back page.
; Copy the complete map once per page after a header change.
; On later frames, restore only the row pairs that contained the previous dots.
; The viewport clear does not change the map.
tb_map_draw:
        movem.l d2-d5/a2/a5,-(sp)
        lea     tb_map_dot_rows,a5
        lea     play_pages,a0
        cmpa.l  a0,a4
        beq.s   .have_page
        addq.l  #4,a5
.have_page:
        move.w  (a5),d0
        bmi.s   .first
        bsr.s   .restore_pair
        move.w  2(a5),d0
        cmp.w   (a5),d0
        beq.s   .dots
        bsr.s   .restore_pair
        bra.s   .dots
.first:
        lea     TB_MAP_BASE(a4),a0
        lea     tb_map_planes,a1
        moveq   #2,d1
.plane: moveq   #15,d0
        movea.l a0,a2
.row:   move.l  (a1)+,d2
        move.l  d2,(a2)
        move.l  d2,PL_ROW_BYTES(a2)
        lea     2*PL_ROW_BYTES(a2),a2
        dbra    d0,.row
        lea     PL_PLANE_BYTES(a0),a0
        dbra    d1,.plane

.dots:
        lea     sc_tank(a3),a1
        moveq   #7,d5
        bsr.s   .dot
        addq.l  #6,a1
        moveq   #1,d5
        bsr.s   .dot
        movem.l (sp)+,d2-d5/a2/a5
        rts

; Input: D0.W = previous cell row. Restore its two rows in each bitplane.
.restore_pair:
        lea     .row_offsets(pc),a0
        add.w   d0,d0
        move.w  (a0,d0.w),d1
        lea     TB_MAP_BASE(a4),a0
        adda.w  d1,a0
        add.w   d0,d0
        lea     tb_map_planes,a2
        adda.w  d0,a2
map_plane set 0
        rept 3
        move.l  (a2),d2
        move.l  d2,(a0)
        move.l  d2,PL_ROW_BYTES(a0)
        ifne map_plane-2
        lea     PL_PLANE_BYTES(a0),a0
        lea     4*TB_MAP_CELLS(a2),a2
        endif
map_plane set map_plane+1
        endr
        rts

.row_offsets:
map_row set 0
        rept TB_MAP_CELLS
        dc.w map_row
map_row set map_row+2*PL_ROW_BYTES
        endr

; Both tank paths stay between -48 and +48 on the X and Z axes.
; Convert each coordinate to its map cell before it selects a 2 x 2 pixel block.
.dot:   move.w  4(a1),d0
        bsr.w   .cell
        move.w  d0,(a5)+
        move.w  d0,d1
        lsl.w   #2,d0
        add.w   d1,d0
        lsl.w   #4,d0  ; Two screen rows have 80 bytes.
        lea     TB_MAP_BASE(a4),a0
        adda.w  d0,a0
        move.w  (a1),d0
        bsr.w   .cell
        add.w   d0,d0
        eori.w  #2*(TB_MAP_CELLS-1),d0  ; Reverse the cell index, not the pixel index.
        move.l  #$c0000000,d2
        lsr.l   d0,d2
        move.l  d2,d3
        not.l   d3
        moveq   #2,d4
.dot_plane:
        lsr.b   #1,d5
        bcc.s   .off
        or.l    d2,(a0)
        or.l    d2,PL_ROW_BYTES(a0)
        bra.s   .dot_next
.off:   and.l   d3,(a0)
        and.l   d3,PL_ROW_BYTES(a0)
.dot_next:
        lea     PL_PLANE_BYTES(a0),a0
        dbra    d4,.dot_plane
        rts

; Input: D0 = signed world coordinate. Output: D0 = map cell index (0 to 15).
; The positive boundary belongs to the last cell.
.cell:
        cmpi.w  #-SC_MAP_EDGE,d0
        blt.s   .cell_low
        cmpi.w  #SC_MAP_EDGE,d0
        bge.s   .cell_high
        addi.w  #SC_MAP_EDGE,d0
        lsr.w   #SC_TILE_SHIFT+1,d0
        rts
.cell_low:
        moveq   #0,d0
        rts
.cell_high:
        moveq   #TB_MAP_CELLS-1,d0
        rts

        section bss,bss
tb_map_dot_rows: ds.l 2
        section code,code

; ------------------------------------------------------------------------
; Terrain edge slope lookup
; ------------------------------------------------------------------------

        ; The assembler makes one entry for each possible positive Q4 rise.
        ; The caller does not use the table for a rise less than 4.
tb_q_slope_table:
tb_q_slope_dy set 4
        ; Each entry has a mantissa from 8192 to 16384 and a shift count.
        ; Increase the shift count at each power of two to keep the mantissa in range.
        dcb.w   8,0
tb_q_slope_shift set 0
        rept    2316
        ifeq    tb_q_slope_dy-(8<<tb_q_slope_shift)
tb_q_slope_shift set tb_q_slope_shift+1
        endif
        dc.w    (((65536<<tb_q_slope_shift)+(tb_q_slope_dy>>1))/tb_q_slope_dy),tb_q_slope_shift
tb_q_slope_dy set tb_q_slope_dy+1
        endr

; ------------------------------------------------------------------------
; PAL live and final FPS measurement and display
; ------------------------------------------------------------------------

; Measure intervals between display page changes in horizontal sync lines.
; The CIA-B time-of-day counter counts one line every 64 microseconds on PAL.
; Read its three bytes from high to low to get one 24-bit value. Do not write the counter.
FPS_LINES       equ 0  ; Total horizontal sync lines (longword).
FPS_WORST       equ 4  ; Longest frame interval (longword).
FPS_FRAMES      equ 8  ; Number of valid intervals (word).
FPS_MIN         equ 10  ; Minimum sample FPS in tenths (word).
FPS_MAX         equ 12  ; Maximum sample FPS in tenths (word).
FPS_INVALID     equ 14  ; Nonzero if the clock is not valid (word).
FPS_SECOND      equ 15625
FPS_NONE        equ $ffff

play_fps_stage_begin:
        bsr.s   play_fps_row
        clr.l   FPS_LINES(a0)
        clr.l   FPS_WORST(a0)
        clr.w   FPS_FRAMES(a0)
        move.l  #-1,FPS_MIN(a0)
        clr.w   FPS_INVALID(a0)
        cmpi.b  #PL_ARM_PAL_END,play_arm_late
        beq.s   .pal
        move.w  #1,FPS_INVALID(a0)
.pal:
        clr.b   play_fps_have
        clr.w   play_fps_win_count
        clr.l   play_fps_win_lines
        move.w  #FPS_NONE,play_fps_live
        move.b  #2,play_fps_dirty
        rts

play_fps_row:
        moveq   #0,d0
        move.b  play_suite_stage,d0
        lsl.w   #4,d0
        lea     play_fps_rows,a0
        adda.w  d0,a0
        rts

; Read the clock immediately after a page change.
; The first page of a stage sets the start time. The interval before it is not a sample.
play_fps_measure:
        bsr.s   play_fps_row
        moveq   #0,d0
        move.b  CIAB_TODHI,d0
        lsl.l   #8,d0
        move.b  CIAB_TODMID,d0
        lsl.l   #8,d0
        move.b  CIAB_TODLO,d0
        move.l  d0,d1
        sub.l   play_fps_tod,d0
        andi.l  #$00ffffff,d0  ; Keep the 24-bit difference after a counter wrap.
        move.l  d1,play_fps_tod
        tst.w   FPS_INVALID(a0)
        bne.w   play_fps_measure_done
        tst.b   play_fps_have
        bne.s   .interval
        st      play_fps_have
        bra.w   play_fps_measure_done
.interval:
        ; A page change cannot occur less than one field after the previous change.
        ; Reject counts below 250 lines or above one second.
        cmpi.l  #250,d0
        blo.s   .invalid
        cmpi.l  #FPS_SECOND,d0
        bhi.s   .invalid
        add.l   d0,FPS_LINES(a0)
        addq.w  #1,FPS_FRAMES(a0)
        cmp.l   FPS_WORST(a0),d0
        bls.s   .window
        move.l  d0,FPS_WORST(a0)
.window:
        addq.w  #1,play_fps_win_count
        add.l   d0,play_fps_win_lines
        move.l  play_fps_win_lines,d0
        cmpi.l  #FPS_SECOND,d0
        blo.s   play_fps_measure_done
        moveq   #0,d1
        move.w  play_fps_win_count,d1
        bsr.w   play_fps_to_rate
        cmpi.w  #FPS_NONE,d0
        beq.s   .invalid
        cmp.w   FPS_MIN(a0),d0
        bhs.s   .min_ok
        move.w  d0,FPS_MIN(a0)
.min_ok:
        cmpi.w  #FPS_NONE,FPS_MAX(a0)
        beq.s   .set_max
        cmp.w   FPS_MAX(a0),d0
        bls.s   .max_ok
.set_max:
        move.w  d0,FPS_MAX(a0)
.max_ok:
        move.w  d0,play_fps_live
        move.b  #2,play_fps_dirty
        clr.w   play_fps_win_count
        clr.l   play_fps_win_lines
        bra.s   play_fps_measure_done
.invalid:
        move.w  #1,FPS_INVALID(a0)
        move.w  #FPS_NONE,play_fps_live
        move.b  #2,play_fps_dirty
play_fps_measure_done:
        rts

; Inputs: D0.L = elapsed lines, D1.W = interval count.
; Output: D0.W = rounded FPS in tenths.
; Convert to whole milliseconds first so that the divisor fits in 16 bits.
; Minimum and maximum FPS use complete samples of approximately one second.
play_fps_to_rate:
        tst.w   d1
        beq.s   .none
        lsl.l   #3,d0
        addi.l  #62,d0
        divu.w  #125,d0  ; PAL lines x 8 / 125 = milliseconds.
        bvs.s   .none
        tst.w   d0
        beq.s   .none
        mulu.w  #10000,d1
        moveq   #0,d2
        move.w  d0,d2
        lsr.w   #1,d2
        add.l   d2,d1
        divu.w  d0,d1
        bvs.s   .none
        cmpi.w  #999,d1
        bhi.s   .none
        move.w  d1,d0
        rts
.none:
        move.w  #FPS_NONE,d0
        rts

play_fps_stamp_live:
        tst.b   play_fps_dirty
        beq.s   .no
        subq.b  #1,play_fps_dirty
        move.w  play_fps_live,d0
        moveq   #2,d1
        lea     37*PL_ROW_BYTES+34(a4),a1
        bra.s   play_fps_stamp_number
.no:
        rts

; Inputs: D0.W = FPS in tenths or $FFFF, D1.W = number of integer digits.
; A1 points to the first glyph position on the back page.
; Write white glyphs on a black background in all three bitplanes.
; Do not change bytes outside the glyph field.
play_fps_stamp_number:
        lea     -6(sp),sp
        movea.l sp,a0
        adda.w  d1,a0
        addq.l  #2,a0
        addq.w  #1,d1
        move.w  d1,d2
        cmpi.w  #FPS_NONE,d0
        beq.s   .dashes
        andi.l  #$ffff,d0
        divu.w  #10,d0
        swap    d0
        move.b  d0,-(a0)
        swap    d0
        move.b  #11,-(a0)
        subq.w  #2,d2
.digit:
        andi.l  #$ffff,d0
        divu.w  #10,d0
        swap    d0
        move.b  d0,-(a0)
        swap    d0
        dbra    d2,.digit
        bra.s   .glyphs
.dashes:
        move.b  #10,-(a0)
        dbra    d2,.dashes
.glyphs:
        lea     play_fps_digits,a2
.glyph:
        moveq   #0,d3
        move.b  (a0)+,d3
        lsl.w   #3,d3
        moveq   #7,d2
.row:
        move.b  (a2,d3.w),d0
        move.b  d0,(a1)
        move.b  d0,PL_PLANE_BYTES(a1)
        move.b  d0,2*PL_PLANE_BYTES(a1)
        addq.w  #1,d3
        lea     PL_ROW_BYTES(a1),a1
        dbra    d2,.row
        lea     1-8*PL_ROW_BYTES(a1),a1
        dbra    d1,.glyph
        addq.l  #6,sp
        rts

play_fps_show_results:
        lea     play_fps_rows,a3
        lea     play_fps_summary,a4
        moveq   #0,d5  ; Longest interval in the valid stages.
        moveq   #0,d6  ; Nonzero if a stage has invalid data.
        moveq   #3,d7
.summary:
        tst.w   FPS_INVALID(a3)
        bne.s   .unavailable
        tst.w   FPS_FRAMES(a3)
        beq.s   .unavailable
        move.l  FPS_LINES(a3),d0
        move.w  FPS_FRAMES(a3),d1
        bsr.w   play_fps_to_rate
        move.w  d0,(a4)+
        move.w  FPS_MIN(a3),(a4)+
        move.w  FPS_MAX(a3),(a4)+
        cmp.l   FPS_WORST(a3),d5
        bhs.s   .next
        move.l  FPS_WORST(a3),d5
        bra.s   .next
.unavailable:
        move.l  #-1,(a4)+
        move.w  #FPS_NONE,(a4)+
        moveq   #1,d6
.next:
        lea     FPS_ROW(a3),a3
        dbra    d7,.summary
        move.w  #FPS_NONE,d0
        tst.w   d6
        bne.s   .save_worst
        lsl.l   #4,d5
        addi.l  #12,d5
        divu.w  #25,d5  ; PAL lines x 16 / 25 = tenths of a millisecond.
        bvs.s   .save_worst
        cmpi.w  #9999,d5
        bhi.s   .save_worst
        move.w  d5,d0
.save_worst:
        move.w  d0,(a4)

        movea.l play_back,a4
        movea.l a4,a0
        lea     play_fps_results_rle,a1
        jsr     play_unpack_panel
        lea     play_fps_summary,a3
        lea     72*PL_ROW_BYTES(a4),a5
        moveq   #3,d7
.lines:
        move.w  (a3)+,d0
        moveq   #2,d1
        lea     15(a5),a1
        bsr.w   play_fps_stamp_number
        move.w  (a3)+,d0
        moveq   #2,d1
        lea     23(a5),a1
        bsr.w   play_fps_stamp_number
        move.w  (a3)+,d0
        moveq   #2,d1
        lea     31(a5),a1
        bsr.w   play_fps_stamp_number
        lea     16*PL_ROW_BYTES(a5),a5
        dbra    d7,.lines
        move.w  (a3),d0
        moveq   #3,d1
        lea     137*PL_ROW_BYTES+21(a4),a1
        bsr.w   play_fps_stamp_number

        ; Change to the results page during vertical blanking.
        ; Do not include the results page in a stage measurement.
        jsr     play_vblank
        move.l  play_copper_back,d0
        move.l  play_copper_front,play_copper_back
        move.l  d0,play_copper_front
        move.l  d0,CUSTOM+COP1LCH
        move.l  play_back,d0
        move.l  play_front,play_back
        move.l  d0,play_front
play_fps_results_ready:
        rts
