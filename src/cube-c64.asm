//*******************************************************************************
//
// Project:      3D Wire Frame Cube (Commodore 64)
// Version:      1.0
// Release Date: 1990
// Last Updated: 2026-04-29
// Author:       Rohin Gosling
//
// DESCRIPTION:
//
//   A 6502 assembly language program that renders a rotating wire frame
//   cube on a stock Commodore 64, using strategically placed PETSCII
//   quadrant block characters to simulate an 80 x 50 pseudo-pixel
//   resolution on the native 40 x 25 character screen.
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
//   This C64 version is a port of the original VIC-20 3D cube demo. 
//   The 3D pipeline, fixed-point math, sine table, and Bresenham line
//   drawing are unchanged; only the screen geometry, VIC register
//   addresses, BASIC stub, and colour-RAM offset have been adjusted
//   for the C64's 40 x 25 / VIC-II environment.
//
// USAGE:
//
//   LOAD "CUBE-C64", 8, 1
//   RUN
//
// BUILD (run from the v2 / project-root directory):
//
//   java -jar KickAss.jar src/cube-c64.asm -odir ../build
//
// RUN IN VICE (Commodore 64):
//
//   x64sc build/cube.prg
//
// CONTROLS:
//
//   F1       HOME / HELP toggle, or help overlay in MAIN
//   F2       Start cube (HOME -> MAIN)
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
//   ASPECT_FACTOR_X   Horizontal scale, unsigned Q1.7 (128 = unity)
//   ASPECT_FACTOR_Y   Vertical   scale, unsigned Q1.7 (128 = unity)
//
//*******************************************************************************


//==============================================================================
// Constants
//==============================================================================

// KERNAL routines.

.const KERNAL_CHROUT            = $FFD2         // Output character to current device
.const KERNAL_CHRIN             = $FFCF         // Input character from current device
.const KERNAL_GETIN             = $FFE4         // Get character from keyboard buffer

// VIC-II chip registers (Commodore 64).

.const VIC_BORDER_COLOR         = $D020         // Border colour register
.const VIC_BACKGROUND_COLOR     = $D021         // Background colour register
.const VIC_RASTER               = $D012         // Bits 0-7 of the 9-bit raster-line counter

// Raster threshold: $D012 ≥ 251 means the raster beam is past the
// visible area (PAL: lines 0-49 + 250-311 are vblank-ish; visible
// 50-249. NTSC: visible roughly 41-240, total 263 lines). Waiting for
// $D012 ≥ 251 detects vblank reliably on both PAL and NTSC because in
// NTSC the register only reaches values 251-255 inside the
// vertical-retrace interval.

.const VBLANK_RASTER_THRESHOLD  = 251

// Commodore 64 screen memory (default configuration).

.const SCREEN_RAM               = $0400         // Screen character matrix (40 x 25 = 1000 bytes)
.const COLOR_RAM                = $D800         // Color RAM (low nibble per cell)

// Screen dimensions.

.const SCREEN_COLUMNS           = 40            // Characters per row
.const SCREEN_ROWS              = 25            // Rows per screen
.const SCREEN_SIZE              = 1000          // Total cells (40 * 25)

// Pseudo-pixel dimensions (2 x 2 quadrants per character cell).

.const PIXEL_COLUMNS            = 80            // SCREEN_COLUMNS * 2
.const PIXEL_ROWS               = 50            // SCREEN_ROWS    * 2

// Pseudo-pixel screen center (used by the 3D projection stage).

.const SCREEN_CENTER_X          = PIXEL_COLUMNS / 2         // 40
.const SCREEN_CENTER_Y          = PIXEL_ROWS    / 2         // 25

// Perspective projection parameters.
//
//   VIEWER_DISTANCE  - Camera Z position in Q2.6 space. depth = VD - rotated_z.
//   PROJECTION_FOCAL - Focal length; paired with VD so that at depth = VD
//                      the projection scale reduces to focal / VD.
//
// The C64 build keeps the same tuning the VIC-20 used (VD = 170, focal
// = 40, scale at depth = VD reduces to ~1/4). On the larger 80 x 50
// pseudo-pixel grid the cube renders smaller relative to the screen
// than it did on the VIC-20's 44 x 46 — that's fine for a stress-test
// fixture. Tweak PROJECTION_FOCAL upward (e.g. to 80) for a larger
// cube; the depth range stays inside 8-bit unsigned with corners at
// ±40 in Q2.6.

.const VIEWER_DISTANCE          = 130
.const PROJECTION_FOCAL         = 40

// Aspect-ratio correction. Each axis is scaled by its own unsigned
// Q1.7 factor: an offset is multiplied by FACTOR / 128 before zoom is
// applied. 128 = unity ( 1.0× ); values below 128 compress that axis,
// values above 128 stretch it (max ~1.99× at 255, min 0.0× at 0).
//
// The aspect step uses multiply_signed_unsigned_8 so the full 0..255
// range is honoured as an unsigned magnitude — multiply_signed_8
// reads bit 7 as a sign bit, which made values >= 128 collapse the
// cube horizontally on earlier builds.
//
// Defaults: 128 / 128 = 1.0× on both axes (no aspect correction). The
// C64's 80 x 50 pseudo-pixel grid is built from 2 x 2 quadrants of
// square 8 x 8 character cells, so unity is a sensible starting
// point. Tune these if the cube looks too narrow / tall on your
// monitor — e.g. ASPECT_FACTOR_X = round( 128 * 5 / 4 ) for a 1.25×
// horizontal stretch.

.const ASPECT_FACTOR_X          = 128
.const ASPECT_FACTOR_Y          = 116

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
//   STATE_HOME       - Static home / title screen, waits for F1 or F2.
//   STATE_MAIN       - 3D pipeline running. F1 pauses with help overlay; F3 returns home.
//   STATE_MAIN_HELP  - Animation paused, help text overlaid on top of the frozen cube.
//   STATE_HELP       - Standalone help screen entered from home. F1 or F3 returns home.

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

// Control character codes.

.const CLEAR_SCREEN             = $93           // Clear screen control code
.const CARRIAGE_RETURN          = $0D           // Carriage return
.const SPACE                    = $20           // Space character

// Color-RAM offset on the high byte. SCREEN_RAM = $0400, COLOR_RAM =
// $D800, so converting a SCREEN_RAM high byte to a COLOR_RAM high byte
// requires adding $D4 (= $D8 - $04). On the VIC-20 the equivalent
// offset is $78 (COLOR_RAM at $9600, SCREEN_RAM at $1E00).

.const COLOR_RAM_HIGH_OFFSET    = $D4

// PETSCII quadrant-block characters (upper / graphics set).
//
// These eight characters, combined with their reverse-video forms
// (base + $80 for the graphics range), cover all 16 possible 2 x 2
// quadrant masks. The C64's character ROM uses the same screen-code
// mapping for these graphics characters as the VIC-20.

.const CHAR_EMPTY               = $20           // No quadrants
.const CHAR_TL                  = $BE           // Top-left quadrant only
.const CHAR_TR                  = $BC           // Top-right quadrant only
.const CHAR_BL                  = $BB           // Bottom-left quadrant only
.const CHAR_BR                  = $AC           // Bottom-right quadrant only
.const CHAR_LOWER_HALF          = $A2           // Bottom-left + bottom-right
.const CHAR_LEFT_HALF           = $A1           // Top-left + bottom-left
.const CHAR_DIAG_TL_BR          = $BF           // Top-left + bottom-right

//==============================================================================
// BASIC Stub - "10 SYS 2062"
//==============================================================================
//
// Tokenised BASIC that auto-SYSes to the assembly entry point at $080E (2062).
// Byte layout:
//
//     $0801-$0802: link pointer to next line (-> $080C, basic_end)
//     $0803-$0804: line number 10
//     $0805:       SYS token ($9E)
//     $0806-$080A: " 2062" in PETSCII (space + four digits)
//     $080B:       end-of-line null terminator
//     $080C-$080D: end-of-program marker ($0000)
//     $080E:       entry:
//
//==============================================================================

*= $0801 "BASIC Stub"

    .word basic_end, 10                         // Link pointer to next line, line number 10
    .byte $9E                                   // SYS token
    .text " 2062"                               // SYS address in decimal ($080E)
    .byte $00                                   // End of line
basic_end:
    .word $0000                                 // End of BASIC program

//==============================================================================
// Program Entry Point
//==============================================================================

*= $080E "Main"

entry:

    // Set border and background to black.

    lda #COLOR_BLACK
    sta VIC_BORDER_COLOR
    sta VIC_BACKGROUND_COLOR

    // Set text colour to white.

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
//   Sets a pseudo-pixel at coordinates (X, Y) on the 80 x 50 virtual
//   screen by OR-ing the new quadrant bit into the existing character
//   at the corresponding 40 x 25 cell.
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

    sta plot_x

    // Build quadrant index (0..3):
    //
    //   quadrant = ( ( pixel_y & 1 ) << 1 ) | ( pixel_x & 1 )

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
//   Fills the 1000-byte back buffer with the empty-cell screen code,
//   wiping the virtual pixel buffer in preparation for a fresh frame.
//   The visible SCREEN_RAM is not touched.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

clear_pixel_screen:

    // Four-pass fill because X is 8-bit. Pages 1-3 are full 256 bytes;
    // page 4 covers the remaining 232 bytes (1000 - 768 = 232).

    lda #$20                                    // A = empty-cell screen code
    ldx #$00

clear_pixel_screen_page_123_loop:

    sta back_buffer + $000, x
    sta back_buffer + $100, x
    sta back_buffer + $200, x
    inx
    bne clear_pixel_screen_page_123_loop        // Stops when X wraps to 0

    // X is 0 here. Fill the final 232 bytes of page 4.

clear_pixel_screen_page_4_loop:

    sta back_buffer + $300, x
    inx
    cpx #SCREEN_SIZE - $300                     // 1000 - 768 = 232 remaining bytes
    bne clear_pixel_screen_page_4_loop

    rts

//------------------------------------------------------------------------------
//
// Subroutine: copy_buffer_to_screen
//
// Description:
//
//   Copies all 1000 bytes of back_buffer into the visible screen
//   matrix at SCREEN_RAM ( $0400 ). Called once per main-loop pass,
//   immediately after wait_for_vblank.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

copy_buffer_to_screen:

    ldx #$00

copy_buffer_to_screen_page_123_loop:

    lda back_buffer + $000, x
    sta SCREEN_RAM  + $000, x
    lda back_buffer + $100, x
    sta SCREEN_RAM  + $100, x
    lda back_buffer + $200, x
    sta SCREEN_RAM  + $200, x
    inx
    bne copy_buffer_to_screen_page_123_loop

copy_buffer_to_screen_page_4_loop:

    lda back_buffer + $300, x
    sta SCREEN_RAM  + $300, x
    inx
    cpx #SCREEN_SIZE - $300
    bne copy_buffer_to_screen_page_4_loop

    rts

//------------------------------------------------------------------------------
//
// Subroutine: wait_for_vblank
//
// Description:
//
//   Blocks until the VIC-II's raster beam enters vertical blanking.
//   On the C64 the raster register is $D012 (low 8 bits of the 9-bit
//   raster line counter). VBLANK_RASTER_THRESHOLD is 251; visible
//   lines run 50-249 in PAL and roughly 41-240 in NTSC. Waiting for
//   $D012 >= 251 catches the retrace interval on both standards.
//
//   Two-stage wait:
//
//     1. Wait until $D012 < threshold   (raster is in visible area).
//     2. Wait until $D012 >= threshold  (raster has just entered vblank).
//
// Clobbers: A.
//
//------------------------------------------------------------------------------

wait_for_vblank:

wait_for_vblank_visible:

    lda VIC_RASTER
    cmp #VBLANK_RASTER_THRESHOLD
    bcs wait_for_vblank_visible                 // Loop while raster >= threshold

wait_for_vblank_blank:

    lda VIC_RASTER
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
//   eight octants (any slope, any direction) via a major-axis split.
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

    lda multiply_a
    eor multiply_b
    sta multiply_sign

    lda multiply_a
    bpl multiply_signed_8_a_positive
    eor #$FF
    clc
    adc #$01
    sta multiply_a

multiply_signed_8_a_positive:

    lda multiply_b
    bpl multiply_signed_8_b_positive
    eor #$FF
    clc
    adc #$01
    sta multiply_b

multiply_signed_8_b_positive:

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

    ror multiply_result_hi
    ror multiply_result_lo
    dex
    bne multiply_signed_8_loop

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

//------------------------------------------------------------------------------
//
// Subroutine: multiply_signed_unsigned_8
//
// Description:
//
//   Signed × unsigned 8-bit multiply producing a 16-bit signed product.
//   Used by the Q1.7 aspect-ratio scaling stages, where the multiplier
//   is an honest unsigned 0..255 fraction-of-128 and the multiplicand
//   carries the sign of a screen-space offset.
//
//   Compared to multiply_signed_8, this routine does NOT treat
//   multiply_b as signed — it consumes the full 0..255 range as an
//   unsigned magnitude, so a factor of 128 means literal 1.0× rather
//   than -1.0×. Only multiply_a's sign drives the result's sign.
//
// Parameters:
//
//   multiply_a - Signed   8-bit multiplicand (clobbered with its abs value).
//   multiply_b - Unsigned 8-bit multiplier   (clobbered: shifted out).
//
// Output:
//
//   multiply_result_hi : multiply_result_lo - Signed 16-bit product.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

multiply_signed_unsigned_8:

    lda multiply_a
    sta multiply_sign

    bpl multiply_signed_unsigned_8_a_positive
    eor #$FF
    clc
    adc #$01
    sta multiply_a

multiply_signed_unsigned_8_a_positive:

    lda #$00
    sta multiply_result_hi
    ldx #$08

multiply_signed_unsigned_8_loop:

    lsr multiply_b                              // Next multiplier bit → carry
    bcc multiply_signed_unsigned_8_no_add

    clc
    lda multiply_result_hi
    adc multiply_a                              // High byte += multiplicand
    sta multiply_result_hi

multiply_signed_unsigned_8_no_add:

    ror multiply_result_hi
    ror multiply_result_lo
    dex
    bne multiply_signed_unsigned_8_loop

    lda multiply_sign
    bpl multiply_signed_unsigned_8_done

    sec
    lda #$00
    sbc multiply_result_lo
    sta multiply_result_lo
    lda #$00
    sbc multiply_result_hi
    sta multiply_result_hi

multiply_signed_unsigned_8_done:

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
//     x' = x * cos(θ) - z * sin(θ)
//     y' = y
//     z' = x * sin(θ) + z * cos(θ)
//
// Inputs:
//
//   yaw_angle, cube_vertices, sin_table.
//
// Outputs:
//
//   rotated_vertices.
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

rotate_vertices_yaw:

    ldy yaw_angle
    lda sin_table, y
    sta rotate_sin

    tya
    clc
    adc #$40                                    // cos(θ) = sin(θ + 90°)
    tay
    lda sin_table, y
    sta rotate_cos

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

    // x' = x*cos - z*sin

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
//   vertices currently in rotated_vertices, in place.
//
//     x' = x
//     y' = y * cos(φ) - z * sin(φ)
//     z' = y * sin(φ) + z * cos(φ)
//
// Clobbers: A, X, Y.
//
//------------------------------------------------------------------------------

rotate_vertices_pitch:

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

    // Cache y_old and z_old before they're clobbered by the writes.

    lda rotated_vertices + 1, y
    sta pitch_y
    lda rotated_vertices + 2, y
    sta pitch_z

    //--------------------------------------------------
    // y' = y * cos(φ) - z * sin(φ)
    //--------------------------------------------------

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

    lda pitch_z
    sta multiply_a
    lda rotate_sin
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi

    sec
    lda rotate_temp
    sbc multiply_result_hi
    sta rotated_vertices + 1, y

    //--------------------------------------------------
    // z' = y * sin(φ) + z * cos(φ)
    //--------------------------------------------------

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

    lda pitch_z
    sta multiply_a
    lda rotate_cos
    sta multiply_b
    jsr multiply_signed_8
    asl multiply_result_lo
    rol multiply_result_hi
    asl multiply_result_lo
    rol multiply_result_hi

    clc
    lda rotate_temp
    adc multiply_result_hi
    sta rotated_vertices + 2, y

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
//   offsets to every rotated vertex in place.
//
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
//   pseudo-pixel screen coordinates.
//
//     depth       = VIEWER_DISTANCE - rotated_z
//     scale       = inv_depth_focal[ depth ]         // Q1.7
//     pixel_x     = ( rotated_x * scale ) >> 7
//     pixel_y     = ( rotated_y * scale ) >> 7
//     screen_x    = pixel_x + SCREEN_CENTER_X
//     screen_y    = SCREEN_CENTER_Y - pixel_y        // flip
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

    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi                      // A = signed pixel_x offset

    //--- X aspect correction: pixel_x * ASPECT_FACTOR_X / 128 ( Q1.7 ). ---

    sta multiply_a
    lda #ASPECT_FACTOR_X
    sta multiply_b
    jsr multiply_signed_unsigned_8
    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi                      // A = pixel_x * ASPECT_FACTOR_X / 128

    //--- Zoom: multiply X offset by zoom_factor ( Q1.6 ), >> 6. ---

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

    //--- Y aspect correction: pixel_y * ASPECT_FACTOR_Y / 128 ( Q1.7 ). ---

    sta multiply_a
    lda #ASPECT_FACTOR_Y
    sta multiply_b
    jsr multiply_signed_unsigned_8
    asl multiply_result_lo
    rol multiply_result_hi
    lda multiply_result_hi                      // A = pixel_y * ASPECT_FACTOR_Y / 128

    //--- Zoom: multiply Y offset by zoom_factor ( Q1.6 ), >> 6. ---

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

    //--- Advance to the next vertex. ---

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
//   draw_line.
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
//   Reads at most one pending key from the KERNEL keyboard buffer via
//   GETIN and dispatches it.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

poll_keyboard:

    jsr KERNEL_GETIN                            // A = key or 0 if buffer empty
    tax
    bne poll_keyboard_has_key
    rts

poll_keyboard_has_key:

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

    // Gameplay keys are only active in STATE_MAIN.

    lda screen_state
    cmp #STATE_MAIN
    bne poll_keyboard_done

    txa                                         // restore key into A

    cmp #$20
    bne poll_keyboard_not_space
    lda control_mode
    eor #$01
    sta control_mode
    rts

poll_keyboard_not_space:

    lda control_mode
    beq poll_keyboard_done

    txa                                         // restore key into A
    ldx #MOTION_TABLE_LAST                      // scan from last entry down

poll_keyboard_motion_loop:

    cmp motion_keys, x
    beq poll_keyboard_motion_hit
    dex
    bpl poll_keyboard_motion_loop
    rts

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
//   F1 key dispatch. State transitions:
//
//     STATE_HOME       -> STATE_HELP
//     STATE_MAIN       -> STATE_MAIN_HELP
//     STATE_MAIN_HELP  -> STATE_MAIN
//     STATE_HELP       -> STATE_HOME
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
    jsr clear_screen_and_colors
    jsr render_help_screen
    rts

handle_f1_mainhelp_to_main:

    lda #STATE_MAIN
    sta screen_state
    jsr clear_screen_and_colors
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
//   F2 starts the main animation loop. Only valid from STATE_HOME.
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
//   F3 always returns to the home screen from any non-home state.
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
//   Fills the visible screen matrix ( SCREEN_RAM, 1000 bytes starting
//   at $0400 ) with the empty-cell screen code ( $20 ) and the color
//   RAM mirror ( COLOR_RAM, $D800 ) with white.
//
// Clobbers: A, X.
//
//------------------------------------------------------------------------------

clear_screen_and_colors:

    // First pass: fill SCREEN_RAM with the space ($20) screen code.

    lda #$20
    ldx #$00
clear_screen_pages_123:
    sta SCREEN_RAM + $000, x
    sta SCREEN_RAM + $100, x
    sta SCREEN_RAM + $200, x
    inx
    bne clear_screen_pages_123

clear_screen_page_4:
    sta SCREEN_RAM + $300, x
    inx
    cpx #SCREEN_SIZE - $300                     // 232 remaining bytes
    bne clear_screen_page_4

    // Second pass: fill COLOR_RAM with white.

    lda #COLOR_WHITE
    ldx #$00
clear_color_pages_123:
    sta COLOR_RAM + $000, x
    sta COLOR_RAM + $100, x
    sta COLOR_RAM + $200, x
    inx
    bne clear_color_pages_123

clear_color_page_4:
    sta COLOR_RAM + $300, x
    inx
    cpx #SCREEN_SIZE - $300
    bne clear_color_page_4

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
//   Color RAM is written by adding COLOR_RAM_HIGH_OFFSET ($D4) to the
//   high byte of the screen-RAM address pointer.
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

    // Advance ZP_PTR_1 past the 4-byte header.

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

    // Switch destination to COLOR_RAM (+$D4 on the high byte) and fill.

    lda ZP_PTR_2 + 1
    clc
    adc #COLOR_RAM_HIGH_OFFSET                  // COLOR_RAM - SCREEN_RAM high byte
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
// Mask -> screen code table.
//
// Indexed by a 4-bit quadrant mask. Values are SCREEN CODES (not
// PETSCII) because plot_pixel writes directly to screen memory at
// $0400.
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
// Quadrant index -> pixel mask table.
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
// by 40. Points at the back buffer rather than SCREEN_RAM because
// plot_pixel writes into the off-screen buffer; completed frames
// are pushed to the visible display by copy_buffer_to_screen.
//------------------------------------------------------------------------------

row_start_lo:

    .fill SCREEN_ROWS, <( back_buffer + i * SCREEN_COLUMNS )

row_start_hi:

    .fill SCREEN_ROWS, >( back_buffer + i * SCREEN_COLUMNS )

//------------------------------------------------------------------------------
// Screen code -> quadrant mask reverse lookup.
//------------------------------------------------------------------------------

screen_code_to_mask:

    .fill 256, $00

//------------------------------------------------------------------------------
// Unit cube geometry (object space).
//
// Eight vertices, stored as Q2.6 signed 8-bit triples ( x, y, z ).
// Cube corners at ±40 (Q2.6).
//
// Coordinate convention:
//
//     +X = right
//     +Y = up                      (screen-space +Y is flipped at projection)
//     +Z = toward viewer
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
// unsigned angle where one turn = 256 steps. Values are signed Q1.6:
// +64 = +1.0, -64 = -1.0.
//------------------------------------------------------------------------------

sin_table:

    .fill 256, round( 64 * sin( i * 2 * PI / 256 ) )

//------------------------------------------------------------------------------
// Perspective 1/depth lookup.
//
//     inv_depth_focal[ d ] = round( 128 * PROJECTION_FOCAL / d )       (Q1.7)
//------------------------------------------------------------------------------

inv_depth_focal:

    .fill 256, round( 128 * PROJECTION_FOCAL / max( 1, i ) ) & $FF

//------------------------------------------------------------------------------
// Screen-RAM row start addresses.
//
// Mirrors row_start_lo / row_start_hi but targets SCREEN_RAM ( $0400 )
// instead of back_buffer. Used by render_text_table to position text
// on the visible screen.
//------------------------------------------------------------------------------

screen_row_lo:

    .fill SCREEN_ROWS, < ( SCREEN_RAM + i * SCREEN_COLUMNS )

screen_row_hi:

    .fill SCREEN_ROWS, > ( SCREEN_RAM + i * SCREEN_COLUMNS )

//------------------------------------------------------------------------------
// Motion-key dispatch tables.
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
// Terminated by a row byte of $FF. Encoded with screencode_upper so
// the text strings expand straight into the 40 x 25 character matrix.
//
// Columns are chosen for the C64's 40-column screen — text is centred
// around col 16-20 instead of the VIC-20's col 7-13.
//------------------------------------------------------------------------------

.encoding "screencode_upper"

home_screen_data:

    .byte  2, 16, COLOR_WHITE, 7
    .text  "3D CUBE"
    .byte  3, 14, COLOR_BLUE, 11
    .text  "VERSION 1.0"
    .byte  6, 16, COLOR_WHITE, 7
    .text  "F1 HELP"
    .byte  7, 16, COLOR_WHITE, 8
    .text  "F2 START"
    .byte  23, 12, COLOR_CYAN,  16
    .text  "BY ROHIN GOSLING"
    .byte  $FF                                  // terminator

help_screen_data:

    .byte  1, 16, COLOR_WHITE, 7
    .text  "3D CUBE"
    .byte  2, 14, COLOR_BLUE, 11
    .text  "VERSION 1.0"

    // Controls.
    .byte  5,  9, COLOR_WHITE, 18
    .text  "+ -    ZOOM IN/OUT"
    .byte  6,  9, COLOR_WHITE, 17
    .text  "W R    Y-ROTATION"
    .byte  7,  9, COLOR_WHITE, 17
    .text  "E D    X-ROTATION"
    .byte  8,  9, COLOR_WHITE, 20
    .text  "Q A    Z-TRANSLATION"
    .byte  9,  9, COLOR_WHITE, 20
    .text  "T G    Y-TRANSLATION"
    .byte 10,  9, COLOR_WHITE, 20
    .text  "S F    X-TRANSLATION"
    .byte 11,  9, COLOR_WHITE, 20
    .text  "SPACE  TOGGLE ROTATE"
    .byte 12,  9, COLOR_WHITE, 18
    .text  "F1     TOGGLE HELP"
    .byte 13,  9, COLOR_WHITE, 16
    .text  "F3     MAIN MENU"

    // Coordinate-system diagram.
    .byte 16, 19, COLOR_WHITE, 1
    .text  "Y"
    .byte 17, 19, COLOR_GREEN, 1
    .byte  $5D
    .byte 17, 22, COLOR_WHITE, 1
    .text  "Z"
    .byte 18, 19, COLOR_GREEN, 3
    .byte  $5D, $20, $4E
    .byte 19, 19, COLOR_GREEN, 2
    .byte  $5D, $4E
    .byte 20, 14, COLOR_WHITE, 2
    .text  "-X"
    .byte 20, 16, COLOR_GREEN, 7
    .byte  $40, $40, $40, $5B, $40, $40, $40
    .byte 20, 23, COLOR_WHITE, 1
    .text  "X"
    .byte 21, 18, COLOR_GREEN, 2
    .byte  $4E, $5D
    .byte 22, 17, COLOR_GREEN, 3
    .byte  $4E, $20, $5D
    .byte 23, 15, COLOR_WHITE, 2
    .text  "-Z"
    .byte 23, 19, COLOR_GREEN, 1
    .byte  $5D
    .byte 24, 18, COLOR_WHITE, 2
    .text  "-Y"
    .byte $FF                                   // terminator

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

    .byte $00                                   // Start x

line_y0:

    .byte $00                                   // Start y

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

    .byte $00                                   // Bit 7 = sign of the result

multiply_result_lo:

    .byte $00                                   // Low byte of the 16-bit product

multiply_result_hi:

    .byte $00                                   // High byte of the 16-bit product

//------------------------------------------------------------------------------
// 3D pipeline working storage.
//------------------------------------------------------------------------------

rotated_vertices:

    .fill 24, $00                               // 8 vertices x 3 bytes (x, y, z) in Q2.6

screen_x:

    .fill 8, $00                                // Projected pseudo-pixel X per vertex (0..79)

screen_y:

    .fill 8, $00                                // Projected pseudo-pixel Y per vertex (0..49)

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

    .byte $00                                   // sin(current axis angle)

rotate_cos:

    .byte $00                                   // cos(current axis angle)

rotate_temp:

    .byte $00                                   // Scratch byte for rotation intermediates

pitch_y:

    .byte $00                                   // Cached y-coord during in-place pitch

pitch_z:

    .byte $00                                   // Cached z-coord during in-place pitch

//------------------------------------------------------------------------------
// Interactive-control state.
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

    .byte $40                                   // Q1.6 post-projection multiplier; $40 = 1.0x

//------------------------------------------------------------------------------
// Screen state + text-render scratch.
//------------------------------------------------------------------------------

screen_state:

    .byte STATE_HOME                            // Current UI state

render_col:

    .byte $00                                   // Current entry's column ( 0..39 )

render_color:

    .byte $00                                   // Current entry's color-RAM value

render_length:

    .byte $00                                   // Current entry's text length

//------------------------------------------------------------------------------
// Back buffer.
//
// 1000-byte off-screen mirror of the visible screen matrix. plot_pixel
// and clear_pixel_screen write here; copy_buffer_to_screen pushes the
// completed frame to SCREEN_RAM once per main-loop pass.
//------------------------------------------------------------------------------

back_buffer:

    .fill SCREEN_SIZE, $00
