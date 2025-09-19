package game

import "base:runtime"
import "core:log"
import "core:fmt"

import "../atlas"

MAX_SPRITES :: 8192

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

WHITE :: Vec3{1, 1, 1}
RED   :: Vec3{1, 0, 0}
GREEN   :: Vec3{0, 1, 0}
BLUE   :: Vec3{0, 0, 1}


when ODIN_OS == .Windows {
	Sprite :: struct {
        pos : Vec2,
        size : Vec2,
        atlaspos : Vec2,
        atlas_size : Vec2,
        color : Vec3,
    }
} else {
    Sprite :: struct #align(16) {
        pos : Vec2,
        size : Vec2,
        atlaspos : Vec2,
        atlas_size : Vec2,
        color : Vec3,
    }
}

Constants :: struct #align(16) {
    screensize : Vec2,
    atlassize  : Vec2,
}

Button_State :: struct {
    ended_down : bool,
    half_transition_count : int,
}

HV_Joystick :: enum {
    Keyboard,
    Joystick1,
    Joystick2,
    Joystick3,
    Joystick4,
}

Buttons :: enum {
    Move_Up,
    Move_Down,
    Move_Right,
    Move_Left,
    Action_Up,
    Action_Down,
    Action_Right,
    Action_Left,
    Start,
    Back,
    L1_Trigger,
    R1_Trigger,
    L2_Trigger,
    R2_Trigger,
}

Controller_Input :: struct {
    is_connected, is_analog: bool,
    stick_avg : Vec2,
    buttons: [Buttons]Button_State,
}

//TODO : Add mouse
Input :: struct {
    Mouse : Vec2,
    cinput: [HV_Joystick]Controller_Input,
}

Entity :: struct {
    pos : Vec2,
    vel : Vec2,
    size : Vec2,
}

Game_State :: struct {
    player : Entity,
}

Memory :: struct {
    sb : [dynamic]Sprite,
    is_init : b32,
    reloaded : b32,
    dt : f32,
    logger : runtime.Logger,
    input : ^Input,
    allocator : runtime.Allocator,
}

draw_rectangle :: proc(sb : ^[dynamic]Sprite, pos, size : Vec2, color := WHITE) {
    r_rect := atlas.glyphs[len(atlas.glyphs) - 8].rect
    append(sb, Sprite{pos, size, {r_rect.x, r_rect.y}, {r_rect.z, r_rect.w}, color})
}

draw_text :: proc(sb : ^[dynamic]Sprite, pos : Vec2, text : string, color := WHITE) {
    startx := pos.x
    starty := pos.y

    for letter in text {
        fnt := atlas.glyphs[0]

        if letter == ' ' {
            startx += 17
            continue
        }

        for glyph in atlas.glyphs {
            if glyph.value == letter {
                fnt = glyph
                break
            }
        }

        if fnt.value == 'A' && letter != 'A' { continue }

        if letter == '\n' {
            starty += fnt.rect.y + f32(fnt.offset_y)
            startx = pos.x
            continue
        }

        startx1 := startx + f32(fnt.offset_x)
        starty1 := starty + f32(fnt.offset_y)

        endx := fnt.rect.z
        endy := fnt.rect.w

        append(sb, Sprite{{startx1, starty1}, {endx, endy}, {fnt.rect.x,
               fnt.rect.y}, { fnt.rect.z,  fnt.rect.w}, color})

        startx += f32(fnt.advance_x)
    }
}

draw_sprite :: proc(sb : ^[dynamic]Sprite, tname : atlas.Texture_Name,
                    pos, size : Vec2, color := WHITE) {
    arect := atlas.textures[tname].rect
    append(sb, Sprite{ pos, size, {arect.x, arect.y}, {arect.z, arect.w}, color})
}

draw_circle :: proc(sb : ^[dynamic]Sprite, pos : Vec2, radius : f32, color := WHITE) {
    arect := atlas.textures[.Circle].rect
    append(sb, Sprite{ pos, {radius * 2, radius * 2}, {arect.x, arect.y}, {arect.z, arect.w}, color})
}

@(export)
game_update :: proc(m : ^Memory) {
    if m.is_init == false {
        m.is_init = true
        context.logger = m.logger
        m.sb = make([dynamic]Sprite, 0, MAX_SPRITES, m.allocator)
        log.info("Gamecode Initialized")
    }

    if m.reloaded {
        m.reloaded = false
        context.logger = m.logger
        log.info("GameCode Reloaded")
    }

    // maybe i just want some stuff to always be in memory
    // for that just set the length of the array to that offset
    clear(&m.sb)

    draw_text(&m.sb, {200, 10}, fmt.tprintf("DT : %f", m.dt), GREEN)
    draw_circle(&m.sb, {200, 200}, 50, RED)
    draw_sprite(&m.sb, .Wall, {400, 400}, {50, 50})
    draw_rectangle(&m.sb, {10, 10}, {100, 100})

}

process_keyboard_message :: proc(new_state: ^Button_State, is_down: bool) {
    if new_state.ended_down != is_down {
        new_state.ended_down = is_down
        new_state.half_transition_count += 1
    }
}

was_pressed :: proc(state : ^Button_State) -> bool {
	result  : bool = ((state.half_transition_count > 1) ||
	                 ((state.half_transition_count == 1) &&
	                  (state.ended_down)))
	return result
}