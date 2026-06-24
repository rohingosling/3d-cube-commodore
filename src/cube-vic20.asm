//*******************************************************************************
//
// Project:      3D Wire Frame Cube (VIC-20)
// Version:      1.0
// Release Date: 1989
// Last Updated: 2026-04-22
// Author:       Rohin Gosling
//
// DESCRIPTION:
//
//   A 6502 assembly language program that renders a rotating wire frame
//   cube on an unexpanded Commodore VIC-20, using strategically placed
//   PETSCII quadrant block characters to simulate a 44 x 46 pseudo-pixel
//   resolution on the native 22 x 23 character screen.
//
//   Each character cell is treated as a 2 x 2 grid of pseudo-pixels.
//   The eight quadrant block characters (plus the space character) and
//   their reverse-video counterparts cover all 16 possible 2 x 2
//   quadrant masks via a lookup table, so plot_pixel can peek the
//   current cell, OR in the new quadrant, and write back the correct
//   character in constant time.
//
//   Quadrant bit assignment per character cell:
//
//     +---+---+
//     | 0 | 1 |     bit 0 = top-left
//     +---+---+     bit 1 = top-right
//     | 2 | 3 |     bit 2 = bottom-left
//     +---+---+     bit 3 = bottom-right
//
//     pixel_mask = 1 << ( ( y & 1 ) << 1 | ( x & 1 ) )
//     cell_mask  = old_cell_mask | pixel_mask    (for plot)
//     cell_mask  = old_cell_mask & ~pixel_mask   (for clear)
//     screen_code = mask_to_screen_code[ cell_mask ]
//
// USAGE:
//
//   LOAD "CUBE-VIC20", 1, 1
//   RUN
//
// BUILD (run from the v1 / project-root directory):
//
//   java -jar KickAss.jar src/cube-vic20.asm -odir ../build//
//
// RUN IN VICE (VIC-20):
//
//   xvic build/cube.prg
//
// CONTROLS:
//
//   F1       HOME / HELP toggle, or help overlay in MAIN
//   F2       Start cube (HOME → MAIN)
//   F3       Return to HOME
//   SPACE    Toggle auto-rotate / keyboard-control (MAIN only)
//
//   The following motion keys act only in keyboard-control mode:
//
//   + / -    Zoom in / out
//   W / R    Yaw left / right
//   E / D    Pitch up / down
//   S / F    X translate left / right
//   T / G    Y translate up / down
//   Q / A    Z translate closer / further
//
// TUNABLES:
//
//   Assembly-time .const declarations at top of source.
//
//   ROTATION_STEP     W/R/E/D delta per keypress
//   TRANSLATION_STEP  S/F/T/G/Q/A delta per keypress
//   ZOOM_STEP         +/- delta per keypress (Q1.6)
//   ASPECT_FACTOR     X compression, Q1.7 — default round(128 * 2 / 3)
//
//*******************************************************************************


//==============================================================================
// Constants
//==============================================================================

// KERNAL routines.

.const KERNAL_CHROUT            = $FFD2         // Output character to current device
.const KERNAL_CHRIN             = $FFCF         // Input character from current device
.const KERNAL_GETIN             = $FFE4         // Get character from keyboard buffer

// VIC-I chip registers (VIC-20).

.const VIC_SCREEN_BORDER        = $900F         // Bits 0-2 border, 3 reverse, 4-7 background
.const VIC_RASTER_HI            = $9004         // Bits 8:1 of the 9-bit raster-line counter

// Raster threshold: $9004 value ≥ 120 means raster line ≥ 240, which is
// past the visible 184-line screen area and into vblank. Used by
// wait_for_vblank to sync the back-buffer → SCREEN_RAM copy with the
// VIC's vertical retrace so the visible image only ever shows complete
// frames.

.const VBLANK_RASTER_THRESHOLD  = 120

// VIC-20 screen memory (unexpanded configuration).

.const SCREEN_RAM               = $1E00         // Screen character matrix (22 x 23 = 506 bytes)
.const COLOR_RAM                = $9600         // Color RAM (low nibble per cell)

// Screen dimensions.

.const SCREEN_COLUMNS           = 22            // Characters per row
.const SCREEN_ROWS              = 23            // Rows per screen
.const SCREEN_SIZE              = 506           // Total cells (22 * 23)

// Pseudo-pixel dimensions (2 x 2 quadrants per character cell).

.const PIXEL_COLUMNS            = 44            // SCREEN_COLUMNS * 2
.const PIXEL_ROWS               = 46            // SCREEN_ROWS    * 2

// Pseudo-pixel screen center (used by the 3D projection stage).

.const SCREEN_CENTER_X          = PIXEL_COLUMNS / 2         // 22
.const SCREEN_CENTER_Y          = PIXEL_ROWS    / 2         // 23

// Perspective projection parameters.
//
//   VIEWER_DISTANCE  - Camera Z position in Q2.6 space. depth = VD - rotated_z.
//   PROJECTION_FOCAL - Focal length; paired with VD so that at depth = VD
//                      the projection scale reduces to the old orthographic
//                      / 4 ( i.e. focal / VD = 1/4 ).
//
// With cube corners at ±40 and yaw+pitch rotation, the resulting depth
// range is 91..229 — all inside the 8-bit unsigned byte, so the 1/depth
// lookup (inv_depth_focal) can be indexed directly without offset math.

.const VIEWER_DISTANCE          = 150
.const PROJECTION_FOCAL         = 40

// Aspect-ratio correction for X. VIC-20 pseudo-pixels are wider than
// tall, so the horizontal offset is multiplied by ASPECT_FACTOR / 128
// (Q1.7) before being added to SCREEN_CENTER_X. Tune by editing the
// 2/3 fraction below — e.g. 3/4 for a wider cube, 5/8 for a taller one.

.const ASPECT_FACTOR            = round ( 128 * 2 / 3 )

// System addresses.

.const CURRENT_TEXT_COLOR       = $0286         // Current text color (used by CHROUT)
.const KEYBOARD_BUFFER_COUNT    = $C6           // Number of characters in keyboard buffer

// Zero page pointers.

.const ZP_PTR_1                 = $FB           // General 16-bit pointer
.const ZP_PTR_2                 = $FD           // Secondary 16-bit pointer
.const ZP_SCRATCH               = $02           // Temporary scratch byte

// Color codes.

.const COLOR_BLACK              = $00           // Black
.const COLOR_WHITE              = $01           // White
.const COLOR_CYAN               = $03           // Cyan
.const COLOR_GREEN              = $05           // Green
.const COLOR_BLUE               = $06           // Blue

// Screen state machine.
//
//   STATE_HOME       — Static home / title screen, waits for F1 or F2.
//   STATE_MAIN       — 3D pipeline running. F1 pauses with help overlay; F3 returns home.
//   STATE_MAIN_HELP  — Animation paused, help text overlaid on top of the frozen cube.
//   STATE_HELP       — Standalone help screen entered from home. F1 or F3 returns home.

.const STATE_HOME               = $00
.const STATE_MAIN               = $01
.const STATE_MAIN_HELP          = $02
.const STATE_HELP               = $03

// Function-key PETSCII codes returned by KERNAL_GETIN.

.const KEY_F1                   = $85
.const KEY_F2                   = $89
.const KEY_F3                   = $86

// Keyboard-controlled motion step sizes. Applied per keypress in
// keyboard-control mode ( control_mode = 1 ).

.const ROTATION_STEP            = 3             // W / R yaw, E / D pitch: ± per press
.const TRANSLATION_STEP         = 3             // S / F / T / G / Q / A: ± per press
.const ZOOM_STEP                = 4             // + / -: ± per press (Q1.6 zoom_factor)
.const MOTION_TABLE_LAST        = 11            // Highest index in motion_* tables (12 entries, 0..11)

// VIC_SCREEN_BORDER ($900F) composite value.
// Background = black ($0), reverse = on ($8 clears reverse mode flag), border = black ($0).
// On the VIC-20, bit 3 = 1 selects "normal" (non-reverse) display.

.const SCREEN_BORDER_BLACK      = $08           // BG=black, normal mode, border=black

// Control character codes.

.const CLEAR_SCREEN             = $93           // Clear screen control code
.const CARRIAGE_RETURN          = $0D           // Carriage return
.const SPACE                    = $20           // Space character

// PETSCII quadrant-block characters (upper / graphics set).
//
// These eight characters, combined with their reverse-video forms
// (base + $80 for the graphics range), cover all 16 possible 2 x 2
// quadrant masks.

.const CHAR_EMPTY               = $20           // No quadrants
.const CHAR_TL                  = $BE           // Top-left quadrant only
.const CHAR_TR                  = $BC           // Top-right quadrant only
.const CHAR_BL                  = $BB           // Bottom-left quadrant only
.const CHAR_BR                  = $AC           // Bottom-right quadrant only
.const CHAR_LOWER_HALF          = $A2           // Bottom-left + bottom-right (upper half is reverse video, screen code $E2)
.const CHAR_LEFT_HALF           = $A1           // Top-left + bottom-left
.const CHAR_DIAG_TL_BR          = $BF           // Top-left + bottom-right

//==============================================================================
// BASIC Stub — "10 SYS 4110"
//==============================================================================
//
// Tokenised BASIC that auto-SYSes to the assembly entry point at $100E (4110).
// Byte layout:
//
//     $1001-$1002: link pointer to next line (→ $100C, basic_end)
//     $1003-$1004: line number 10
//     $1005:       SYS token ($9E)
//     $1006-$100A: " 4110" in PETSCII (space + four digits)
//     $100B:       end-of-line null terminator
//     $100C-$100D: end-of-program marker ($0000)
//     $100E:       entry:
//
//==============================================================================

*= $1001 "BASIC Stub"

    .word basic_end, 10                         // Link pointer to next line, line number 10
    .byte $9E                                   // SYS token
    .text " 4110"                               // SYS address in decimal ($100E)
    .byte $00                                   // End of line
basic_end:
    .word $0000                                 // End of BASIC program

//==============================================================================
// Program Entry Point
//==============================================================================

*= $100E "Main"

entry:

    // Set background and border to black.

    lda #SCREEN_BORDER_BLACK
    sta VIC_SCREEN_BORDER

    // Set text color to white.

    lda #COLOR_WHITE
    sta CURRENT_TEXT_COLOR

    // Clear the screen.

    lda #CLEAR_SCREEN
    jsr KERNAL_CHROUT

    // Initialize the screen_code_to_mask reverse-lookup table.

    jsr init_plot_tables

    // Initialize rotation / translation / control state. Angles start
    // at zero; translations start centred; zoom_factor starts at $40
    // ( = 1.0× in Q1.6 ); control_mode = 0 ( auto-rotate ). The main
    // loop advances yaw + pitch by one step per frame while in auto
    // mode — a full revolution every 256 frames — and freezes them
    // when the user presses SPACE to switch to keyboard-control mode.

    lda #$00
    sta yaw_angle
    sta pitch_angle
    sta control_mode
    sta translate_x
    sta translate_y
    sta translate_z

    lda #$40                                    // Q1.6 unity
    sta zoom_factor

    // Render the home screen and enter the dispatch loop in STATE_HOME.

    lda #STATE_HOME
    sta screen_state
    jsr render_home_screen

    // Fall through to the main loop.

//==============================================================================
// Main Loop
//==============================================================================

main_loop:

    // State dispatcher. Only STATE_MAIN runs the 3D pipeline; the other
    // three states ( HOME, HELP, MAIN_HELP ) render once on state entry
    // and just spin-poll the keyboard afterwards.

    lda screen_state
    cmp #STATE_MAIN
    bne main_loop_idle

    // STATE_MAIN — one frame of the double-buffered 3D pipeline.

    jsr clear_pixel_screen
    jsr rotate_vertices_yaw
    jsr rotate_vertices_pitch
    jsr translate_vertices
    jsr project_vertices
    jsr draw_edges
    jsr wait_for_vblank
    jsr copy_buffer_to_screen
    jsr poll_keyboard

    // Re-check state: a keypress may have moved us out of STATE_MAIN.
    // Only advance the auto-rotation angles if we're still here and in
    // auto mode ( control_mode = 0 ).

    lda screen_state
    cmp #STATE_MAIN
    bne main_loop
    lda control_mode
    bne main_loop
    inc yaw_angle
    inc pitch_angle
    jmp main_loop

main_loop_idle:

    // Non-animation states: no 3D work, just poll for key events.

    jsr poll_keyboard
    jmp main_loop

//==============================================================================
// Subroutines — Pixel Plotting
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: plot_pixel
//
// Description:
//
//   Sets a pseudo-pixel at coordinates (X, Y) on the 44 x 46 virtual
//   screen by OR-ing the new quadrant bit into the existing character
//   at the corresponding 22 x 23 cell.
//
//   Algorithm:
//
//     cell_column = pixel_x >> 1
//     cell_row    = pixel_y >> 1
//     quadrant    = ( ( pixel_y & 1 ) << 1 ) | ( pixel_x & 1 )
//     pixel_mask  = 1 << quadrant
//     cell_offset = cell_row * SCREEN_COLUMNS + cell_column
//     old_mask    = screen_code_to_mask[ back_buffer + cell_offset ]
//     new_mask    = old_mask | pixel_mask
//     back_buffer + cell_offset = mask_to_screen_code[ new_mask ]
//
//   plot_pixel writes into back_buffer (not the visible SCREEN_RAM).
//   The row_start tables are precomputed against back_buffer so the
//   inner loop doesn't know the difference. copy_buffer_to_screen
//   pushes the completed frame to SCREEN_RAM once per main-loop pass.
//
// Parameters:
//
//   A - Pseudo-pixel X coordinate (0 to PIXEL_COLUMNS - 1).
//   X - Pseudo-pixel Y coordinate (0 to PIXEL_ROWS - 1).
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

plot_pixel:

    // Save pixel_x for cell-column computation later. pixel_y stays in X
    // through the quadrant calculation, so it doesn't need saving yet.

    sta plot_x

    // Build quadrant index (0..3):
    //
    //   quadrant = ( ( pixel_y & 1 ) << 1 ) | ( pixel_x & 1 )
    //
    // and look up the corresponding pixel_mask (1 << quadrant).

    and #$01                                    // A = pixel_x & 1 (low bit of quadrant)
    sta ZP_SCRATCH

    txa                                         // A = pixel_y (still in X)
    and #$01                                    // A = pixel_y & 1
    asl                                         // A = ( pixel_y & 1 ) << 1
    ora ZP_SCRATCH                              // A = quadrant index (0..3)
    tay
    lda pixel_mask_table, y                     // A = 1 << quadrant
    sta plot_pixel_mask

    // Compute cell_row = pixel_y >> 1 and load the row start address
    // into ZP_PTR_1 from the precomputed row_start tables.

    txa                                         // A = pixel_y
    lsr                                         // A = cell_row
    tax                                         // X = cell_row

    lda row_start_lo, x
    sta ZP_PTR_1
    lda row_start_hi, x
    sta ZP_PTR_1 + 1

    // Add cell_column = pixel_x >> 1 to the row start address.
    // The high byte needs incrementing only if the low-byte add carries.

    lda plot_x
    lsr                                         // A = cell_column
    clc
    adc ZP_PTR_1
    sta ZP_PTR_1
    bcc plot_pixel_peek
    inc ZP_PTR_1 + 1

plot_pixel_peek:

    // Peek current screen code, translate to its quadrant mask, OR in the
    // new pixel's mask, translate back to a screen code, write back.

    ldy #$00
    lda ( ZP_PTR_1 ), y                         // A = current screen code
    tax
    lda screen_code_to_mask, x                  // A = current cell's mask
    ora plot_pixel_mask                         // A = combined mask
    tax
    lda mask_to_screen_code, x                  // A = new screen code
    sta ( ZP_PTR_1 ), y

    rts

//------------------------------------------------------------------------------
//
// Subroutine: clear_pixel_screen
//
// Description:
//
//   Fills the 506-byte back buffer with the empty-cell screen code,
//   wiping the virtual pixel buffer in preparation for a fresh frame.
//   The visible SCREEN_RAM is not touched — copy_buffer_to_screen
//   pushes completed frames to the display.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

clear_pixel_screen:

    // Two-loop fill because X is 8-bit: the first loop sweeps a full
    // 256-byte page of back_buffer, the second fills the remaining
    // 250 bytes.

    lda #$20                                    // A = empty-cell screen code
    ldx #$00

clear_pixel_screen_page_1_loop:

    sta back_buffer, x                          // First 256 bytes
    inx
    bne clear_pixel_screen_page_1_loop          // Stops when X wraps to 0

    // X is 0 here. Fill the final 250 bytes.

clear_pixel_screen_page_2_loop:

    sta back_buffer + $100, x
    inx
    cpx #SCREEN_SIZE - $100                     // 506 - 256 = 250 remaining bytes
    bne clear_pixel_screen_page_2_loop

    rts

//------------------------------------------------------------------------------
//
// Subroutine: copy_buffer_to_screen
//
// Description:
//
//   Copies all 506 bytes of back_buffer into the visible screen
//   matrix at SCREEN_RAM ( $1E00 ). Called once per main-loop pass,
//   immediately after wait_for_vblank, so the copy runs during (and
//   briefly past) the VIC's vertical retrace interval.
//
//   The copy proceeds top-to-bottom, matching the raster beam's own
//   scan direction. At ~14 cycles per byte, the write-front moves
//   about 1.9× faster than the visible beam, so even on NTSC — where
//   vblank is ~2,665 cycles and the copy is ~7,000 cycles — the
//   copy stays ahead of the beam and the visible image is always a
//   complete frame.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

copy_buffer_to_screen:

    ldx #$00

copy_buffer_to_screen_page_1_loop:

    lda back_buffer, x                          // First 256 bytes
    sta SCREEN_RAM, x
    inx
    bne copy_buffer_to_screen_page_1_loop

copy_buffer_to_screen_page_2_loop:

    lda back_buffer + $100, x                   // Remaining 250 bytes
    sta SCREEN_RAM + $100, x
    inx
    cpx #SCREEN_SIZE - $100
    bne copy_buffer_to_screen_page_2_loop

    rts

//------------------------------------------------------------------------------
//
// Subroutine: wait_for_vblank
//
// Description:
//
//   Blocks until the VIC's raster beam enters vertical blanking
//   ( i.e. transitions past the visible screen area ). Used to
//   schedule the back_buffer → SCREEN_RAM copy for maximum time
//   before the beam reaches the top of the visible area again.
//
//   Two-stage wait:
//
//     1. Wait until $9004 < threshold   (raster is in visible area).
//     2. Wait until $9004 ≥ threshold   (raster has just entered vblank).
//
//   Stage 1 guards against the case where we arrive already in
//   vblank; without it we'd return immediately and lose most of
//   the retrace window.
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

wait_for_vblank:

wait_for_vblank_visible:

    lda VIC_RASTER_HI
    cmp #VBLANK_RASTER_THRESHOLD
    bcs wait_for_vblank_visible                 // Loop while raster ≥ threshold

wait_for_vblank_blank:

    lda VIC_RASTER_HI
    cmp #VBLANK_RASTER_THRESHOLD
    bcc wait_for_vblank_blank                   // Loop while raster < threshold

    rts

//------------------------------------------------------------------------------
//
// Subroutine: draw_line
//
// Description:
//
//   Draws a line between two pseudo-pixel endpoints using Bresenham's
//   integer line algorithm, plotting through plot_pixel. Handles all
//   eight octants (any slope, any direction) via a major-axis split:
//   the algorithm iterates along whichever axis has the larger
//   magnitude and steps along the minor axis whenever the accumulated
//   error exceeds zero.
//
//   Algorithm:
//
//     dx   = abs( x1 - x0 )
//     dy   = abs( y1 - y0 )
//     sx   = sign( x1 - x0 )         // +1 or -1
//     sy   = sign( y1 - y0 )         // +1 or -1
//     dx2  = dx << 1
//     dy2  = dy << 1
//
//     if dx >= dy:                   // X-major
//         err = dy2 - dx
//         repeat ( dx + 1 ) times:
//             plot( x, y )
//             if err > 0:  y += sy;  err -= dx2
//             err += dy2
//             x += sx
//     else:                          // Y-major
//         err = dx2 - dy
//         repeat ( dy + 1 ) times:
//             plot( x, y )
//             if err > 0:  x += sx;  err -= dy2
//             err += dx2
//             y += sy
//
//   Error accumulator is signed 8-bit. For coordinates in the
//   44 x 46 pseudo-pixel range, err stays within [-90, +90], well
//   inside signed-byte limits.
//
// Parameters:
//
//   line_x0, line_y0 - Start pseudo-pixel coordinates.
//   line_x1, line_y1 - End pseudo-pixel coordinates.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

draw_line:

    // Compute dx = abs( x1 - x0 ) and sx = sign( x1 - x0 ).

    lda line_x1
    sec
    sbc line_x0                                 // A = x1 - x0
    bcs draw_line_dx_positive

    eor #$FF                                    // x1 < x0: negate A
    clc
    adc #$01
    sta line_dx
    lda #$FF                                    // sx = -1
    sta line_sx
    jmp draw_line_dy_compute

draw_line_dx_positive:

    sta line_dx
    lda #$01                                    // sx = +1
    sta line_sx

draw_line_dy_compute:

    // Compute dy = abs( y1 - y0 ) and sy = sign( y1 - y0 ).

    lda line_y1
    sec
    sbc line_y0                                 // A = y1 - y0
    bcs draw_line_dy_positive

    eor #$FF                                    // y1 < y0: negate A
    clc
    adc #$01
    sta line_dy
    lda #$FF                                    // sy = -1
    sta line_sy
    jmp draw_line_precompute

draw_line_dy_positive:

    sta line_dy
    lda #$01                                    // sy = +1
    sta line_sy

draw_line_precompute:

    // Precompute 2 * dx and 2 * dy for the error accumulator updates.

    lda line_dx
    asl
    sta line_dx2
    lda line_dy
    asl
    sta line_dy2

    // Select major axis: dx >= dy → X-major, otherwise Y-major.

    lda line_dx
    cmp line_dy
    bcc draw_line_y_major

    //--------------------------------------------------------------
    // X-major: iterate over x, step y when error exceeds zero.
    //--------------------------------------------------------------

    lda line_dy2                                // err = 2 * dy - dx
    sec
    sbc line_dx
    sta line_err

    lda line_dx                                 // count down dx → -1 (plots dx + 1 pixels)
    sta line_count

draw_line_x_major_loop:

    lda line_x0
    ldx line_y0
    jsr plot_pixel

    lda line_err
    bmi draw_line_x_major_no_y_step
    beq draw_line_x_major_no_y_step

    // err > 0: step y, err -= 2 * dx.

    lda line_y0
    clc
    adc line_sy
    sta line_y0

    lda line_err
    sec
    sbc line_dx2
    sta line_err

draw_line_x_major_no_y_step:

    // err += 2 * dy; advance x.

    lda line_err
    clc
    adc line_dy2
    sta line_err

    lda line_x0
    clc
    adc line_sx
    sta line_x0

    dec line_count
    bpl draw_line_x_major_loop

    rts

    //--------------------------------------------------------------
    // Y-major: iterate over y, step x when error exceeds zero.
    //--------------------------------------------------------------

draw_line_y_major:

    lda line_dx2                                // err = 2 * dx - dy
    sec
    sbc line_dy
    sta line_err

    lda line_dy                                 // count down dy → -1 (plots dy + 1 pixels)
    sta line_count

draw_line_y_major_loop:

    lda line_x0
    ldx line_y0
    jsr plot_pixel

    lda line_err
    bmi draw_line_y_major_no_x_step
    beq draw_line_y_major_no_x_step

    // err > 0: step x, err -= 2 * dy.

    lda line_x0
    clc
    adc line_sx
    sta line_x0

    lda line_err
    sec
    sbc line_dy2
    sta line_err

draw_line_y_major_no_x_step:

    // err += 2 * dx; advance y.

    lda line_err
    clc
    adc line_dx2
    sta line_err

    lda line_y0
    clc
    adc line_sy
    sta line_y0

    dec line_count
    bpl draw_line_y_major_loop

    rts

//------------------------------------------------------------------------------
//
// Subroutine: init_plot_tables
//
// Description:
//
//   Initializes the 256-byte screen_code_to_mask reverse-lookup table
//   at runtime. The table is pre-zeroed at assembly time, so only the
//   16 valid screen codes corresponding to the eight base quadrant
//   characters and their reverse-video forms need to be patched.
//
//   mask_to_screen_code already holds the forward mapping; we walk it
//   backwards and write screen_code_to_mask[mask_to_screen_code[m]] = m
//   for each mask m in 0..15. No separate pair table is needed.
//
//   Invalid / unknown screen codes read back as mask 0 (treated as
//   empty), so characters left on screen from the previous program
//   state behave as a clean slate the first time plot_pixel touches
//   them.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

init_plot_tables:

    ldx #$0F

init_plot_tables_loop:

    ldy mask_to_screen_code, x                  // Y = screen code for mask X
    txa                                         // A = mask X
    sta screen_code_to_mask, y
    dex
    bpl init_plot_tables_loop

    rts

//==============================================================================
// Subroutines — Fixed-Point Math
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: multiply_signed_8
//
// Description:
//
//   Signed 8-bit by 8-bit multiply producing a 16-bit signed product.
//   Classic shift-and-add algorithm, no table, ~120 cycles per call.
//
//   The signed multiply is decomposed into: (1) record the sign of the
//   result as the XOR of the input signs, (2) take absolute values of
//   both inputs, (3) run an unsigned 8 x 8 shift-add multiply, and
//   (4) negate the 16-bit result if the recorded sign is negative.
//
//   The unsigned core exploits the fact that shifting the multiplier
//   right one bit per iteration pushes the next multiplier bit into
//   carry; if carry is set, the current multiplicand is added into the
//   high byte of the product. A following ROR on the high byte (then
//   the low byte) shifts the accumulator right, feeding the addition
//   carry into the high bit and the displaced bit of the high byte
//   into the top of the low byte. After eight iterations the full
//   16-bit product sits in ( multiply_result_hi, multiply_result_lo ).
//
// Parameters:
//
//   multiply_a - Signed 8-bit multiplicand (clobbered with its abs value).
//   multiply_b - Signed 8-bit multiplier   (clobbered: shifted out).
//
// Output:
//
//   multiply_result_hi : multiply_result_lo - Signed 16-bit product.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

multiply_signed_8:

    // Record the result's sign: bit 7 of ( a XOR b ) is set iff the
    // inputs differ in sign (i.e. exactly one is negative).

    lda multiply_a
    eor multiply_b
    sta multiply_sign

    // Take absolute value of multiply_a.

    lda multiply_a
    bpl multiply_signed_8_a_positive
    eor #$FF
    clc
    adc #$01
    sta multiply_a

multiply_signed_8_a_positive:

    // Take absolute value of multiply_b.

    lda multiply_b
    bpl multiply_signed_8_b_positive
    eor #$FF
    clc
    adc #$01
    sta multiply_b

multiply_signed_8_b_positive:

    // Unsigned 8 x 8 → 16-bit shift-add multiply.
    // multiply_result_lo is not initialised — the ROR sequence shifts
    // out any garbage over the eight iterations and replaces it with
    // the low byte of the product.

    lda #$00
    sta multiply_result_hi
    ldx #$08

multiply_signed_8_loop:

    lsr multiply_b                              // Next multiplier bit → carry
    bcc multiply_signed_8_no_add

    clc
    lda multiply_result_hi
    adc multiply_a                              // High byte += multiplicand
    sta multiply_result_hi

multiply_signed_8_no_add:

    ror multiply_result_hi                      // Carry from ADC → high bit of result_hi
    ror multiply_result_lo                      // Displaced low bit of result_hi → high bit of result_lo
    dex
    bne multiply_signed_8_loop

    // If the recorded sign is negative, negate the 16-bit result.

    lda multiply_sign
    bpl multiply_signed_8_done

    sec
    lda #$00
    sbc multiply_result_lo
    sta multiply_result_lo
    lda #$00
    sbc multiply_result_hi
    sta multiply_result_hi

multiply_signed_8_done:

    rts

//==============================================================================
// Subroutines — 3D Pipeline
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: rotate_vertices_yaw
//
// Description:
//
//   Applies a yaw rotation ( around the Y axis ) to the eight cube
//   vertices, writing the rotated triples into rotated_vertices.
//
//   Yaw rotation:
//
//     x' = x * cos(θ) - z * sin(θ)
//     y' = y
//     z' = x * sin(θ) + z * cos(θ)
//
//   θ is taken from yaw_angle, treated as a full-turn / 256 fraction:
//
//     yaw_angle $00 =   0°        $40 =  90°
//     yaw_angle $80 = 180°        $C0 = 270°
//
//   sin(θ) is read from sin_table directly; cos(θ) is read at
//   ( yaw_angle + $40 ) & $FF since cos(θ) = sin(θ + 90°).
//
//   Products are Q2.6 × Q1.6 = Q3.12 in 16 bits. Because both operands
//   are bounded ( |x|, |z| ≤ 48 and |sin|, |cos| ≤ 64 ), the product
//   fits easily in ± 3072 — the top three bits of the 16-bit result
//   are sign-extension. Taking the high byte of the product alone
//   gives Q3.6, but what we want is Q2.6, which requires one more bit
//   of scale. Equivalently: shift the 16-bit product LEFT by two bits
//   ( asl lo ; rol hi, twice ) and take the new high byte. That gives
//   Q2.6 directly.
//
// Inputs:
//
//   yaw_angle        - Current yaw, 0..255 ( 256 steps / revolution ).
//   cube_vertices    - Eight source triples in object space ( Q2.6 ).
//   sin_table        - 256-byte sine LUT, Q1.6.
//
// Outputs:
//
//   rotated_vertices - Eight rotated triples, Q2.6, written in place.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

rotate_vertices_yaw:

    // Precompute sin(θ) and cos(θ) once per frame.

    ldy yaw_angle
    lda sin_table, y
    sta rotate_sin

    tya
    clc
    adc #$40                                    // cos(θ) = sin(θ + 90°)
    tay
    lda sin_table, y
    sta rotate_cos

    // Iterate vertices. Y is the byte offset into the 24-byte vertex
    // buffers ( cube_vertices and rotated_vertices ), advancing by 3
    // per vertex. Y survives multiply_signed_8 because the multiply
    // routine only uses A and X internally.

    ldy #$00

rotate_vertices_yaw_loop:

    //--------------------------------------------------
    // x' = x * cos(θ) - z * sin(θ)
    //--------------------------------------------------

    // x * cos

    lda cube_vertices + 0, y
    sta multiply_a
    lda rotate_cos
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi
    sta rotate_temp                             // save x*cos

    // z * sin

    lda cube_vertices + 2, y
    sta multiply_a
    lda rotate_sin
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi

    // x' = x*cos - z*sin  (multiply_result_hi holds z*sin at this point)

    sec
    lda rotate_temp
    sbc multiply_result_hi
    sta rotated_vertices + 0, y

    //--------------------------------------------------
    // y' = y  (yaw leaves Y untouched)
    //--------------------------------------------------

    lda cube_vertices + 1, y
    sta rotated_vertices + 1, y

    //--------------------------------------------------
    // z' = x * sin(θ) + z * cos(θ)
    //--------------------------------------------------

    // x * sin

    lda cube_vertices + 0, y
    sta multiply_a
    lda rotate_sin
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi
    sta rotate_temp                             // save x*sin

    // z * cos

    lda cube_vertices + 2, y
    sta multiply_a
    lda rotate_cos
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi

    // z' = x*sin + z*cos

    clc
    lda rotate_temp
    adc multiply_result_hi
    sta rotated_vertices + 2, y

    // Advance Y by 3 to the next vertex; stop after the 8th. The loop
    // body is longer than a relative branch can reach ( ~153 bytes, and
    // BNE's range is ±127 ), so we invert the terminal test and jump
    // back via JMP, which has no range limit.

    iny
    iny
    iny
    cpy #24
    beq rotate_vertices_yaw_done
    jmp rotate_vertices_yaw_loop

rotate_vertices_yaw_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: rotate_vertices_pitch
//
// Description:
//
//   Applies a pitch rotation ( around the X axis ) to the eight
//   vertices currently in rotated_vertices, in place. Designed to
//   run AFTER rotate_vertices_yaw so the final pose is yaw-then-
//   pitch.
//
//   Pitch rotation:
//
//     x' = x
//     y' = y * cos(φ) - z * sin(φ)
//     z' = y * sin(φ) + z * cos(φ)
//
//   φ is taken from pitch_angle, same 256-steps-per-turn encoding
//   as yaw_angle.
//
//   Because the new Y depends on the old Z ( and vice versa ) the
//   loop caches ( y_old, z_old ) in ( pitch_y, pitch_z ) at the top
//   of each iteration. Without the cache the second pair of multiplies
//   would read the already-written y' and produce nonsense.
//
//   Final Y and Z magnitudes can reach ≈ √( 48² + 68² ) ≈ 83 in Q2.6
//   ( combining the ±48 object extent with yaw's √2 stretch ).
//   After project_vertices' >> 2 that's ≈ 20 pixels off-center — just
//   inside the 22 / 23 half-screen allowance.
//
// Inputs:
//
//   pitch_angle      - Current pitch, 0..255 ( 256 steps per revolution ).
//   rotated_vertices - Vertex buffer ( read and written in place ).
//   sin_table        - 256-byte sine LUT, Q1.6.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

rotate_vertices_pitch:

    // Precompute sin(φ) and cos(φ) once per frame.

    ldy pitch_angle
    lda sin_table, y
    sta rotate_sin

    tya
    clc
    adc #$40                                    // cos(φ) = sin(φ + 90°)
    tay
    lda sin_table, y
    sta rotate_cos

    ldy #$00

rotate_vertices_pitch_loop:

    // Cache y_old and z_old — each is read twice across the four
    // multiplies below, and the first write-back would otherwise
    // clobber y_old before the z' computation can read it.

    lda rotated_vertices + 1, y
    sta pitch_y
    lda rotated_vertices + 2, y
    sta pitch_z

    //--------------------------------------------------
    // y' = y * cos(φ) - z * sin(φ)
    //--------------------------------------------------

    // y * cos

    lda pitch_y
    sta multiply_a
    lda rotate_cos
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi
    sta rotate_temp                             // save y*cos

    // z * sin

    lda pitch_z
    sta multiply_a
    lda rotate_sin
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi

    // y' = y*cos - z*sin

    sec
    lda rotate_temp
    sbc multiply_result_hi
    sta rotated_vertices + 1, y

    //--------------------------------------------------
    // z' = y * sin(φ) + z * cos(φ)
    //--------------------------------------------------

    // y * sin

    lda pitch_y
    sta multiply_a
    lda rotate_sin
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi
    sta rotate_temp                             // save y*sin

    // z * cos

    lda pitch_z
    sta multiply_a
    lda rotate_cos
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi

    // z' = y*sin + z*cos

    clc
    lda rotate_temp
    adc multiply_result_hi
    sta rotated_vertices + 2, y

    // Advance Y by 3. Loop body is too long for a relative branch,
    // so invert the terminal test and use JMP, same pattern as yaw.

    iny
    iny
    iny
    cpy #24
    beq rotate_vertices_pitch_done
    jmp rotate_vertices_pitch_loop

rotate_vertices_pitch_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: translate_vertices
//
// Description:
//
//   Adds the signed Q2.6 translate_x / translate_y / translate_z
//   offsets to every rotated vertex in place. Runs after both
//   rotation passes and before projection, so the offsets are in
//   world / view space ( i.e. the cube moves relative to the camera
//   along the camera's own axes, not the object's ).
//
//   Simple byte-wise ADC loop, no multiplies. Y walks the 24-byte
//   rotated_vertices buffer three bytes at a time.
//
// Inputs:   translate_x, translate_y, translate_z; rotated_vertices.
// Outputs:  rotated_vertices ( mutated in place ).
// Clobbers: A, Y.
//
//------------------------------------------------------------------------------

translate_vertices:

    ldy #$00

translate_vertices_loop:

    lda rotated_vertices + 0, y
    clc
    adc translate_x
    sta rotated_vertices + 0, y

    lda rotated_vertices + 1, y
    clc
    adc translate_y
    sta rotated_vertices + 1, y

    lda rotated_vertices + 2, y
    clc
    adc translate_z
    sta rotated_vertices + 2, y

    iny
    iny
    iny
    cpy #$18                                    // 8 vertices × 3 bytes = 24
    bne translate_vertices_loop

    rts

//------------------------------------------------------------------------------
//
// Subroutine: project_vertices
//
// Description:
//
//   Perspective projection of the eight rotated vertices into
//   pseudo-pixel screen coordinates. For each triple ( x, y, z ) in
//   rotated_vertices (signed Q2.6):
//
//     depth       = VIEWER_DISTANCE - rotated_z
//     scale       = inv_depth_focal[ depth ]         // Q1.7, pre-computed
//     pixel_x     = ( rotated_x * scale ) >> 7
//     pixel_y     = ( rotated_y * scale ) >> 7
//     screen_x    = pixel_x + SCREEN_CENTER_X
//     screen_y    = SCREEN_CENTER_Y - pixel_y        // flip ( +Y is up in world )
//
//   The inv_depth_focal table stores ( 128 × PROJECTION_FOCAL / depth )
//   rounded to an 8-bit unsigned byte. Multiplying by this value and
//   shifting right 7 recovers ( rotated_x × PROJECTION_FOCAL / depth ),
//   which is the classical perspective formula. The shift right 7 is
//   implemented as ( asl lo ; rol hi ) then taking the high byte — i.e.
//   shift the 16-bit product LEFT by one and read bits 15..8, which is
//   equivalent to arithmetic shift RIGHT by 7 and correctly preserves
//   the sign of the rotated coordinate.
//
//   At depth = VIEWER_DISTANCE the scale reduces to PROJECTION_FOCAL /
//   VIEWER_DISTANCE = 40/160 = 1/4, matching the old orthographic
//   scale — so the cube at Z = 0 looks the same as before, and only
//   vertices displaced in ±Z change size.
//
//   Y flip uses the two's-complement identity ~A + 1 = -A :
//
//     SCREEN_CENTER_Y - pixel_y = ( SCREEN_CENTER_Y + 1 ) + ~pixel_y
//
//   one EOR #$FF then ADC #( SCREEN_CENTER_Y + 1 ) does the flip and
//   translate in a single sequence.
//
//   Register usage: Y is preserved across multiply_signed_8 (which
//   only clobbers A and X), so Y serves as the vertex-index loop
//   counter across the two multiply calls. X is reloaded from
//   project_byte_offset each time it's needed.
//
// Inputs:   rotated_vertices, inv_depth_focal
// Outputs:  screen_x[ 0..7 ], screen_y[ 0..7 ]
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

project_vertices:

    lda #$00
    sta project_byte_offset
    ldy #$00                                    // Y = vertex index (survives multiply calls)

project_vertices_loop:

    //--- Compute depth and look up the Q1.7 scale factor. ---

    ldx project_byte_offset
    lda #VIEWER_DISTANCE
    sec
    sbc rotated_vertices + 2, x                 // A = VIEWER_DISTANCE - rotated_z
    tax
    lda inv_depth_focal, x
    sta project_scale

    //--- X: pixel_x = ( rotated_x * scale ) >> 7 + SCREEN_CENTER_X ---

    ldx project_byte_offset
    lda rotated_vertices + 0, x
    sta multiply_a
    lda project_scale
    sta multiply_b
    jsr multiply_signed_8

    asl multiply_result_lo                      // Shift product left 1 so the
    rol multiply_result_hi                      // high byte becomes product/128.
    lda multiply_result_hi                      // A = signed pixel_x offset

    //--- Aspect correction: multiply X offset by ASPECT_FACTOR / 128. ---
    //
    // VIC-20 pseudo-pixels are wider than tall, so the horizontal pixel
    // offset is compressed by ASPECT_FACTOR (Q1.7 fraction of unity,
    // declared at the top of the file). A signed 8×8 multiply produces
    // a 16-bit product; one ASL/ROL pair then taking the high byte is
    // ( product << 1 ) >> 8 = product >> 7, the Q1.7 scaling.
    //
    // Changing the aspect ratio is a single-line edit at ASPECT_FACTOR —
    // no code change here. See zoom stage below for the same pattern
    // specialised to Q1.6.

    sta multiply_a
    lda #ASPECT_FACTOR
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi                      // A = pixel_x * ASPECT_FACTOR / 128

    //--- Zoom: multiply X offset by zoom_factor ( Q1.6 ), >> 6. ---
    //
    // zoom_factor = $40 ( 64 ) is unity; smaller shrinks, larger grows.
    // multiply_signed_8 preserves sign; two ASL/ROL pairs then take
    // the high byte implements ( product * 4 ) / 256 = product / 64,
    // i.e. arithmetic >> 6. Because zoom_factor is always in [0, 127]
    // it reads as a positive signed byte and the product's sign tracks
    // the input pixel offset.

    sta multiply_a
    lda zoom_factor
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi                      // A = pixel_x * zoom / 64

    clc
    adc #SCREEN_CENTER_X
    sta screen_x, y

    //--- Y: pixel_y = ( rotated_y * scale ) >> 7, zoom, flip + translate. ---

    ldx project_byte_offset
    lda rotated_vertices + 1, x
    sta multiply_a
    lda project_scale
    sta multiply_b
    jsr multiply_signed_8

    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi                      // A = raw signed pixel_y offset

    //--- Zoom for Y (same pattern as X). ---

    sta multiply_a
    lda zoom_factor
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi                      // A = pixel_y * zoom / 64

    eor #$FF                                    // A = ~offset
    clc
    adc #( SCREEN_CENTER_Y + 1 )                // A = CENTER_Y - offset
    sta screen_y, y

    //--- Advance to the next vertex. Body now exceeds BNE range, so
    //    the terminal test is inverted and a JMP trampolines back.

    lda project_byte_offset
    clc
    adc #$03
    sta project_byte_offset
    iny
    cpy #$08
    beq project_vertices_done
    jmp project_vertices_loop

project_vertices_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: draw_edges
//
// Description:
//
//   Iterates the 12-entry cube_edges table and draws each edge via
//   draw_line. Each table entry is a pair of vertex indices ( v0, v1 )
//   that reference the parallel screen_x / screen_y arrays produced
//   by project_vertices. For each edge:
//
//     line_x0 = screen_x[ v0 ],  line_y0 = screen_y[ v0 ]
//     line_x1 = screen_x[ v1 ],  line_y1 = screen_y[ v1 ]
//     jsr draw_line
//
//   A single byte (edge_index) holds the current byte offset into
//   cube_edges (0, 2, 4, ..., 22). It lives in memory rather than a
//   register because draw_line clobbers A, X, and Y.
//
// Inputs:
//
//   screen_x[ 0..7 ], screen_y[ 0..7 ] - projected pseudo-pixel coords.
//   cube_edges                         - 12 × 2 bytes of vertex indices.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

draw_edges:

    lda #$00
    sta edge_index

draw_edges_loop:

    ldy edge_index

    // Look up endpoint 0 via its vertex index.

    lda cube_edges + 0, y                       // A = v0 index (0..7)
    tax
    lda screen_x, x
    sta line_x0
    lda screen_y, x
    sta line_y0

    // Look up endpoint 1 via its vertex index.

    lda cube_edges + 1, y                       // A = v1 index
    tax
    lda screen_x, x
    sta line_x1
    lda screen_y, x
    sta line_y1

    jsr draw_line

    // Advance to the next edge record (2 bytes per entry).

    lda edge_index
    clc
    adc #$02
    sta edge_index
    cmp #24                                     // 12 edges × 2 bytes
    bne draw_edges_loop

    rts

//==============================================================================
// Subroutines — Input
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: poll_keyboard
//
// Description:
//
//   Reads at most one pending key from the KERNAL keyboard buffer via
//   GETIN ( $FFE4 ) and dispatches it. SPACE always toggles
//   control_mode ( auto-rotate ↔ keyboard-control ). Every other
//   mapped key is a no-op in auto mode and only takes effect in
//   keyboard-control mode.
//
//   Key map ( PETSCII, unshifted on the VIC-20's upper/graphics set,
//   which returns uppercase letter codes $41..$5A ):
//
//     SPACE ($20)  toggle control_mode
//     W     ($57)  yaw   −= 1
//     R     ($52)  yaw   += 1
//     E     ($45)  pitch −= 1
//     D     ($44)  pitch += 1
//     S     ($53)  translate_x −= 1
//     F     ($46)  translate_x += 1
//     T     ($54)  translate_y += 1
//     G     ($47)  translate_y −= 1
//     Q     ($51)  translate_z += 1
//     A     ($41)  translate_z −= 1
//     +     ($2B)  zoom_factor += 4
//     −     ($2D)  zoom_factor −= 4
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

poll_keyboard:

    jsr KERNAL_GETIN                            // A = key or 0 if buffer empty
    tax
    bne poll_keyboard_has_key
    rts                                         // no key pending — short trampoline

poll_keyboard_has_key:

    // --- Function keys: state-machine transitions. Active in all states. ---

    cmp #KEY_F1
    bne poll_keyboard_not_f1
    jsr handle_f1
    rts
poll_keyboard_not_f1:

    cmp #KEY_F2
    bne poll_keyboard_not_f2
    jsr handle_f2
    rts
poll_keyboard_not_f2:

    cmp #KEY_F3
    bne poll_keyboard_not_f3
    jsr handle_f3
    rts
poll_keyboard_not_f3:

    // Gameplay keys (space, w/r/e/d/q/a/t/g/s/f, +/-) are only active
    // while the 3D pipeline is running — i.e. STATE_MAIN.

    lda screen_state
    cmp #STATE_MAIN
    bne poll_keyboard_done

    txa                                         // restore key into A

    // --- SPACE: flip control_mode bit 0 ( auto ↔ keyboard ). ---

    cmp #$20
    bne poll_keyboard_not_space
    lda control_mode
    eor #$01
    sta control_mode
    rts

poll_keyboard_not_space:

    // Motion keys are inert in auto mode. In keyboard-control mode they
    // dispatch through motion_keys / motion_addrs_lo / motion_addrs_hi /
    // motion_deltas: find the key in motion_keys, then add the signed
    // delta from motion_deltas to the byte at the target address.

    lda control_mode
    beq poll_keyboard_done

    txa                                         // restore key into A
    ldx #MOTION_TABLE_LAST                      // scan from last entry down

poll_keyboard_motion_loop:

    cmp motion_keys, x
    beq poll_keyboard_motion_hit
    dex
    bpl poll_keyboard_motion_loop
    rts                                         // key not in table → ignore

poll_keyboard_motion_hit:

    lda motion_addrs_lo, x
    sta ZP_PTR_1
    lda motion_addrs_hi, x
    sta ZP_PTR_1 + 1
    lda motion_deltas, x
    ldy #$00
    clc
    adc (ZP_PTR_1), y
    sta (ZP_PTR_1), y

poll_keyboard_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: handle_f1
//
// Description:
//
//   F1 key dispatch. Behavior depends on screen_state:
//
//     STATE_HOME       → STATE_HELP         ( show standalone help )
//     STATE_MAIN       → STATE_MAIN_HELP    ( overlay help on frozen cube )
//     STATE_MAIN_HELP  → STATE_MAIN         ( resume animation; cube redraw
//                                              overwrites help next frame )
//     STATE_HELP       → STATE_HOME         ( back to title screen )
//
//   Rendering side effects happen here so the calling main_loop can stay
//   a simple state-dispatch spin.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

handle_f1:

    lda screen_state
    cmp #STATE_HOME
    beq handle_f1_home_to_help
    cmp #STATE_MAIN
    beq handle_f1_main_to_mainhelp
    cmp #STATE_MAIN_HELP
    beq handle_f1_mainhelp_to_main
    cmp #STATE_HELP
    beq handle_f1_help_to_home
    rts

handle_f1_home_to_help:

    lda #STATE_HELP
    sta screen_state
    jsr clear_screen_and_colors
    jsr render_help_screen
    rts

handle_f1_main_to_mainhelp:

    lda #STATE_MAIN_HELP
    sta screen_state
    jsr clear_screen_and_colors                 // full-screen help, not overlay
    jsr render_help_screen
    rts

handle_f1_mainhelp_to_main:

    lda #STATE_MAIN
    sta screen_state
    jsr clear_screen_and_colors                 // fresh canvas for resumed cube
    rts

handle_f1_help_to_home:

    lda #STATE_HOME
    sta screen_state
    jsr clear_screen_and_colors
    jsr render_home_screen
    rts

//------------------------------------------------------------------------------
//
// Subroutine: handle_f2
//
// Description:
//
//   F2 starts the main animation loop — only valid from STATE_HOME. Clears
//   screen + color RAM so the cube renders on a clean slate.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

handle_f2:

    lda screen_state
    cmp #STATE_HOME
    bne handle_f2_done
    lda #STATE_MAIN
    sta screen_state
    jsr clear_screen_and_colors
handle_f2_done:
    rts

//------------------------------------------------------------------------------
//
// Subroutine: handle_f3
//
// Description:
//
//   F3 always returns to the home screen from any non-home state:
//   STATE_MAIN, STATE_MAIN_HELP, or STATE_HELP. Ignored from STATE_HOME
//   where it'd be a genuine no-op.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

handle_f3:

    lda screen_state
    cmp #STATE_MAIN
    beq handle_f3_to_home
    cmp #STATE_MAIN_HELP
    beq handle_f3_to_home
    cmp #STATE_HELP
    beq handle_f3_to_home
    rts

handle_f3_to_home:

    lda #STATE_HOME
    sta screen_state
    jsr clear_screen_and_colors
    jsr render_home_screen
    rts

//------------------------------------------------------------------------------
//
// Subroutine: clear_screen_and_colors
//
// Description:
//
//   Fills the visible screen matrix ( SCREEN_RAM, 506 bytes starting at
//   $1E00 ) with the empty-cell screen code ( $20 ) and the color RAM
//   mirror ( COLOR_RAM, $9600 ) with white. Used on every state entry
//   that needs a clean slate ( HOME, HELP, MAIN ). Not used when
//   entering MAIN_HELP — that state overlays help on top of the frozen
//   cube and must preserve the existing SCREEN_RAM contents.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

clear_screen_and_colors:

    // First pass: fill SCREEN_RAM with the space ($20) screen code.

    lda #$20
    ldx #$00
clear_screen_page_1:
    sta SCREEN_RAM, x
    inx
    bne clear_screen_page_1

clear_screen_page_2:
    sta SCREEN_RAM + $100, x
    inx
    cpx #SCREEN_SIZE - $100                     // 250 remaining bytes
    bne clear_screen_page_2

    // Second pass: fill COLOR_RAM with white.

    lda #COLOR_WHITE
    ldx #$00
clear_color_page_1:
    sta COLOR_RAM, x
    inx
    bne clear_color_page_1

clear_color_page_2:
    sta COLOR_RAM + $100, x
    inx
    cpx #SCREEN_SIZE - $100
    bne clear_color_page_2

    rts

//------------------------------------------------------------------------------
//
// Subroutine: render_text_table
//
// Description:
//
//   Walks a data-driven screen layout table pointed to by ZP_PTR_1 and
//   writes each entry to SCREEN_RAM + COLOR_RAM. Each entry is:
//
//     .byte row, col, color, length
//     .byte ch0, ch1, ..., ch(length-1)   // screen codes
//
//   The table is terminated by a row byte of $FF.
//
//   For each entry we compute:
//
//     screen_addr = SCREEN_RAM + row * 22 + col   (via screen_row_lo/hi)
//     color_addr  = COLOR_RAM  + row * 22 + col   (same offset, hi+$78)
//
//   and fill both regions for `length` bytes.
//
// Inputs:    ZP_PTR_1 — table pointer
// Clobbers:  A, X, Y, ZP_PTR_1, ZP_PTR_2
//
//------------------------------------------------------------------------------

render_text_table:

render_text_entry_loop:

    ldy #$00
    lda (ZP_PTR_1), y                           // row
    cmp #$FF
    beq render_text_table_done

    tax                                         // X = row (index into screen_row tables)
    iny
    lda (ZP_PTR_1), y                           // col
    sta render_col
    iny
    lda (ZP_PTR_1), y                           // color
    sta render_color
    iny
    lda (ZP_PTR_1), y                           // length
    sta render_length

    // Compute screen-RAM address into ZP_PTR_2 (full 16-bit with carry).

    lda screen_row_lo, x
    clc
    adc render_col
    sta ZP_PTR_2
    lda screen_row_hi, x
    adc #$00
    sta ZP_PTR_2 + 1

    // Advance ZP_PTR_1 past the 4-byte header so it points at the first char.

    lda ZP_PTR_1
    clc
    adc #$04
    sta ZP_PTR_1
    bcc render_text_header_no_carry
    inc ZP_PTR_1 + 1
render_text_header_no_carry:

    // Write screen codes.

    ldy #$00
render_text_char_loop:
    cpy render_length
    beq render_text_chars_done
    lda (ZP_PTR_1), y
    sta (ZP_PTR_2), y
    iny
    bne render_text_char_loop                   // length always < 256

render_text_chars_done:

    // Switch destination to COLOR_RAM ( +$78 on the high byte ) and fill.

    lda ZP_PTR_2 + 1
    clc
    adc #$78                                    // COLOR_RAM - SCREEN_RAM high byte
    sta ZP_PTR_2 + 1

    ldy #$00
render_text_color_loop:
    cpy render_length
    beq render_text_colors_done
    lda render_color
    sta (ZP_PTR_2), y
    iny
    bne render_text_color_loop

render_text_colors_done:

    // Advance ZP_PTR_1 past the text bytes to the next entry.

    lda ZP_PTR_1
    clc
    adc render_length
    sta ZP_PTR_1
    bcc render_text_advance_no_carry
    inc ZP_PTR_1 + 1
render_text_advance_no_carry:

    jmp render_text_entry_loop

render_text_table_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: render_home_screen
//
// Description:
//
//   Loads the home_screen_data pointer into ZP_PTR_1 and calls
//   render_text_table. Assumes the screen has been cleared first.
//
//------------------------------------------------------------------------------

render_home_screen:

    lda #<home_screen_data
    sta ZP_PTR_1
    lda #>home_screen_data
    sta ZP_PTR_1 + 1
    jmp render_text_table                       // tail call

//------------------------------------------------------------------------------
//
// Subroutine: render_help_screen
//
// Description:
//
//   Loads the help_screen_data pointer into ZP_PTR_1 and calls
//   render_text_table. When called from STATE_MAIN_HELP ( overlay case )
//   the screen is NOT cleared first — help text writes on top of the
//   frozen cube.
//
//------------------------------------------------------------------------------

render_help_screen:

    lda #<help_screen_data
    sta ZP_PTR_1
    lda #>help_screen_data
    sta ZP_PTR_1 + 1
    jmp render_text_table                       // tail call

//==============================================================================
// Data
//==============================================================================

.encoding "petscii_upper"

//------------------------------------------------------------------------------
// Mask → screen code table.
//
// Indexed by a 4-bit quadrant mask. Values are SCREEN CODES (not PETSCII)
// because plot_pixel writes directly to screen memory at $1E00.
//
// Screen-code derivation for the default upper / graphics character set:
//
//   PETSCII $20         → screen code $20  (space, same range)
//   PETSCII $A0-$BF     → screen code $60-$7F  (subtract $40)
//   reverse video       → add $80 to the screen code
//
// Mapping:
//
//   mask  quadrants            PETSCII        screen code
//   ----  -------------------  -------------  -----------
//   $00   none                 $20 space      $20
//   $01   TL                   $BE            $7E
//   $02   TR                   $BC            $7C
//   $03   TL+TR (upper half)   reverse $A2    $E2
//   $04   BL                   $BB            $7B
//   $05   TL+BL (left half)    $A1            $61
//   $06   TR+BL                reverse $BF    $FF
//   $07   TL+TR+BL             reverse $AC    $EC
//   $08   BR                   $AC            $6C
//   $09   TL+BR (back-diag)    $BF            $7F
//   $0A   TR+BR (right half)   reverse $A1    $E1
//   $0B   TL+TR+BR             reverse $BB    $FB
//   $0C   BL+BR (lower half)   $A2            $62
//   $0D   TL+BL+BR             reverse $BC    $FC
//   $0E   TR+BL+BR             reverse $BE    $FE
//   $0F   all (solid)          reverse space  $A0
//
// NOTE: verify visually in VICE and adjust if any entries render
//       incorrectly against the VIC-20 character ROM.
//------------------------------------------------------------------------------

mask_to_screen_code:

    .byte $20                                   // 0000: empty
    .byte $7E                                   // 0001: TL
    .byte $7C                                   // 0010: TR
    .byte $E2                                   // 0011: TL + TR          (upper half)
    .byte $7B                                   // 0100: BL
    .byte $61                                   // 0101: TL + BL          (left half)
    .byte $FF                                   // 0110: TR + BL          (reverse diag)
    .byte $EC                                   // 0111: TL + TR + BL     (reverse BR)
    .byte $6C                                   // 1000: BR
    .byte $7F                                   // 1001: TL + BR          (back-diag)
    .byte $E1                                   // 1010: TR + BR          (right half)
    .byte $FB                                   // 1011: TL + TR + BR     (reverse BL)
    .byte $62                                   // 1100: BL + BR          (lower half)
    .byte $FC                                   // 1101: TL + BL + BR     (reverse TR)
    .byte $FE                                   // 1110: TR + BL + BR     (reverse TL)
    .byte $A0                                   // 1111: all              (solid block)

//------------------------------------------------------------------------------
// Quadrant index → pixel mask table.
//
// pixel_mask_table[q] = 1 << q, for q in 0..3. Used by plot_pixel in place
// of a runtime shift loop.
//------------------------------------------------------------------------------

pixel_mask_table:

    .byte $01                                   // quadrant 0: top-left
    .byte $02                                   // quadrant 1: top-right
    .byte $04                                   // quadrant 2: bottom-left
    .byte $08                                   // quadrant 3: bottom-right

//------------------------------------------------------------------------------
// Row start address tables.
//
// row_start_lo[r] / row_start_hi[r] = low / high byte of
// ( back_buffer + r * SCREEN_COLUMNS ). Replaces a per-plot multiply
// by 22. Points at the back buffer rather than SCREEN_RAM because
// plot_pixel writes into the off-screen buffer; completed frames
// are pushed to the visible display by copy_buffer_to_screen.
//
// Generated at assembly time with Kick Assembler's .fill iterator `i`.
//------------------------------------------------------------------------------

row_start_lo:

    .fill SCREEN_ROWS, <( back_buffer + i * SCREEN_COLUMNS )

row_start_hi:

    .fill SCREEN_ROWS, >( back_buffer + i * SCREEN_COLUMNS )

//------------------------------------------------------------------------------
// Screen code → quadrant mask reverse lookup.
//
// 256-byte table indexed directly by any screen code read from screen RAM.
// Pre-zeroed at assembly time; init_plot_tables patches the 16 entries
// that correspond to valid quadrant characters. Any other screen code
// reads back as mask 0, so unknown characters on screen are treated as
// empty cells the first time plot_pixel touches them.
//------------------------------------------------------------------------------

screen_code_to_mask:

    .fill 256, $00

//------------------------------------------------------------------------------
// Unit cube geometry (object space).
//
// Eight vertices, stored as Q2.6 signed 8-bit triples ( x, y, z ).
// The cube is scaled to corners at ±0.625 ( = ±40 in Q2.6 ). Smaller
// than a unit cube for two reasons:
//
//   1. yaw+pitch rotation stretches ±40 → max √3 × 40 ≈ 69 on any
//      single axis (sphere-of-rotation argument).
//   2. Under perspective projection with VIEWER_DISTANCE = 160, the
//      closest vertex sits at depth ≈ 91 with projection scale ≈ 56/128.
//      Analytic max pixel offset is 19 — inside the 22-pixel half
//      width with margin for arithmetic rounding.
//
// A larger cube would either overflow screen bounds near the cube's
// closest face or force a 16-bit depth register.
//
// Coordinate convention:
//
//     +X = right
//     +Y = up                      (screen-space +Y is flipped at projection)
//     +Z = toward viewer
//
// Vertex numbering (front face = -Z, back face = +Z):
//
//         7----------6
//        /|         /|          +Y
//       / |        / |           ^
//      3----------2  |           |
//      |  4-------|--5           +----> +X
//      | /        | /           /
//      |/         |/           +Z
//      0----------1
//
//------------------------------------------------------------------------------

cube_vertices:

    .byte -40, -40, -40                         // 0: left,  bottom, front
    .byte  40, -40, -40                         // 1: right, bottom, front
    .byte  40,  40, -40                         // 2: right, top,    front
    .byte -40,  40, -40                         // 3: left,  top,    front
    .byte -40, -40,  40                         // 4: left,  bottom, back
    .byte  40, -40,  40                         // 5: right, bottom, back
    .byte  40,  40,  40                         // 6: right, top,    back
    .byte -40,  40,  40                         // 7: left,  top,    back

//------------------------------------------------------------------------------
// Unit cube edges.
//
// Twelve edges, each stored as a pair of vertex indices ( v0, v1 )
// referencing cube_vertices. draw_edges walks this list to emit the
// wire-frame outline via draw_line.
//------------------------------------------------------------------------------

cube_edges:

    .byte  0,  1                                // front face, bottom
    .byte  1,  2                                // front face, right
    .byte  2,  3                                // front face, top
    .byte  3,  0                                // front face, left
    .byte  4,  5                                // back  face, bottom
    .byte  5,  6                                // back  face, right
    .byte  6,  7                                // back  face, top
    .byte  7,  4                                // back  face, left
    .byte  0,  4                                // connector, left-bottom
    .byte  1,  5                                // connector, right-bottom
    .byte  2,  6                                // connector, right-top
    .byte  3,  7                                // connector, left-top

//------------------------------------------------------------------------------
// Sine table.
//
// 256-entry lookup covering a full revolution. Indexed by an 8-bit
// unsigned angle where one turn = 256 steps:
//
//     $00 =   0°        $40 =  90°        $80 = 180°        $C0 = 270°
//
// Values are signed Q1.6: +64 = +1.0, -64 = -1.0. Cosine is obtained
// by indexing at ( angle + $40 ) since cos(θ) = sin(θ + 90°).
//
// Generated at assembly time via Kick Assembler's sin() intrinsic.
//------------------------------------------------------------------------------

sin_table:

    .fill 256, round( 64 * sin( i * 2 * PI / 256 ) )

//------------------------------------------------------------------------------
// Perspective 1/depth lookup.
//
// Indexed by an 8-bit unsigned depth value. Each entry is:
//
//     inv_depth_focal[ d ] = round( 128 * PROJECTION_FOCAL / d )       (Q1.7)
//
// project_vertices multiplies rotated_x (or _y) by this value and then
// takes the high byte of the product-left-shifted-by-one, which is
// equivalent to ( rotated * PROJECTION_FOCAL / d ) — the perspective
// pixel offset.
//
// Only depths in the range [91, 229] are reached in practice ( cube
// ±40 under yaw+pitch with VIEWER_DISTANCE = 160 ). Entries outside
// that range are computed anyway but aren't touched at runtime; d = 0
// would divide by zero, so we clamp the denominator with max(1, i).
// The byte-wise result is masked to 8 bits for small-d entries whose
// true Q1.7 value exceeds 255.
//------------------------------------------------------------------------------

inv_depth_focal:

    .fill 256, round( 128 * PROJECTION_FOCAL / max( 1, i ) ) & $FF

//------------------------------------------------------------------------------
// Screen-RAM row start addresses.
//
// Mirrors row_start_lo / row_start_hi but targets SCREEN_RAM ( $1E00 )
// instead of back_buffer. Used by render_text_table to position text on
// the visible screen without touching the 3D pipeline's double buffer.
//------------------------------------------------------------------------------

screen_row_lo:

    .fill SCREEN_ROWS, < ( SCREEN_RAM + i * SCREEN_COLUMNS )

screen_row_hi:

    .fill SCREEN_ROWS, > ( SCREEN_RAM + i * SCREEN_COLUMNS )

//------------------------------------------------------------------------------
// Motion-key dispatch tables.
//
// poll_keyboard scans motion_keys for a match, then uses the matched
// index to read motion_addrs_lo / motion_addrs_hi (the target state
// variable) and motion_deltas (the signed per-press step). Keeping
// these as four parallel arrays lets the dispatcher use a single
// X register as both the key search cursor and the value-table index.
//
// Table order is not significant to behavior — the per-key effect is
// defined by each entry's addr + delta pair. Organised here as W/R/E/D
// rotation, then S/F/T/G/Q/A translation, then +/- zoom.
//------------------------------------------------------------------------------

motion_keys:

    .byte $57, $52, $45, $44                    // W, R, E, D  (yaw-, yaw+, pitch-, pitch+)
    .byte $53, $46, $54, $47, $51, $41          // S, F, T, G, Q, A (translate x-,x+,y+,y-,z+,z-)
    .byte $2B, $2D                              // +, - (zoom+, zoom-)

motion_addrs_lo:

    .byte <yaw_angle,    <yaw_angle,    <pitch_angle,  <pitch_angle
    .byte <translate_x,  <translate_x,  <translate_y,  <translate_y,  <translate_z,  <translate_z
    .byte <zoom_factor,  <zoom_factor

motion_addrs_hi:

    .byte >yaw_angle,    >yaw_angle,    >pitch_angle,  >pitch_angle
    .byte >translate_x,  >translate_x,  >translate_y,  >translate_y,  >translate_z,  >translate_z
    .byte >zoom_factor,  >zoom_factor

motion_deltas:

    .byte -ROTATION_STEP,    ROTATION_STEP,    -ROTATION_STEP,    ROTATION_STEP
    .byte -TRANSLATION_STEP, TRANSLATION_STEP, TRANSLATION_STEP, -TRANSLATION_STEP, TRANSLATION_STEP, -TRANSLATION_STEP
    .byte ZOOM_STEP,         -ZOOM_STEP

//------------------------------------------------------------------------------
// Home and help screen layout tables.
//
// Each entry: .byte row, col, color, length
//             .text "..."      ( length bytes of SCREEN CODES )
//
// Terminated by a row byte of $FF. Encoded with screencode_upper so the
// text strings expand straight into the 22 x 23 character matrix.
//------------------------------------------------------------------------------

.encoding "screencode_upper"

home_screen_data:

    .byte  0,  7, COLOR_WHITE, 7
    .text  "3D CUBE"
    .byte  1,  5, COLOR_BLUE, 11
    .text  "VERSION 1.0"
    .byte  3,  7, COLOR_WHITE, 7
    .text  "F1 HELP"
    .byte  4,  7, COLOR_WHITE, 8
    .text  "F2 START"
    .byte 21,  3, COLOR_CYAN,  16
    .text  "BY ROHIN GOSLING"
    .byte  $FF                                  // terminator

help_screen_data:

    .byte  0,  7, COLOR_WHITE, 7
    .text  "3D CUBE"
    .byte  1,  5, COLOR_BLUE, 11
    .text  "VERSION 1.0"

    // Controls (abbreviated to fit below SCREEN_RAM; keeps same semantics).
    .byte  3,  1, COLOR_WHITE, 18
    .text  "+ -    ZOOM IN/OUT"
    .byte  4,  1, COLOR_WHITE, 17
    .text  "W R    Y-ROTATION"
    .byte  5,  1, COLOR_WHITE, 17
    .text  "E D    X-ROTATION"
    .byte  6,  1, COLOR_WHITE, 20
    .text  "Q A    Z-TRANSLATION"
    .byte  7,  1, COLOR_WHITE, 20
    .text  "T G    Y-TRANSLATION"
    .byte  8,  1, COLOR_WHITE, 20
    .text  "S F    X-TRANSLATION"
    .byte  9,  1, COLOR_WHITE, 20
    .text  "SPACE  TOGGLE ROTATE"
    .byte  10,  1, COLOR_WHITE, 18
    .text  "F1     TOGGLE HELP"
    .byte 11,  1, COLOR_WHITE, 16
    .text  "F3     MAIN MENU"

    // Coordinate-system diagram    
    .byte 14, 10, COLOR_WHITE, 1
    .text  "Y"
    .byte 15, 10, COLOR_GREEN, 1
    .byte  $5D
    .byte 15, 13, COLOR_WHITE, 1
    .text  "Z"
    .byte 16, 10, COLOR_GREEN, 3
    .byte  $5D, $20, $4E
    .byte 17, 10, COLOR_GREEN, 2
    .byte  $5D, $4E
    .byte 18,  5, COLOR_WHITE, 2
    .text  "-X"
    .byte 18,  7, COLOR_GREEN, 7
    .byte  $40, $40, $40, $5B, $40, $40, $40
    .byte 18, 14, COLOR_WHITE, 1
    .text  "X"
    .byte 19,  9, COLOR_GREEN, 2
    .byte  $4E, $5D
    .byte 20,  8, COLOR_GREEN, 3
    .byte  $4E, $20, $5D
    .byte 21,  6, COLOR_WHITE, 2
    .text  "-Z"
    .byte 21, 10, COLOR_GREEN, 1
    .byte  $5D
    .byte 22,  9, COLOR_WHITE, 2
    .text  "-Y"
    .byte $FF                                  // terminator

.encoding "petscii_upper"

//------------------------------------------------------------------------------
// plot_pixel working storage.
//------------------------------------------------------------------------------

plot_x:

    .byte $00                                   // Saved pixel_x for cell-column computation

plot_pixel_mask:

    .byte $00                                   // Quadrant bit mask for the current plot

//------------------------------------------------------------------------------
// Bresenham line-drawing working storage.
//------------------------------------------------------------------------------

line_x0:

    .byte $00                                   // Start x (also the current x during the run)

line_y0:

    .byte $00                                   // Start y (also the current y during the run)

line_x1:

    .byte $00                                   // End x

line_y1:

    .byte $00                                   // End y

line_dx:

    .byte $00                                   // abs( x1 - x0 )

line_dy:

    .byte $00                                   // abs( y1 - y0 )

line_sx:

    .byte $00                                   // x step: $01 or $FF

line_sy:

    .byte $00                                   // y step: $01 or $FF

line_dx2:

    .byte $00                                   // 2 * dx

line_dy2:

    .byte $00                                   // 2 * dy

line_err:

    .byte $00                                   // Signed error accumulator

line_count:

    .byte $00                                   // Loop countdown on the major axis

//------------------------------------------------------------------------------
// Fixed-point math working storage.
//------------------------------------------------------------------------------

multiply_a:

    .byte $00                                   // Signed multiplicand in, abs value out

multiply_b:

    .byte $00                                   // Signed multiplier in, shifted out during the multiply

multiply_sign:

    .byte $00                                   // Bit 7 = sign of the result (XOR of input signs)

multiply_result_lo:

    .byte $00                                   // Low byte of the 16-bit product

multiply_result_hi:

    .byte $00                                   // High byte of the 16-bit product

//------------------------------------------------------------------------------
// 3D pipeline working storage.
//------------------------------------------------------------------------------

rotated_vertices:

    .fill 24, $00                               // 8 vertices x 3 bytes (x, y, z) in Q2.6, post-rotation

screen_x:

    .fill 8, $00                                // Projected pseudo-pixel X per vertex (0..43)

screen_y:

    .fill 8, $00                                // Projected pseudo-pixel Y per vertex (0..45)

vertex_index:

    .byte $00                                   // Loop counter for vertex iteration (0..7)

edge_index:

    .byte $00                                   // Byte offset into cube_edges (0, 2, ..., 22)

project_byte_offset:

    .byte $00                                   // Byte offset into rotated_vertices (0, 3, ..., 21)

project_scale:

    .byte $00                                   // Per-vertex Q1.7 perspective scale from inv_depth_focal

yaw_angle:

    .byte $00                                   // Current yaw, 0..255 (256 steps per full turn)

pitch_angle:

    .byte $00                                   // Current pitch, 0..255 (256 steps per full turn)

rotate_sin:

    .byte $00                                   // sin(current axis angle), precomputed per pass, Q1.6

rotate_cos:

    .byte $00                                   // cos(current axis angle), precomputed per pass, Q1.6

rotate_temp:

    .byte $00                                   // Scratch byte for rotation intermediates (first-multiply high byte)

pitch_y:

    .byte $00                                   // Cached y-coord during in-place pitch (read twice across 4 multiplies)

pitch_z:

    .byte $00                                   // Cached z-coord during in-place pitch

//------------------------------------------------------------------------------
// Interactive-control state.
//
// control_mode selects auto-rotate ( 0 ) or keyboard-control ( 1 ).
// The translate_* bytes are Q2.6 offsets added to every vertex after
// rotation ( see translate_vertices ). zoom_factor is a Q1.6 post-
// projection multiplier: $40 = 1.0x, the projection is scaled via a
// multiply + shift-right-6 in project_vertices.
//------------------------------------------------------------------------------

control_mode:

    .byte $00                                   // 0 = auto-rotate, 1 = keyboard-control

translate_x:

    .byte $00                                   // Q2.6 world-space X offset, signed

translate_y:

    .byte $00                                   // Q2.6 world-space Y offset, signed

translate_z:

    .byte $00                                   // Q2.6 world-space Z offset, signed

zoom_factor:

    .byte $40                                   // Q1.6 post-projection multiplier; $40 = 1.0x, step $04 = 6.25%

//------------------------------------------------------------------------------
// Screen state + text-render scratch.
//------------------------------------------------------------------------------

screen_state:

    .byte STATE_HOME                            // Current UI state; entry boots into home

render_col:

    .byte $00                                   // Current entry's column ( 0..21 )

render_color:

    .byte $00                                   // Current entry's color-RAM value

render_length:

    .byte $00                                   // Current entry's text length

//------------------------------------------------------------------------------
// Back buffer.
//
// 506-byte off-screen mirror of the visible screen matrix. plot_pixel
// and clear_pixel_screen write here; copy_buffer_to_screen pushes the
// completed frame to SCREEN_RAM once per main-loop pass. Initial
// contents are the assembly-time .fill zeros — the first frame's
// clear_pixel_screen call overwrites them with the empty-cell code
// ($20) before any plot_pixel reads.
//------------------------------------------------------------------------------

back_buffer:

    .fill SCREEN_SIZE, $00
