package game

import "base:runtime"
import "core:log"
import "core:fmt"
import "core:math"
import la "core:math/linalg"

import "../atlas"

MAX_SPRITES :: 8192

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
IVec2 :: [2]i32

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

    DEBUG_EDITOR,
    MOUSE_LEFT,
    MOUSE_RIGHT,
}

Controller_Input :: struct {
    is_connected, is_analog: bool,
    stick_avg : Vec2,
    buttons: [Buttons]Button_State,
}

//TODO : Add mouse
Input :: struct {
    mouse : Vec2,
    cinput: [HV_Joystick]Controller_Input,
}

Entity :: struct {
    grounded : b32,
    pos : Vec2,
    vel : Vec2,
    size : Vec2,
}

State :: struct {
    player : Entity,
}

Memory :: struct {
    sb : [dynamic]Sprite,
    tiles : [dynamic]AABB,
    is_init : b32,
    reloaded : b32,
    dt : f32,
    logger : runtime.Logger,
    input : ^Input,
    state : ^State,
    allocator : runtime.Allocator,
    editor : bool,
}

AABB :: struct {
    min, max : Vec2,
}

Circle :: struct {
    pos : Vec2,
    radius : f32,
}


draw_rectangle :: proc(sb : ^[dynamic]Sprite, pos, size : Vec2, color := WHITE) {
    r_rect := atlas.glyphs[len(atlas.glyphs) - 8].rect
    append(sb, Sprite{pos, size, {r_rect.x, r_rect.y}, {r_rect.z, r_rect.w}, color})
}

draw_aabb :: proc(sb : ^[dynamic]Sprite, aabb : AABB, color := WHITE) {
    draw_rectangle(sb, aabb.min, aabb.max - aabb.min, color)
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

draw_circle_vec :: proc(sb : ^[dynamic]Sprite, pos : Vec2, radius : f32, color := WHITE) {
    arect := atlas.textures[.Circle].rect
    append(sb, Sprite{ pos - radius, {radius * 2, radius * 2}, {arect.x, arect.y}, {arect.z, arect.w}, color})
}

draw_circle_c :: proc(sb : ^[dynamic]Sprite, c : Circle, color := WHITE) {
    arect := atlas.textures[.Circle].rect
    append(sb, Sprite{ c.pos - c.radius, {c.radius * 2, c.radius * 2}, {arect.x, arect.y}, {arect.z, arect.w}, color})
}

draw_circle :: proc { draw_circle_vec, draw_circle_c}

circle_vs_circle :: proc(a, b : Circle) -> bool {
    r := a.radius + b.radius
    r *= r
    c := a.pos - b.pos
    cc := la.dot(c, c)
    return r > cc
}

aabb_vs_circle :: proc(a : AABB, b : Circle) -> bool {
    l := la.clamp(b.pos, a.min, a.max)
    c := b.pos - l
    cc := la.dot(c, c)
    r := b.radius * b.radius
    return r > cc
}

aabb_vs_aabb :: proc(a, b : AABB) -> bool {
    if(a.max.x < b.min.x || a.min.x > b.max.x) { return false }
    if(a.max.y < b.min.y || a.min.y > b.max.y) { return false }
    return true
}

get_collision_rec :: proc(a, b : Vec4) -> Vec4 {
    result : Vec4

    result.x = max(a.x, b.x)
    right := min(a.x + a.z, b.x + b.z)
    result.y = max(a.y, b.y)
    bottom := min(a.y + a.w, b.y, b.w)

    if(result.x < right && result.y < bottom ) {
        result.z = right - result.x
        result.w = bottom - result.y
    }

    return result
}

get_collision_aabb :: proc(a, b : AABB) -> AABB {
    result : AABB

    result.min.x = max(a.min.x, b.min.x)
    result.min.y = max(a.min.y, b.min.y)

    right := min(a.max.x, b.max.x)
    bottom := min(a.max.y, b.max.y)

    if result.min.x < right && result.min.y < bottom {
        result.max.y = bottom
        result.max.x = right
    }

    return result

}

editor_stuff :: proc(sb : ^[dynamic]Sprite, tiles : ^[dynamic]AABB, input : ^Input) {
    TILE_SIZE :: 32

    snapped_x := (i32(input.mouse.x) / TILE_SIZE) * TILE_SIZE
    snapped_y := (i32(input.mouse.y) / TILE_SIZE) * TILE_SIZE
    snapped_pos := Vec2{f32(snapped_x), f32(snapped_y)}

    draw_rectangle(sb, snapped_pos, {TILE_SIZE, TILE_SIZE}, RED)



    if input.cinput[.Keyboard].buttons[.MOUSE_LEFT].ended_down {
        new_aabb := AABB {
            min = snapped_pos,
            max = snapped_pos + TILE_SIZE,
        }

        can_append := true

        for w in tiles {
            aabb_check := new_aabb
            aabb_check.min += 2
            aabb_check.max -= 2



            if aabb_vs_aabb(aabb_check, w) {
                can_append = false
                break
            }
        }

        if can_append {
            append(tiles, new_aabb)
        }
    }

    if input.cinput[.Keyboard].buttons[.MOUSE_RIGHT].ended_down {
        new_aabb := AABB {
            min = snapped_pos,
            max = snapped_pos + TILE_SIZE,
        }

        for w, ind in tiles {
            aabb_check := new_aabb
            aabb_check.min += 1
            aabb_check.max -= 1

            if aabb_vs_aabb(aabb_check, w) {
                unordered_remove(tiles, ind)
            }
        }
    }

}

@(export)
game_update :: proc(m : ^Memory) {
    if m.is_init == false {
        m.is_init = true
        context.logger = m.logger
        m.sb = make([dynamic]Sprite, 0, MAX_SPRITES, m.allocator)
        m.state = new(State, m.allocator)
        m.tiles = make([dynamic]AABB, 0, 4192, m.allocator)
        m.state.player.vel = {0, 0}
        m.state.player.size = {32, 32}
        log.info("Gamecode Initialized")

            clear(&m.tiles)

        ground_aabb := AABB{
            min = {0, 640},
            max = {1280, 720},
        }

        append(&m.tiles, ground_aabb)
        append(&m.tiles, AABB{{0, 200}, {300, 420}})
    }

    if m.reloaded {
        m.reloaded = false
        context.logger = m.logger
        log.info("GameCode Reloaded")
    }

    player := &m.state.player
    dt : f32 = 0.016
    keyboard := m.input.cinput[.Keyboard].buttons


    if was_pressed(&keyboard[.DEBUG_EDITOR]) {
        m.editor = !m.editor
        //editor_stuff(&m.sb, &m.tiles, m.input)
    }
    // maybe i just want some stuff to always be in memory
    // for that just set the length of the array to that offset
    clear(&m.sb)
    //for now


    player.vel.y += 1000 * dt

    if keyboard[.Move_Left].ended_down {
        player.vel.x -= 140
    } else if keyboard[.Move_Right].ended_down {
        player.vel.x += 140
    }

    grounded := false

    player.pos.y += player.vel.y * dt

    player_aabb := AABB {
        min = player.pos,
        max = player.pos + player.size,
    }

    //y osa
    for c in m.tiles {
        overlap := get_collision_aabb(c, player_aabb)

        if overlap.max.y != 0 {
            player.vel.y = 0
            sign : f32 = (player_aabb.max.y / 2) < (c.max.y / 2) ? -1 : 1
            player.pos.y += (overlap.max.y - overlap.min.y) * sign
            grounded = true
            break
        }
    }

    player.pos.x += player.vel.x * dt

    player_aabb.min = player.pos
    player_aabb.max = player.pos + player.size

    for c in m.tiles {
        overlap := get_collision_aabb(c, player_aabb)

        if overlap.max.x != 0 {
            sign : f32 = (player_aabb.max.x / 2) < (c.max.x / 2) ? -1 : 1
            player.pos.x += (overlap.max.x - overlap.min.x) * sign
            player.vel.x = 0
            break
        }
    }

    if grounded && was_pressed(&keyboard[.Action_Up]) {
        player.vel.y = -500
    }

    if (m.editor) {
        editor_stuff(&m.sb, &m.tiles, m.input)
    }

    player.vel.x = 0

    draw_rectangle(&m.sb, player.pos, player.size)
    for w in m.tiles {
        draw_aabb(&m.sb, w, RED)
    }
}

shutdown :: proc(m : ^Memory) {
    //b2.DestroyWorld(m.world_id)
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