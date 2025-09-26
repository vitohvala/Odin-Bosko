package Game6

import win "core:sys/windows"
import "core:mem"
import "core:os"
import v "core:mem/virtual"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:log"
import "core:time"
import "core:dynlib"
import d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import d3d  "vendor:directx/d3d_compiler"
import stbi "vendor:stb/image" //remove this

import g "game"


when ODIN_OS == .Windows {
    DLL_EXT :: ".dll"
    PATH_SEPARATOR :: "\\"
} else {
    PATH_SEPARATOR :: "/"
}

TEXTURE_ATLAS :: #load("../build/assets/atlas.png")

Vec2 :: [2]f32
Vec3 :: [3]f32

Dx_Context :: struct {
    device : ^d11.IDevice,
    dcontext: ^d11.IDeviceContext,
    framebuffer_rtv: ^d11.IRenderTargetView,
    swapchain : ^dxgi.ISwapChain1,
    viewport : d11.VIEWPORT,
    vertex_shader : ^d11.IVertexShader,
    pixel_shader :  ^d11.IPixelShader,
    sprite_SRV : ^d11.IShaderResourceView,
    sprite_buffer : ^d11.IBuffer,
    rstate : ^d11.IRasterizerState,
    atlas_SRV : ^d11.IShaderResourceView,
    sampler : ^d11.ISamplerState,
    constant_buffer : ^d11.IBuffer,
}

Game_API :: struct {
	lib: dynlib.Library,
	update: proc(^g.Memory),
	write_time: os.File_Time,
}

/*****************************************************************************/
/*GLOBALS*/
grunning := false
//(NOTE) : This should exist ONLY in DEBUG builds
gshaders_hlsl : string
shader_lwtime : os.File_Time



hv_messagebox :: #force_inline proc (s : string) {
    win.MessageBoxW(nil, win.utf8_to_wstring(s), win.L("Error"),
                    win.MB_OK | win.MB_ICONERROR)
}

hv_assert :: #force_inline proc(assertion : bool, msg_args : ..any,
                                loc := #caller_location) {
    if !assertion {
        lp_msg_buf : win.wstring
        dw := win.GetLastError()
        message := fmt.tprint(..msg_args)

        lp_len := win.FormatMessageW(win.FORMAT_MESSAGE_ALLOCATE_BUFFER |
                              win.FORMAT_MESSAGE_FROM_SYSTEM |
                              win.FORMAT_MESSAGE_IGNORE_INSERTS,
                              nil, dw,
                              win.MAKELANGID(win.LANG_NEUTRAL, win.SUBLANG_DEFAULT),
                              lp_msg_buf, 0, nil)
        if lp_len == 0 {
            hv_messagebox(message)
            win.ExitProcess(dw)
        }

        err_msg_str, err := win.wstring_to_utf8(lp_msg_buf, int(lp_len))

        if int(err) > 0 {
            enum_str, _ := fmt.enum_value_to_string(err)
            hv_messagebox(enum_str)
            win.ExitProcess(dw)
        }

        assertion_strings := [?]string {err_msg_str, message}
        assertion_string := strings.concatenate(assertion_strings[:])

        hv_messagebox(assertion_string)
        win.LocalFree(lp_msg_buf)

        win.ExitProcess(dw)
    }
}

hv_asserthr :: proc(hr : win.HRESULT, msg : ..any, loc := #caller_location) {
    hv_assert(win.SUCCEEDED(hr), msg)
}

create_window :: proc(width, height : i32, window_name : string) -> win.HWND {
    instance := win.HINSTANCE(win.GetModuleHandleW(nil))
    hv_assert(instance != nil)

    wca : win.WNDCLASSW
    wca.hInstance = instance
    wca.lpszClassName = win.L("Odin ROCKS")
    wca.style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC
    wca.lpfnWndProc = win_proc
    wca.hIcon = win.LoadIconW(nil, transmute(win.wstring)(win.IDI_APPLICATION))
    wca.hCursor = win.LoadCursorW(nil, transmute(win.wstring)(win.IDC_ARROW))

    cls := win.RegisterClassW(&wca)
    hv_assert(cls != 0, "Class creation failed")

    wrect := win.RECT{0, 0, width, height}
    win.AdjustWindowRect(&wrect, win.WS_OVERLAPPEDWINDOW, win.FALSE)

    window_name_wstring := win.utf8_to_wstring(window_name)

    handle := win.CreateWindowExW(0, wca.lpszClassName,
        window_name_wstring,
        win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
        10, 10,
        wrect.right - wrect.left, wrect.bottom - wrect.top,
        nil, nil, instance, nil)

    hv_assert(handle != nil, "Window Creation Failed\n")

    log.info("Created window", window_name)
    return handle
}

pump_msg :: proc(old_input, new_input : ^g.Input) {

    new_input.cinput[.Keyboard] = {}

    new_keyboard := &new_input.cinput[.Keyboard]
    old_keyboard := &old_input.cinput[.Keyboard]

    for oldi, ind in old_keyboard.buttons {
        new_keyboard.buttons[ind].ended_down = oldi.ended_down
    }

    msg : win.MSG
    for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
        switch(msg.message) {
            case win.WM_MOUSEMOVE : {
                new_input.mouse = { f32(win.GET_X_LPARAM(msg.lParam)), f32(win.GET_Y_LPARAM(msg.lParam)) }
            }

            case win.WM_LBUTTONDOWN: {
                g.process_keyboard_message(&new_keyboard.buttons[.MOUSE_LEFT], true)
            }
            case win.WM_LBUTTONUP: {
                g.process_keyboard_message(&new_keyboard.buttons[.MOUSE_LEFT], false)
            }
            case win.WM_RBUTTONDOWN: {
                g.process_keyboard_message(&new_keyboard.buttons[.MOUSE_RIGHT], true)
            }
            case win.WM_RBUTTONUP: {
                g.process_keyboard_message(&new_keyboard.buttons[.MOUSE_RIGHT], false)
            }

            case win.WM_KEYUP : fallthrough
            case win.WM_KEYDOWN : fallthrough
            case win.WM_SYSKEYDOWN : fallthrough
            case win.WM_SYSKEYUP : {
                was_down := ((msg.lParam & (1 << 30)) != 0)
                is_down :=  ((msg.lParam & (1 << 31)) == 0)
                vk_code := msg.wParam

                if is_down != was_down {
                    switch vk_code {
                        case 'W': fallthrough
                        case win.VK_UP: {
                            g.process_keyboard_message(&new_keyboard.buttons[.Move_Up],
                                                       is_down)
                        }
                        case 'S': fallthrough
                        case win.VK_DOWN: {
                            g.process_keyboard_message(&new_keyboard.buttons[.Move_Down],
                                                       is_down)
                        }
                        case 'A': fallthrough
                        case win.VK_LEFT: {
                            g.process_keyboard_message(&new_keyboard.buttons[.Move_Left],
                                                       is_down)
                        }
                        case 'D': fallthrough
                        case win.VK_RIGHT: {
                            g.process_keyboard_message(&new_keyboard.buttons[.Move_Right],
                                                       is_down)
                        }
                        case win.VK_SPACE: {
                            g.process_keyboard_message(&new_keyboard.buttons[.Action_Up],
                                                       is_down)
                        }
                        case 'J': {
                            g.process_keyboard_message(&new_keyboard.buttons[.Action_Right],
                                                       is_down)
                        }
                        case 'K' : {
                            g.process_keyboard_message(&new_keyboard.buttons[.Action_Down],
                                                       is_down)
                        }
                        case 'H' : {
                            g.process_keyboard_message(&new_keyboard.buttons[.Action_Left],
                                                       is_down)
                        }
                        case 'R' : {
                            g.process_keyboard_message(&new_keyboard.buttons[.Start],
                                                       is_down)
                        }
                        case 'N' : {
                            g.process_keyboard_message(&new_keyboard.buttons[.DEBUG_EDITOR],
                                                       is_down)
                        }
                    }
                }

            }
            case : {
                win.TranslateMessage(&msg)
                win.DispatchMessageW(&msg)
            }
        }
    }
}

compile_shader :: proc(entrypoint, shader_model : cstring,
                       blob_out : ^^d11.IBlob) -> win.HRESULT {
    hr : win.HRESULT = win.S_OK
    // TODO : WARNINGS_ARE_ERRORS on release
    dw_shader_flags := d3d.D3DCOMPILE { .ENABLE_STRICTNESS, .PACK_MATRIX_COLUMN_MAJOR }
    when ODIN_DEBUG {
        dw_shader_flags += { .DEBUG, .SKIP_OPTIMIZATION }
    } else {
        dw_shader_flags += { .OPTIMIZATION_LEVEL3 }
    }

    error_blob : ^d11.IBlob
    hr = d3d.Compile(raw_data(gshaders_hlsl), len(gshaders_hlsl), "shaders.hlsl", nil, nil, entrypoint,
                     shader_model, 0, 0, blob_out, &error_blob)

    //should i assert this??
    if error_blob != nil {
        buffer_ptr := error_blob->GetBufferPointer()
        bytes := cast([^]u8)buffer_ptr
        err_str8 := string(bytes[:error_blob->GetBufferSize()])
        log.error(err_str8)
    }

    if (error_blob != nil) { error_blob->Release() }

    log.info("Compiled Shader : ", entrypoint)

    return hr
}

d3d_init :: proc(handle : win.HWND) -> Dx_Context {
    dx : Dx_Context

    feature_levels := [?]d11.FEATURE_LEVEL{._11_0}

    creation_flags : d11.CREATE_DEVICE_FLAGS

    when ODIN_DEBUG {
        creation_flags += { .DEBUG }
    }

    hr := d11.CreateDevice(nil, .HARDWARE, nil, creation_flags,
                           &feature_levels[0], len(feature_levels),
                           d11.SDK_VERSION, &dx.device, nil, &dx.dcontext)
    hv_asserthr(hr, "Failed to create d3d11 device")

    when ODIN_DEBUG {
        info : ^d11.IInfoQueue
        dx.device->QueryInterface(d11.IInfoQueue_UUID, (^rawptr)(&info))
        info->SetBreakOnSeverity(.CORRUPTION, true)
        info->SetBreakOnSeverity(.ERROR, true)
        info->Release()

        dxgi_info : ^dxgi.IInfoQueue

        hr = dxgi.DXGIGetDebugInterface1(0, dxgi.IInfoQueue_UUID, (^rawptr)(&dxgi_info))
        hv_assert(win.SUCCEEDED(hr), "Couldn't get debug interface")

        dxgi_info->SetBreakOnSeverity(dxgi.DEBUG_ALL, .CORRUPTION, true)
        dxgi_info->SetBreakOnSeverity(dxgi.DEBUG_ALL, .ERROR, true)
        dxgi_info->Release()
    }

    {
        dxgi_device : ^dxgi.IDevice
        hr = dx.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))
        hv_asserthr(hr, "Failed Querying dxgi device")

        dxgi_adapter : ^dxgi.IAdapter
        hr = dxgi_device->GetAdapter(&dxgi_adapter)
        hv_asserthr(hr, "DXGI Adapter failed")

        factory : ^dxgi.IFactory2
        hr = dxgi_adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&factory))
        hv_asserthr(hr, "GetParent Failed")

        desc := dxgi.SWAP_CHAIN_DESC1 {
            Format = .R8G8B8A8_UNORM,
            SampleDesc = {1, 0},
            BufferUsage = { .RENDER_TARGET_OUTPUT },
            BufferCount = 2,
            Scaling = .NONE,
            SwapEffect = .FLIP_DISCARD,
        }

        hr = factory->CreateSwapChainForHwnd(dx.device, handle, &desc,
                                            nil, nil, &dx.swapchain)
        hv_asserthr(hr, "CreateSwapChain failed")

        factory->MakeWindowAssociation(handle, { .NO_ALT_ENTER })

        adapter_desc : dxgi.ADAPTER_DESC
        hr = dxgi_adapter->GetDesc(&adapter_desc)

        graphics_card_buf : [128]u8
        graphics_card := win.utf16_to_utf8(graphics_card_buf[:], adapter_desc.Description[:])
        log.infof("Graphics device : {}", graphics_card)

        factory->Release()
        dxgi_adapter->Release()
        dxgi_device->Release()
    }

    framebuffer: ^d11.ITexture2D
    hr = dx.swapchain->GetBuffer(0, d11.ITexture2D_UUID, (^rawptr)(&framebuffer))
    hv_asserthr(hr, "GetBuffer failed")

    hr = dx.device->CreateRenderTargetView(framebuffer, nil, &dx.framebuffer_rtv)
    hv_asserthr(hr, "CreateRenderTargetView failed")

    framebuffer->Release()
    dx.dcontext->OMSetRenderTargets(1, &dx.framebuffer_rtv, nil)

    rect : win.RECT
    win.GetClientRect(handle, &rect)
    width := rect.right - rect.left
    height := rect.bottom - rect.top

    dx.viewport.Width =  f32(width)
    dx.viewport.Height = f32(height)
    dx.viewport.MaxDepth = 1

    dx.dcontext->RSSetViewports(1, &dx.viewport)

    vs_blob : ^d11.IBlob

    compile_shader("vs_main", "vs_5_0", &vs_blob)

    hr = dx.device->CreateVertexShader(vs_blob->GetBufferPointer(),
                                       vs_blob->GetBufferSize(), nil,
                                       &dx.vertex_shader)
    hv_asserthr(hr, "CreateVertexShader failed")
    vs_blob->Release()

    ps_blob : ^d11.IBlob
    compile_shader("ps_main", "ps_5_0", &ps_blob)

    hr = dx.device->CreatePixelShader(ps_blob->GetBufferPointer(),
                                       ps_blob->GetBufferSize(), nil,
                                       &dx.pixel_shader)
    hv_asserthr(hr, "CreatePixelShader failed")
    ps_blob->Release()

    sc_rect := d11.RECT {
        left = win.LONG(dx.viewport.TopLeftX),
        top = win.LONG(dx.viewport.TopLeftY),
        right = win.LONG(dx.viewport.TopLeftX + dx.viewport.Width),
        bottom = win.LONG(dx.viewport.TopLeftY + dx.viewport.Height),
    }

    dx.dcontext->RSSetScissorRects(1, &sc_rect)

    rdesc := d11.RASTERIZER_DESC {
        FillMode = .SOLID,
        CullMode = .NONE,
        DepthClipEnable = true,
        ScissorEnable = true,
    }

    hr = dx.device->CreateRasterizerState(&rdesc, &dx.rstate)
    hv_asserthr(hr, "CreateRasterizer failed")


    twidth, theight, nr_channels : i32
    image_data := stbi.load_from_memory(raw_data(TEXTURE_ATLAS), i32(len(TEXTURE_ATLAS)),
                                        &twidth, &theight, &nr_channels, 4)
    hv_assert(image_data != nil, "Failed to load atlas.png")

    texture_desc := d11.TEXTURE2D_DESC {
        Width = u32(twidth),
        Height = u32(theight),
        MipLevels = 1,
        ArraySize = 1,
        Format = .R8G8B8A8_UNORM,
        SampleDesc = { 1, 0},
        Usage = .IMMUTABLE,
        BindFlags = { .SHADER_RESOURCE },
    }

    texture_data := d11.SUBRESOURCE_DATA {
        pSysMem = &image_data[0],
        SysMemPitch = u32(twidth * 4),
    }

    texture : ^d11.ITexture2D
    dx.device->CreateTexture2D(&texture_desc, &texture_data, &texture)
    dx.device->CreateShaderResourceView(texture, nil, &dx.atlas_SRV)

    log.info("Loaded default texture")

    bdesc := d11.BUFFER_DESC {
        ByteWidth = g.MAX_SPRITES * size_of(g.Sprite),
        Usage = .DYNAMIC,
        BindFlags = { .SHADER_RESOURCE },
        CPUAccessFlags = { .WRITE },
        MiscFlags = { .BUFFER_STRUCTURED },
        StructureByteStride = size_of(g.Sprite),
    }

    dx.device->CreateBuffer(&bdesc, nil, &dx.sprite_buffer)

    srv_desc := d11.SHADER_RESOURCE_VIEW_DESC {
        Format = .UNKNOWN,
        ViewDimension = .BUFFER,
    }
    srv_desc.Buffer.NumElements = g.MAX_SPRITES

    dx.device->CreateShaderResourceView(dx.sprite_buffer, &srv_desc, &dx.sprite_SRV)

    sampler_desc := d11.SAMPLER_DESC {
        AddressU = .WRAP,
        AddressV = .WRAP,
        AddressW = .WRAP,
        MaxAnisotropy = 1,
        ComparisonFunc = .NEVER,
        Filter = .MIN_MAG_MIP_POINT,
        MaxLOD = d11.FLOAT32_MAX,
    }
    dx.device->CreateSamplerState(&sampler_desc, &dx.sampler)

    constants := g.Constants {
        screensize = {dx.viewport.Width, dx.viewport.Height},
        atlassize = { f32(twidth), f32(theight) },
    }

    cbuffer_desc := d11.BUFFER_DESC {
        ByteWidth = size_of(g.Constants),
        Usage = .IMMUTABLE,
        BindFlags = { .CONSTANT_BUFFER },
    }

    srdata := d11.SUBRESOURCE_DATA { pSysMem = &constants }

    dx.device->CreateBuffer(&cbuffer_desc, &srdata, &dx.constant_buffer)

    texture->Release()
    stbi.image_free(image_data)
    log.info("Dx11 Initialized")
    return dx
}

d3d_close :: proc(dx : ^Dx_Context) {
    dx.device->Release()
    dx.dcontext->Release()
    dx.framebuffer_rtv->Release()
    dx.swapchain->Release()
    //dx.viewport->Release()
    dx.vertex_shader->Release()
    dx.pixel_shader->Release()
    dx.sprite_SRV->Release()
    dx.sprite_buffer->Release()
    dx.rstate->Release()
    dx.atlas_SRV->Release()
    dx.sampler->Release()
    dx.constant_buffer->Release()
}

d3d_render :: proc(dx : ^Dx_Context, sb : [dynamic]g.Sprite, vsync := true) {
    sprite_buffer_MSR : d11.MAPPED_SUBRESOURCE

    dx.dcontext->Map(dx.sprite_buffer, 0, .WRITE_DISCARD, nil, &sprite_buffer_MSR)
    {
        mem.copy(sprite_buffer_MSR.pData, raw_data(sb),
                 size_of(g.Sprite) * len(sb))
    }
    dx.dcontext->Unmap(dx.sprite_buffer, 0)

    dx.dcontext->OMSetRenderTargets(1, &dx.framebuffer_rtv, nil)
    dx.dcontext->ClearRenderTargetView(dx->framebuffer_rtv, &[4]f32{0, 0, 0, 0})

    dx.dcontext->IASetPrimitiveTopology(.TRIANGLELIST)
    dx.dcontext->RSSetState(dx.rstate)

    dx.dcontext->VSSetShader(dx.vertex_shader, nil, 0)
    dx.dcontext->VSSetShaderResources(0, 1, &dx.sprite_SRV)
    dx.dcontext->VSSetConstantBuffers(0, 1, &dx.constant_buffer)

    dx.dcontext->PSSetShader(dx.pixel_shader, nil, 0)
    dx.dcontext->PSSetShaderResources(1, 1, &dx.atlas_SRV)
    dx.dcontext->PSSetSamplers(0, 1, &dx.sampler)

    dx.dcontext->DrawInstanced(6, u32(len(sb)), 0, 0)

    dx.swapchain->Present(u32(vsync), {})
}

@(require_results)
load_gamepath :: proc(alloc : runtime.Allocator)  -> (string, string){
    current_dir := os.get_current_directory(context.temp_allocator)
    path_to_dll, _ := strings.concatenate({current_dir, PATH_SEPARATOR, "game", DLL_EXT},
                                          alloc)
    tmp_path_to_dll, _ := strings.concatenate({current_dir, PATH_SEPARATOR, "tmp_game",
                                               DLL_EXT}, alloc)

    return path_to_dll, tmp_path_to_dll
}

@(require_results)
load_shader_path :: proc(alloc : runtime.Allocator, shader_path : string) -> string {
    //TODO : assert ???
    current_dir := os.get_current_directory(context.temp_allocator)
    shader_path, _ := strings.concatenate({ current_dir, PATH_SEPARATOR, shader_path}, alloc)

    return shader_path
}

load_shader :: proc(shader_path : string) {
    shaders_hlsl, err := os.read_entire_file(shader_path, context.temp_allocator)
    hv_assert(err, "Failed reading file", shader_path)
    gshaders_hlsl = string(shaders_hlsl)
    write_time, err_wtime := os.last_write_time_by_name(shader_path)
    if err_wtime == os.ERROR_NONE {
        shader_lwtime = write_time
    } else {
        log.warn("Couldn't get shader writetime")
    }
    log.info("loaded shader : ", shader_path)
}

copy_entire_file :: proc(source_name, target_name: string) -> bool {
    data, read_ok := os.read_entire_file(source_name, context.temp_allocator)
    if read_ok {
        write_ok := os.write_entire_file(target_name, data)
        return write_ok
    }

    return read_ok
}

@(require_results)
load_gamecode :: proc(dll_path, tmp_dll_path : string) -> Game_API {
    game : Game_API

    err : os.Error
    game.write_time, err = os.last_write_time_by_name(dll_path)
    hv_assert(err == os.ERROR_NONE, "Get writetime failed")

    for(copy_entire_file(dll_path, tmp_dll_path) == false) {}

    _, ok := dynlib.initialize_symbols(&game, tmp_dll_path, "game_", "lib")
    hv_assert(ok, "Failed to initialize symbols from game code!")

    return game
}

hot_reload_game :: proc(game : ^Game_API, dll_path, tmp_dll_path : string) -> b32 {
    write_time, err := os.last_write_time_by_name(dll_path)
    hv_assert(err == os.ERROR_NONE, "Get writetime failed")

    if write_time > game.write_time {
         if game.lib != nil {
            if ok := dynlib.unload_library(game.lib); ok {
                game.lib = nil
            }
        }
        game.update = nil

        game^ = load_gamecode(dll_path, tmp_dll_path)
        return true
    }

    return false
}

hot_reload_shader :: proc(dx : ^Dx_Context, shader_path : string) {
    write_time, err := os.last_write_time_by_name(shader_path)
    hv_assert(err == os.ERROR_NONE, "Get writetime failed")



    if write_time > shader_lwtime {
        shader_lwtime = write_time
        blob : ^d11.IBlob

        shaders_hlsl, err := os.read_entire_file(shader_path, context.temp_allocator)
        hv_assert(err, "Failed reading file", shader_path)
        gshaders_hlsl = string(shaders_hlsl)

        res := compile_shader("vs_main", "vs_5_0", &blob)
        if win.FAILED(res) || blob == nil {
            log.warn("Vertex shader compilation failed")
            log.warn("Using old Vertex Shader")
        } else {
            res = dx.device->CreateVertexShader(blob->GetBufferPointer(),
                                                blob->GetBufferSize(), nil,
                                                &dx.vertex_shader)
            log.info("Vertex shader reloaded")
            blob->Release()
        }

        res = compile_shader("ps_main", "ps_5_0", &blob)
        if win.FAILED(res) || blob == nil {
            log.warn("Pixel shader compilation failed")
            log.warn("Using old Pixel Shader")
        } else {
            res = dx.device->CreatePixelShader(blob->GetBufferPointer(),
                                               blob->GetBufferSize(), nil,
                                               &dx.pixel_shader)
            log.info("Pixel shader reloaded")
            blob->Release()
        }

    }
}

//(NOTE): do not use hv_assert in main loop
main :: proc() {
    context.logger = log.create_console_logger(log.Level.Debug,
                                               { .Level, .Procedure, .Thread_Id})

    start_tick := time.tick_now()

    p_arena : v.Arena
    errf := v.arena_init_static(&p_arena)
    hv_assert(errf == .None, "Arena Creation Failed")
    allocator := v.arena_allocator(&p_arena)
    defer v.arena_destroy(&p_arena)

    handle := create_window(1280, 720, "Bosko")
    grunning = true

    shader_path := load_shader_path(allocator, "assets\\shader.hlsl")
    load_shader(shader_path)

    dx := d3d_init(handle)
    defer d3d_close(&dx)

    dll_path, tmp_dll_path := load_gamepath(allocator)
    game := load_gamecode(dll_path, tmp_dll_path)

    mem : g.Memory
    //mem.sb = make([dynamic]g.Sprite, 0, g.MAX_SPRITES, allocator)
    mem.logger = context.logger
    mem.allocator = allocator

    //append(&sb, g.Sprite{})

    input : [2]g.Input
    old_input := &input[0]
    mem.input = &input[1] // new input

    dt_tick := start_tick

    free_all(context.temp_allocator)

    for grunning {
        mem.reloaded = hot_reload_game(&game, dll_path, tmp_dll_path)
        hot_reload_shader(&dx, shader_path)

        mem.dt = f32(time.duration_seconds(time.tick_lap_time(&dt_tick)))

        pump_msg(old_input, mem.input)

        if game.update != nil { game.update(&mem) }

        d3d_render(&dx, mem.sb)

        mem.input, old_input = old_input, mem.input

        free_all(context.temp_allocator)
    }
    g.shutdown(&mem)
}


win_proc :: proc "stdcall" (hwnd: win.HWND,
    msg: win.UINT,
    wparam: win.WPARAM,
    lparam: win.LPARAM) -> win.LRESULT {
    context = runtime.default_context()
    switch msg {
        case win.WM_CLOSE :
            grunning = false
        fallthrough
        case win.WM_DESTROY :
            grunning = false
            win.PostQuitMessage(0)
        return 0
        case win.WM_ERASEBKGND : return 1
        case win.WM_SIZE : {
            crect :win.RECT
            win.GetClientRect(hwnd, &crect)
        }
        case win.WM_NCLBUTTONDOWN:
        {
            //log.info("NCLBUTTONDOWN")
            win.SendMessageW(hwnd, win.WM_NCHITTEST, wparam, lparam)
            point : win.POINT
            win.GetCursorPos(&point)
            win.ScreenToClient(hwnd, &point)
            win.PostMessageW(hwnd, win.WM_MOUSEMOVE, 0, int(point.x | point.y << 16))
        }
        case win.WM_ENTERSIZEMOVE : { win.SetTimer(hwnd, 1, 0, nil); return 0}
        case win.WM_EXITSIZEMOVE : { win.KillTimer(hwnd, 1); return 0 }
        case win.WM_TIMER : {
            //update
            return 0
        }
        case win.WM_PAINT:
        {
            pst : win.PAINTSTRUCT
            win.BeginPaint(hwnd, &pst)

            win.EndPaint(hwnd, &pst)
        }
        case win.WM_SYSKEYDOWN :
        case win.WM_SYSKEYUP :
        case win.WM_KEYDOWN :
        case win.WM_KEYUP : {

        }

    }

    return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}