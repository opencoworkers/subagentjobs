// AsciiPetView.swift — hand-crafted ASCII pet animation.
//
// Directly ported from:
//   vendors/anthropics/claude-desktop-buddy/src/buddies/robot.cpp
//   vendors/anthropics/claude-desktop-buddy/src/buddies/cat.cpp
//
// Each species has 7 states (sleep/idle/busy/attention/celebrate/dizzy/heart).
// Each state has multiple pose frames (5-line string arrays) driven by a tick
// counter, plus particle overlays drawn into a SwiftUI Canvas.
//
// No GIFs. No pixel-brightness conversion. Pure ASCII sprites, same as device.jpg.

import SwiftUI
import BuddyCore

// MARK: - Sprite data helpers

private typealias Pose = [String]  // always 5 lines × 12 chars

/// Draw a 5-line sprite block centred in the canvas, with optional y/x offsets.
private func drawSprite(
    _ ctx: inout GraphicsContext,
    _ size: CGSize,
    _ pose: Pose,
    color: Color,
    yOff: CGFloat = 0,
    xOff: CGFloat = 0
) {
    let fs: CGFloat = 11          // font size
    let cw: CGFloat = fs * 0.601  // monospace char width (Menlo ratio)
    let lh: CGFloat = fs * 1.30   // line height

    let sprW = 12.0 * cw
    let originX = (size.width  - sprW) / 2 + xOff * cw
    let originY =  size.height * 0.06  + yOff * lh

    for (i, line) in pose.enumerated() {
        ctx.draw(
            Text(line)
                .font(.system(size: fs, design: .monospaced))
                .foregroundStyle(color),
            at: CGPoint(x: originX, y: originY + CGFloat(i) * lh),
            anchor: .topLeading
        )
    }
}

/// Draw a single overlay character at a position relative to the sprite centre.
/// `rx` / `ry` are in "hardware pixels" (same units as the C++ offsets).
private func drawOverlay(
    _ ctx: inout GraphicsContext,
    _ size: CGSize,
    _ char: String,
    rx: CGFloat, ry: CGFloat,
    color: Color,
    fontSize: CGFloat = 10
) {
    let scale: CGFloat = 0.80
    let centerX = size.width  / 2
    // Anchor overlays near the robot's head row (line 1, ~20px from top).
    // Sprite draws from originY = size.height * 0.06 ≈ 6.6 px.
    // baseY * 0.25 ≈ 27.5 means ry=0 sits just above the antennae, negative
    // ry values float above the head, large negatives (ry ≈ -38) reach the
    // top edge — matching the C++ device coordinate system.
    // (The old value 0.82 anchored at y=90, 26 px below the sprite bottom.)
    let baseY   = size.height * 0.25

    let pt = CGPoint(x: centerX + rx * scale, y: baseY + ry * scale)
    guard pt.x >= 0, pt.x <= size.width, pt.y >= -4, pt.y <= size.height + 4
    else { return }

    ctx.draw(
        Text(char)
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundStyle(color),
        at: pt, anchor: .center
    )
}

// MARK: - Species colours

private let robotBody  = Color(red: 0.78, green: 0.78, blue: 0.78)  // 0xC618 ≈ mid-grey
private let catBody    = Color(red: 0.76, green: 0.67, blue: 0.65)  // 0xC2A6 ≈ warm grey

private let cDim    = Color(red: 0.35, green: 0.35, blue: 0.35)
private let cCyan   = Color.cyan
private let cYellow = Color.yellow
private let cGreen  = Color.green
private let cRed    = Color.red
private let cPurple = Color.purple
private let cWhite  = Color.white
private let cHeart  = Color(red: 1.0,  green: 0.27, blue: 0.47)   // hot-pink hearts

// MARK: - Robot species  (robot.cpp)

private enum Robot {

    // SLEEP
    static func sleep(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "   .[__].   ", "  [ -    - ]", "  [ ____ ]  ", "  (------)  "],  // PWR_DN
            ["            ", "   .[..].   ", "  [ .    . ]", "  [ ____ ]  ", "  (------)  "],  // DIM_A
            ["            ", "   .[  ].   ", "  [        ]", "  [ ____ ]  ", "  (------)  "],  // DIM_B
            ["            ", "   .[||].   ", "  [ -    - ]", "  [ z__z ]  ", "  (------)  "],  // PING
            ["    .[*].   ", "   .[||].   ", "  [ -    - ]", "  [ zzzz ]  ", "  (------)  "],  // DREAM
            ["            ", "   .[..].   ", "  [ o    - ]", "  [ ____ ]  ", "  (------)  "],  // REBOOT
        ]
        let seq: [UInt32] = [0,1,2,1,0,1,2,1, 0,0,3,3, 4,4,4,3, 0,1,2,1,0, 5,0,1,0]
        let beat = (t / 5) % UInt32(seq.count)
        drawSprite(&ctx, sz, poses[Int(seq[Int(beat)])], color: robotBody)

        let p1 = Int(t)     % 10
        let p2 = Int(t + 4) % 10
        let p3 = Int(t + 7) % 10
        drawOverlay(&ctx, sz, "z", rx: CGFloat(20 + p1), ry: CGFloat(18 - p1 * 2) - 20, color: cDim)
        drawOverlay(&ctx, sz, "Z", rx: CGFloat(26 + p2), ry: CGFloat(14 - p2)     - 20, color: cCyan)
        drawOverlay(&ctx, sz, "z", rx: CGFloat(16 + p3/2), ry: CGFloat(10 - p3/2) - 20, color: cDim)
    }

    // IDLE
    static func idle(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "   .[||].   ", "  [ o    o ]", "  [ ==== ]  ", "  (------)  "],  // REST
            ["            ", "   .[||].   ", "  [o     o ]", "  [ ==== ]  ", "  (------)  "],  // SCAN_L
            ["            ", "   .[||].   ", "  [ o     o]", "  [ ==== ]  ", "  (------)  "],  // SCAN_R
            ["            ", "   .[||].   ", "  [ -    - ]", "  [ ==== ]  ", "  (------)  "],  // BLINK
            ["            ", "   .[\\\\].  ", "  [ o    o ]", "  [ ==== ]  ", "  (------)  "],  // ANT_L
            ["            ", "   .[//].   ", "  [ o    o ]", "  [ ==== ]  ", "  (------)  "],  // ANT_R
            ["            ", "   .[||].   ", "  [ o    o ]", "  [ -==- ]  ", "  (------)  "],  // BEEP_A
            ["            ", "   .[||].   ", "  [ o    o ]", "  [ =--= ]  ", "  (------)  "],  // BEEP_B
            ["    .[*].   ", "   .[||].   ", "  [ ^    ^ ]", "  [ ==== ]  ", "  (------)  "],  // PING
            ["            ", "   .[||].   ", "  [ o    o ]", "  [ ==== ]  ", " /(------)\\ "],  // CLICK
        ]
        let seq: [UInt32] = [0,0,1,1,0,2,2,0, 3,0,0, 4,5,4,5,0, 6,7,6,7,0, 0,8,8,0, 9,9,0,3,0]
        let beat = (t / 5) % UInt32(seq.count)
        drawSprite(&ctx, sz, poses[Int(seq[Int(beat)])], color: robotBody)

        if (t / 4) & 1 == 1 {
            drawOverlay(&ctx, sz, ".", rx: -1, ry: -38, color: cRed)
        }
    }

    // BUSY
    static func busy(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["    01010   ", "   .[||].   ", "  [ #    # ]", "  [ ==== ]  ", " /(------)\\ "],  // CALC_A
            ["    10101   ", "   .[||].   ", "  [ #    # ]", "  [ -==- ]  ", " \\(------)/ "],  // CALC_B
            ["     ?      ", "   .[||].   ", "  [ ^    ^ ]", "  [ .... ]  ", "  (------)  "],  // PROC
            ["    [@@]    ", "   .[||].   ", "  [ o    o ]", "  [ ==== ]  ", "  (------)  "],  // WHIRR
            ["     !      ", "   .[||].   ", "  [ O    O ]", "  [ ^^^^ ]  ", " /(------)\\ "],  // DING
            ["    ~~~     ", "   .[||].   ", "  [ -    - ]", "  [ ____ ]  ", "  (------)  "],  // COOL
        ]
        let seq: [UInt32] = [0,1,0,1,0,1, 2,2, 0,1,0,1, 3,3, 2,4, 0,1,0,1, 5]
        let beat = (t / 5) % UInt32(seq.count)
        drawSprite(&ctx, sz, poses[Int(seq[Int(beat)])], color: robotBody)

        let bits = ["1  ", "10 ", "101", "010", "10 ", "1  "]
        drawOverlay(&ctx, sz, bits[Int(t) % 6], rx: 22, ry: -6, color: cGreen)
    }

    // ATTENTION
    static func attention(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["    [!]     ", "   .[||].   ", "  [ O    O ]", "  [ #### ]  ", " /(------)\\ "],  // ALERT
            ["    [!]     ", "   .[\\\\].  ", "  [O     O ]", "  [ #### ]  ", " /(------)\\ "],  // SCAN_L
            ["    [!]     ", "   .[//].   ", "  [ O     O]", "  [ #### ]  ", " /(------)\\ "],  // SCAN_R
            ["    [!]     ", "   .[||].   ", "  [ ^    ^ ]", "  [ #### ]  ", " /(------)\\ "],  // SCAN_U
            ["    {!!}    ", "   .[||].   ", "  [ X    X ]", "  [ #### ]  ", "//(------)\\\\"],  // SIREN
            ["    [.]     ", "   .[||].   ", "  [ o    o ]", "  [ .... ]  ", "  (------)  "],  // HUSH
        ]
        let seq: [UInt32] = [0,4,0,1,0,2,0,3, 4,4,0,1,2,0, 5,0]
        let beat = (t / 5) % UInt32(seq.count)
        let pose = seq[Int(beat)]
        let xOff: CGFloat = (pose == 4) ? ((t & 1 == 1) ? 1 : -1) : 0
        drawSprite(&ctx, sz, poses[Int(pose)], color: robotBody, xOff: xOff)

        if (t / 2) & 1 == 1 {
            drawOverlay(&ctx, sz, "!", rx: -6, ry: -36, color: cYellow)
        }
        if (t / 3) & 1 == 1 {
            drawOverlay(&ctx, sz, "!", rx: 6, ry: -32, color: cRed)
        }
    }

    // CELEBRATE
    static func celebrate(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "   .[||].   ", "  [ ^    ^ ]", "  [ ==== ]  ", " /(------)\\ "],  // CROUCH
            ["  \\[||]/    ", "   .----.   ", "  [ ^    ^ ]", "  [ ==== ]  ", "  (------)  "],  // JUMP
            ["  \\[**]/    ", "   .----.   ", "  [ O    O ]", "  [ ^^^^ ]  ", "  (------)  "],  // PEAK
            ["            ", "   .[\\\\].  ", "  [ <    < ]", "  [ ==== ] /", "  (------)  "],  // SPIN_L
            ["            ", "   .[//].   ", "  [ >    > ]", " \\[ ==== ]  ", "  (------)  "],  // SPIN_R
            ["    [**]    ", "   .[||].   ", "  [ ^    ^ ]", " /[ #### ]\\ ", "  (------)  "],  // POSE
        ]
        let seq: [UInt32]   = [0,1,2,1,0, 3,4,3,4, 0,1,2,1,0, 5,5]
        let yShift: [CGFloat] = [0,-1,-2,-1,0, 0,0,0,0, 0,-1,-2,-1,0, 0,0]
        let beat = (t / 3) % UInt32(seq.count)
        let b = Int(beat)
        drawSprite(&ctx, sz, poses[Int(seq[b])], color: robotBody, yOff: yShift[b])

        let sparks = [cYellow, cCyan, cGreen, cWhite, cPurple]
        for i in 0..<6 {
            let phase = (Int(t) * 2 + i * 11) % 22
            let rx = CGFloat(-36 + i * 14)
            let ry = CGFloat(-6 + phase) - 36
            let c = sparks[i % 5]
            let ch = ((i + Int(t/2)) & 1 == 1) ? "+" : "*"
            drawOverlay(&ctx, sz, ch, rx: rx, ry: ry, color: c)
        }
    }

    // DIZZY
    static func dizzy(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "  .[||].    ", " [ x    x ] ", " [ ~~~~ ]   ", "  (------)  "],  // TILT_L
            ["            ", "    .[||].  ", "  [ x    x ]", "   [ ~~~~ ] ", "  (------)  "],  // TILT_R
            ["            ", "   .[/\\].  ", "  [ X    @ ]", "  [ #v#v ]  ", "  `--__--'  "],  // GLITCH
            ["            ", "   .[\\/].  ", "  [ @    X ]", "  [ v#v# ]  ", "  `--__--'  "],  // GLITCH2
            ["            ", "   .[??].   ", "  [ x    x ]", "  [ ____ ]  ", " /`-_--_-'\\ "],  // CRASH
        ]
        let seq: [UInt32]    = [0,1,0,1, 2,3, 0,1,0,1, 4,4, 2,3]
        let xShift: [CGFloat] = [-1,1,-1,1, 0,0, -1,1,-1,1, 0,0, 0,0]
        let beat = (t / 4) % UInt32(seq.count)
        let b = Int(beat)
        drawSprite(&ctx, sz, poses[Int(seq[b])], color: robotBody, xOff: xShift[b])

        let ox: [CGFloat] = [0, 5, 7, 5, 0, -5, -7, -5]
        let oy: [CGFloat] = [-5, -3, 0, 3, 5, 3, 0, -3]
        let p1 = Int(t) % 8
        let p2 = (Int(t) + 4) % 8
        drawOverlay(&ctx, sz, "?", rx: ox[p1] - 2, ry: oy[p1] - 16, color: cYellow)
        drawOverlay(&ctx, sz, "x", rx: ox[p2] - 2, ry: oy[p2] - 16, color: cRed)
    }

    // HEART
    static func heart(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["    [<3]    ", "   .[||].   ", "  [ ^    ^ ]", "  [ ==== ]  ", "  (------)  "],  // DREAMY
            ["    [<3]    ", "   .[||].   ", "  [#^    ^#]", "  [ ==== ]  ", "  (------)  "],  // BLUSH
            ["    [<3]    ", "   .[||].   ", "  [ <3  <3 ]", "  [ ==== ]  ", "  (------)  "],  // EYES_C
            ["    [<3]    ", "   .[||].   ", "  [ @    @ ]", "  [ ==== ]  ", " /(------)\\ "],  // TWIRL
            ["    [<3]    ", "   .[||].   ", "  [ -    - ]", "  [ ^^^^ ]  ", "  (------)  "],  // SIGH
        ]
        let seq: [UInt32]    = [0,0,1,0, 2,2,0, 1,0,4, 0,0,3,3, 0,1,0,2, 1,0]
        let yBob: [CGFloat]  = [0,-1,0,-1, 0,-1,0, -1,0,0, -1,0,0,0, -1,0,-1,0, -1,0]
        let beat = (t / 5) % UInt32(seq.count)
        let b = Int(beat)
        drawSprite(&ctx, sz, poses[Int(seq[b])], color: robotBody, yOff: yBob[b])

        for i in 0..<5 {
            let phase = (Int(t) + i * 4) % 16
            let ry    = CGFloat(16 - phase) - 22
            let rx    = CGFloat(-20 + i * 8 + ((phase / 3) & 1) * 2 - 1)
            drawOverlay(&ctx, sz, "v", rx: rx, ry: ry, color: cHeart)
        }
    }
}

// MARK: - Cat species  (cat.cpp)

private enum Cat {

    static func sleep(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "            ", "   .-..-.   ", "  ( -.- )   ", "  `------`~ "],  // LOAF
            ["            ", "            ", "   .-..-.   ", "  ( -.- )_  ", " `~------'~ "],  // BREATHE
            ["            ", "            ", "   .-/\\.    ", "  (  ..  )) ", "  `~~~~~~`  "],  // CURL
            ["            ", "            ", "   .-/\\.    ", "  (  ..  )) ", "  `~~~~~~`~ "],  // CURL_TW
            ["            ", "            ", "   .-..-.   ", "  ( u.u )   ", " `~------'~ "],  // PURR
        ]
        let seq: [UInt32] = [0,1,0,1,0,1, 4,4,0,1, 2,3,2,3,2,3, 0,1,0,1, 3,3,2,2]
        let beat = (t / 5) % UInt32(seq.count)
        drawSprite(&ctx, sz, poses[Int(seq[Int(beat)])], color: catBody)
        let p1 = Int(t) % 12; let p2 = (Int(t)+5)%12; let p3 = (Int(t)+9)%12
        drawOverlay(&ctx, sz, "z", rx: CGFloat(18+p1), ry: CGFloat(18-p1*2)-20, color: cDim)
        drawOverlay(&ctx, sz, "Z", rx: CGFloat(24+p2), ry: CGFloat(14-p2)-20,   color: cWhite)
        drawOverlay(&ctx, sz, "z", rx: CGFloat(14+p3/2), ry: CGFloat(8-p3/2)-20, color: cDim)
    }

    static func idle(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "   /\\_/\\    ", "  ( o   o ) ", "  (  w   )  ", "  (\")_(\")  "],  // REST
            ["            ", "   /\\_/\\    ", "  (o    o ) ", "  (  w   )  ", "  (\")_(\")  "],  // LOOK_L
            ["            ", "   /\\_/\\    ", "  ( o    o) ", "  (  w   )  ", "  (\")_(\")  "],  // LOOK_R
            ["            ", "   /\\_/\\    ", "  ( -   - ) ", "  (  w   )  ", "  (\")_(\")  "],  // BLINK
            ["            ", "   /\\-/\\    ", "  ( _   _ ) ", "  (  w   )  ", "  (\")_(\")  "],  // SLOW_BL
            ["            ", "   /\\_/\\    ", "  ( o   o ) ", "  (  w   )  ", "  (\")_(\")~ "],  // TAIL_R
            ["            ", "   /\\_/\\    ", "  ( ^   ^ ) ", "  (  P   )  ", "  (\")_(\")  "],  // GROOM
        ]
        let seq: [UInt32] = [0,0,0,3,0,1,0,2,0, 5,5,0, 4,4,0, 6,6,6,0, 0,3,0, 5,0]
        let beat = (t / 5) % UInt32(seq.count)
        drawSprite(&ctx, sz, poses[Int(seq[Int(beat)])], color: catBody)
    }

    static func busy(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["      .     ", "   /\\_/\\    ", "  ( o   o ) ", "  (  w   )/ ", "  (\")_(\")  "],  // PAW_UP
            ["    .       ", "   /\\_/\\    ", "  ( o   o ) ", "  (  w   )_ ", "  (\")_(\")  "],  // PAW_TAP
            ["            ", "   /\\_/\\    ", "  ( O   O ) ", "  (  w   )  ", "  (\")_(\")  "],  // STARE
            ["    o       ", "   /\\_/\\    ", "  ( o   o ) ", "  ( -w   )  ", "  (\")_(\")  "],  // NUDGE
            ["  o         ", "   /\\_/\\    ", "  ( o   o ) ", "  (-w    )  ", "  (\")_(\")  "],  // SHOVE
            ["            ", "   /\\_/\\    ", "  ( -   - ) ", "  (  w   )  ", "  (\")_(\")  "],  // SMUG
        ]
        let seq: [UInt32] = [2,2,2, 0,1,0,1, 3,4,3,4, 5,5, 2,2, 0,1,0,1, 5,2]
        let beat = (t / 5) % UInt32(seq.count)
        drawSprite(&ctx, sz, poses[Int(seq[Int(beat)])], color: catBody)
        let dots = [".  ", ".. ", "...", " ..", "  .", "   "]
        drawOverlay(&ctx, sz, dots[Int(t) % 6], rx: 22, ry: -6, color: cWhite)
    }

    static func attention(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "   /^_^\\    ", "  ( O   O ) ", "  (  v   )  ", "  (\")_(\")  "],  // ALERT
            ["            ", "   /^_^\\    ", "  (O    O ) ", "  (  v   )  ", "  (\")_(\")  "],  // SCAN_L
            ["            ", "   /^_^\\    ", "  ( O    O) ", "  (  v   )  ", "  (\")_(\")  "],  // SCAN_R
            ["            ", "   /^_^\\    ", "  ( ^   ^ ) ", "  (  v   )  ", "  (\")_(\")  "],  // SCAN_U
            ["            ", "   /^_^\\    ", " /( O   O )\\", " (   v    ) ", " /(\")-(\")\\  "],  // CROUCH
        ]
        let seq: [UInt32] = [0,4,0,1,0,2,0,3, 4,4,0,1,2,0, 0]
        let beat = (t / 5) % UInt32(seq.count)
        let pose = seq[Int(beat)]
        let xOff: CGFloat = (pose == 4) ? ((t & 1 == 1) ? 0.5 : -0.5) : 0
        drawSprite(&ctx, sz, poses[Int(pose)], color: catBody, xOff: xOff)
        if (t/2)&1==1 { drawOverlay(&ctx, sz, "!", rx: -4, ry: -36, color: cYellow) }
        if (t/3)&1==1 { drawOverlay(&ctx, sz, "!", rx:  4, ry: -32, color: cYellow) }
    }

    static func celebrate(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "   /\\_/\\    ", "  ( ^   ^ ) ", "  (  W   )  ", " /(\")_(\")\\  "],
            ["  \\^   ^/   ", "    /\\_/\\   ", "  ( ^   ^ ) ", "  (  W   )  ", "  (\")_(\")  "],
            ["  \\^   ^/   ", "    /\\_/\\   ", "  ( * * * ) ", "  (  W   )  ", "  (\")_(\")~ "],
            ["            ", "   /\\_/\\    ", "  ( <   < ) ", "  (  W   ) /", " ~(\")_(\")  "],
            ["            ", "   /\\_/\\    ", "  ( >   > ) ", " \\(  W   )  ", "  (\")_(\")~ "],
            ["    \\o/     ", "   /\\_/\\    ", "  ( ^   ^ ) ", " /(  W   )\\ ", "  (\")_(\")  "],
        ]
        let seq: [UInt32]    = [0,1,2,1,0, 3,4,3,4, 0,1,2,1,0, 5,5]
        let yShift: [CGFloat] = [0,-1,-2,-1,0, 0,0,0,0, 0,-1,-2,-1,0, 0,0]
        let beat = (t/3) % UInt32(seq.count); let b = Int(beat)
        drawSprite(&ctx, sz, poses[Int(seq[b])], color: catBody, yOff: yShift[b])
        let sparks = [cYellow, cHeart, cCyan, cWhite, cGreen]
        for i in 0..<6 {
            let ph = (Int(t)*2 + i*11) % 22
            drawOverlay(&ctx, sz, ((i + Int(t/2))&1==1) ? "*" : ".", rx: CGFloat(-36+i*14), ry: CGFloat(-6+ph)-36, color: sparks[i%5])
        }
    }

    static func dizzy(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "  /\\_/\\     ", " ( @   @ )  ", " (   ~~  )  ", " (\")_(\")   "],
            ["            ", "    /\\_/\\   ", "  ( @   @ ) ", "  (  ~~  )  ", "    (\")_(\")"],
            ["            ", "   /\\_/\\    ", "  ( x   @ ) ", "  (  v   )  ", "  (\")_(\")~ "],
            ["            ", "   /\\_/\\    ", "  ( @   x ) ", "  (  v   )  ", " ~(\")_(\")  "],
            ["            ", "   /\\_/\\    ", "  ( @   @ ) ", "  (  -   )  ", " /(\")_(\")\\~"],
        ]
        let seq: [UInt32]    = [0,1,0,1, 2,3, 0,1,0,1, 4,4, 2,3]
        let xShift: [CGFloat] = [-1,1,-1,1, 0,0, -1,1,-1,1, 0,0, 0,0]
        let beat = (t/4) % UInt32(seq.count); let b = Int(beat)
        drawSprite(&ctx, sz, poses[Int(seq[b])], color: catBody, xOff: xShift[b])
        let ox: [CGFloat] = [0,5,7,5,0,-5,-7,-5]; let oy: [CGFloat] = [-5,-3,0,3,5,3,0,-3]
        let p1 = Int(t)%8; let p2 = (Int(t)+4)%8
        drawOverlay(&ctx, sz, "*", rx: ox[p1]-2, ry: oy[p1]-16, color: cCyan)
        drawOverlay(&ctx, sz, "*", rx: ox[p2]-2, ry: oy[p2]-16, color: cYellow)
    }

    static func heart(_ ctx: inout GraphicsContext, _ sz: CGSize, _ t: UInt32) {
        let poses: [Pose] = [
            ["            ", "   /\\_/\\    ", "  ( ^   ^ ) ", "  (  u   )  ", "  (\")_(\")~ "],
            ["            ", "   /\\_/\\    ", "  (#^   ^#) ", "  (  u   )  ", "  (\")_(\")  "],
            ["            ", "   /\\_/\\    ", "  ( <3 <3 ) ", "  (  u   )  ", "  (\")_(\")~ "],
            ["            ", "   /\\-/\\    ", "  ( ~   ~ ) ", "  (  u   )  ", " ~(\")_(\")~ "],
            ["            ", "   /\\_/\\    ", "  ( ^   - ) ", "  (  u   )  ", "  (\")_(\")  "],
        ]
        let seq: [UInt32]   = [0,0,1,0, 2,2,0, 1,0,4, 0,0,3,3, 0,1,0,2, 1,0]
        let yBob: [CGFloat] = [0,-1,0,-1, 0,-1,0, -1,0,0, -1,0,0,0, -1,0,-1,0, -1,0]
        let beat = (t/5) % UInt32(seq.count); let b = Int(beat)
        drawSprite(&ctx, sz, poses[Int(seq[b])], color: catBody, yOff: yBob[b])
        for i in 0..<5 {
            let ph = (Int(t) + i*4) % 16
            drawOverlay(&ctx, sz, "v", rx: CGFloat(-20+i*8+((ph/3)&1)*2-1), ry: CGFloat(16-ph)-22, color: cHeart)
        }
    }
}

// MARK: - AsciiPetView

/// Drop-in character view — renders hand-crafted ASCII sprites, no GIFs.
/// Species selection: "robot" (default, shown on device.jpg), "cat".
struct AsciiPetView: View {
    let state: CharacterState
    var species: String = "robot"

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { tl in
            // timeIntervalSinceReferenceDate * 10 ≈ 7.9B in 2026 > UInt32.max(4.29B)
            // Mask to 31-bit to stay safely within UInt32 while keeping animation continuity
            let rawTick = Int64(tl.date.timeIntervalSinceReferenceDate * 10)
            let tick    = UInt32(rawTick & 0x7FFF_FFFF)
            Canvas { ctx, size in
                render(&ctx, size, tick)
            }
        }
        .frame(width: 220, height: 110)
    }

    private func render(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: UInt32) {
        switch species {
        case "cat":
            switch state {
            case .sleep:     Cat.sleep(&ctx, size, t)
            case .idle:      Cat.idle(&ctx, size, t)
            case .busy:      Cat.busy(&ctx, size, t)
            case .attention: Cat.attention(&ctx, size, t)
            case .celebrate: Cat.celebrate(&ctx, size, t)
            case .dizzy:     Cat.dizzy(&ctx, size, t)
            case .heart:     Cat.heart(&ctx, size, t)
            }
        default:  // "robot"
            switch state {
            case .sleep:     Robot.sleep(&ctx, size, t)
            case .idle:      Robot.idle(&ctx, size, t)
            case .busy:      Robot.busy(&ctx, size, t)
            case .attention: Robot.attention(&ctx, size, t)
            case .celebrate: Robot.celebrate(&ctx, size, t)
            case .dizzy:     Robot.dizzy(&ctx, size, t)
            case .heart:     Robot.heart(&ctx, size, t)
            }
        }
    }
}
