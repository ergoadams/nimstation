import sdl2, opengl, opengl/glu
import cdrom, bus

discard sdl2.init(INIT_EVERYTHING)

const VERTEX_BUFFER_LEN = 64*1024
const VRAM_SIZE_PIXELS = 1024 * 512

type
    Buffer = ref object
        buffer_object: GLuint
        memory: array[VERTEX_BUFFER_LEN, GLfloat]

proc init_buffer(buffer: Buffer) =
    glGenBuffers(cast[GLsizei](1), buffer.buffer_object.addr)
    glBindBuffer(GL_ARRAY_BUFFER, buffer.buffer_object)
    glBufferData(GL_ARRAY_BUFFER, buffer.memory.sizeof, buffer.memory.addr, GL_STATIC_DRAW)

proc buffer_set(buffer: Buffer, index: uint32, value: tuple[x: GLshort, y: GLshort, z: GLshort]) =
    if index >= VERTEX_BUFFER_LEN:
        quit("buffer overflow", QuitSuccess)

    buffer.memory[index*3 + 0] = value[0].GLfloat
    buffer.memory[index*3 + 1] = value[1].GLfloat
    buffer.memory[index*3 + 2] = 0'f32


proc compile_shader(filename: string, shader_type: GLenum): GLuint =
    var shader: GLuint
    shader = glCreateShader(shader_type)
    var shader_source = readFile(filename)
    var shader_array = allocCStringArray([shader_source])
    glShaderSource(shader, cast[GLsizei](1), shader_array, cast[ptr GLint](nil))
    glCompileShader(shader)
    var isCompiled: GLint
    glGetShaderiv(shader, GL_COMPILE_STATUS, isCompiled.addr)
    if isCompiled == 0:
        echo "Vertex Shader wasn't compiled.  Reason:"
        var logSize: GLint
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, logSize.addr)
        var
            logStr = cast[ptr GLchar](alloc(logSize))
            logLen: GLsizei

        glGetShaderInfoLog(shader, logSize.GLsizei, logLen.addr, logStr)
        echo $logStr
        dealloc(logStr)
    else:
        echo "Vertex Shader compiled successfully."
        return shader

proc link_program(vertex: GLuint, frag: GLuint): GLuint =
    var program: GLuint
    program = glCreateProgram()
    glAttachShader(program, vertex)
    glAttachShader(program, frag)
    glLinkProgram(program)
    var isLinked: GLint
    glGetProgramiv(program, GL_LINK_STATUS, isLinked.addr)
    if isLinked == 0:
        echo "Wasn't able to link shaders.  Reason:"
        var logSize: GLint
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, logSize.addr)
        var
            logStr = cast[ptr GLchar](alloc(logSize))
            logLen: GLsizei
        glGetProgramInfoLog(program, logSize.GLsizei, logLen.addr, logStr)
        echo $logStr
        dealloc(logStr)
    else:
        echo "Shader Program ready!"
        return program

var screenWidth: cint = 1024
var screenHeight: cint = 512
var window = createWindow("NimStation", 100, 100, screenWidth, screenHeight, SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE)
var context = window.glCreateContext()

loadExtensions()
glClearColor(0.0, 0.0, 0.0, 1.0)
glClearDepth(1.0)
glMatrixMode(GL_PROJECTION)
gluOrtho2D(0.0, 1024.0, 512.0, 0.0)
glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
window.glSwapWindow()

# let vertex_shader = compile_shader("src/vertex.glsl", GL_VERTEX_SHADER)
# let fragment_shader = compile_shader("src/fragment.glsl", GL_FRAGMENT_SHADER)
# let program = link_program(vertex_shader, fragment_shader)
# glUseProgram(program)
#
# var vao: GLuint
# glGenVertexArrays(cast[GLsizei](1), vao.addr)
# glBindVertexArray(vao)
#
# var positions = Buffer()
# init_buffer(positions)
# var colors = Buffer()
# init_buffer(colors)
#
#
# glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, 0, nil)
# glVertexAttribPointer(1, 3, cGL_FLOAT, GL_FALSE, 0, nil)
# glEnableVertexAttribArray(0)
# glEnableVertexAttribArray(1)


var evt = sdl2.defaultEvent

var vertices: array[VERTEX_BUFFER_LEN, tuple[r: uint8, g: uint8, b: uint8, x: int16, y: int16]]
var nvertices = 0'u32

var textures: array[VERTEX_BUFFER_LEN, tuple[a: uint8, xlen: uint16, ylen: uint16, x: int16, y: int16, clut_x: uint32, clut_y: uint32, page_x: uint32, page_Y: uint32, texturedepth: uint32, tex_x: uint8, tex_y: uint8]]
var ntextures = 0'u32

var clut_x: uint32
var clut_y: uint32

var page_x: uint32
var page_y: uint32

var texture_depth: uint32

var vram: array[512, array[1024, uint16]]

proc draw_vram() =
    glBegin(GL_POINTS)
    for y in (0 ..< 512):
        for x in (0 ..< 1024):
            let pixel = vram[y][x]
            let r = float32((pixel shl 3) and 0xF8) / 255'f32
            let g = float32((pixel shr 2) and 0xF8) / 255'f32
            let b = float32((pixel shr 7) and 0xF8) / 255'f32
            let xpos = cast[GLint](x)
            let ypos = cast[GLint](y)
            glColor3f(r, g, b)
            glVertex2i(xpos, ypos)
    glEnd()

proc renderer_load_image*(top_left: tuple[a: uint16, b: uint16], resolution: tuple[a: uint16, b: uint16], buffer: array[VRAM_SIZE_PIXELS, uint16], index: uint32) =
    let x1 = top_left[0]
    let y1 = top_left[1]
    let width = resolution[0]
    let height = resolution[1]
    for y in 0'u32 ..< height:
        vram[y1 + y][x1 ..< x1 + width] = buffer[y*width ..< y*width + width]

proc renderer_fill_rectangle*(position: tuple[x: int16, y: int16], size: tuple[x: int16, y: int16],  color: tuple[r: uint8, g: uint8, b: uint8]) =
    var fill_color = 0'u16
    fill_color = fill_color or ((color[0] shr 3) shl 10)
    fill_color = fill_color or ((color[1] shr 3) shl 5)
    fill_color = fill_color or (color[0] shl 3)

    for y in (0 ..< size[1]):
        for x in (0 ..< size[0]):
            vram[position[1] + y][(position[0] + x) and 1023] = fill_color

proc set_clut*(clut: uint32) =
    clut_x = (clut and 0x3F) shl 4
    clut_y = (clut shr 6) and 0x1FF'u32
    #echo "set clut_x to ", clut_x, ", clut y to ", clut_y

proc set_draw_params*(params: uint32) =
    page_x = (params and 0xF'u32) shl 6
    page_y = ((params shr 4) and 1) shl 8
    texture_depth = (params shr 7) and 3
    #echo "set draw params ", page_x, " ", page_y, " ", texture_depth

proc get_texel_4bit(x: uint32, y: uint32, clutx: uint32, cluty: uint32, pagex: uint32, pagey: uint32): uint16 =
    let texel = vram[pagey + y][pagex + (x div 4)]
    let index = (texel shr ((x mod 4) * 4)) and 0xF
    return vram[cluty][clutx + index]

proc get_texel_8bit(x: uint32, y: uint32, clutx: uint32, cluty: uint32, pagex: uint32, pagey: uint32): uint16 =
    let texel = vram[pagey + y][pagex + (x div 2)]
    let index = (texel shr ((x mod 2) * 4)) and 0xFF
    return vram[cluty][clutx + index]

proc get_texel_16bit(x: uint32, y: uint32, clutx: uint32, cluty: uint32, pagex: uint32, pagey: uint32): uint16 =
    return vram[pagey + y][pagex + x]

proc draw_textures() =
    glBegin(GL_POINTS)
    for i in 0 ..< ntextures:
        let texture = textures[i]
        let a = cast[GLubyte](texture[0])
        let xlen = texture[1]
        let ylen = texture[2]
        let x_start = texture[3]
        let y_start = texture[4]
        let clutx = texture[5]
        let cluty = texture[6]
        let pagex = texture[7]
        let pagey = texture[8]
        let texturedepth = texture[9]
        let tex_x = texture[10]
        let tex_y = texture[11]
        for y_pos in 0'u16 ..< ylen:
            for x_pos in 0'u16 ..< xlen:
                let pixel = case texturedepth:
                    of 0: get_texel_4bit(x_pos + tex_x, y_pos + tex_y, clutx, cluty, pagex, pagey)
                    of 1: get_texel_8bit(x_pos, y_pos, clutx, cluty, pagex, pagey)
                    of 2: get_texel_16bit(x_pos, y_pos, clutx, cluty, pagex, pagey)
                    else: 0x00'u16

                let r = cast[GLubyte]((pixel shl 3) and 0xF8)
                let g = cast[GLubyte]((pixel shr 2) and 0xF8)
                let b = cast[GLubyte]((pixel shr 7) and 0xF8)
                let xpos = cast[GLint](cast[uint16](x_start) + x_pos)
                let ypos = cast[GLint](cast[uint16](y_start) + y_pos)
                if pixel != 0:
                    glColor4ub(r, g, b, a)
                    glVertex2i(xpos, ypos)
    glEnd()

proc parse_events*() =
    evt = sdl2.defaultEvent
    while pollEvent(evt):
        case evt.kind:
            of QuitEvent:
                destroy window
                quit("Window closed", QuitSuccess)
            of KeyDown:
                echo evt.key.keysym.scancode
                if evt.key.keysym.scancode == SDL_SCANCODE_F1:
                    cdrom_debug = true
                elif evt.key.keysym.scancode == SDL_SCANCODE_F2:
                    dump_wram()
                elif evt.key.keysym.scancode == SDL_SCANCODE_F3:
                    dump_regs = true
            of KeyUp:
                if evt.key.keysym.scancode == SDL_SCANCODE_F1:
                    cdrom_debug = false
                elif evt.key.keysym.scancode == SDL_SCANCODE_F3:
                    dump_regs = false


            else: discard

proc new_render_frame*() =
    glMemoryBarrier(GL_CLIENT_MAPPED_BUFFER_BARRIER_BIT)
    glDrawArrays(GL_TRIANGLES, cast[GLint](0), cast[GLsizei](nvertices))
    nvertices = 0


proc render_frame*() =

    if nvertices > 0:
        glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
        draw_vram()

        glBegin(GL_TRIANGLES)
        let num = nvertices div 3
        for i in (0 ..< num):
            for j in countup(0, 2):
                let vertice = vertices[(i*3) + uint32(j)]
                let xpos = vertice[3]
                let ypos = vertice[4]
                glColor3f(float32(vertice[0]) / 255'f32, float32(vertice[1]) / 255'f32, float32(vertice[2]) / 255'f32)
                glVertex2i(xpos, ypos)
        glEnd()


    if ntextures > 0:
        draw_textures()

    if (nvertices != 0) or (ntextures != 0):
        window.glSwapWindow()
        nvertices = 0
        ntextures = 0

proc push_triangle*(pos: array[3, tuple], col: array[3, tuple]) =
    if (nvertices + 3 + ntextures) > VERTEX_BUFFER_LEN:
        render_frame()

    for i in 0 ..< 3:
        vertices[nvertices] = (col[i][0], col[i][1], col[i][2], pos[i][0], pos[i][1])
        #buffer_set(positions, nvertices, pos[i])
        #buffer_set(colors, nvertices, col[i])
        nvertices += 1

proc push_quad*(positions: array[4, tuple], colors: array[4, tuple]) =
    if (nvertices + 6 + ntextures) > VERTEX_BUFFER_LEN:
        render_frame()

    for i in 0 ..< 3:
        vertices[nvertices] = (colors[i][0], colors[i][1], colors[i][2], positions[i][0], positions[i][1])
        nvertices += 1

    for i in 1 ..< 4:
        vertices[nvertices] = (colors[i][0], colors[i][1], colors[i][2], positions[i][0], positions[i][1])
        nvertices += 1

proc push_texture_quad*(positions: array[4, tuple], alpha: uint8, tex_x: uint8, tex_y: uint8) =
    if (nvertices + ntextures + 1) > VERTEX_BUFFER_LEN:
        render_frame()

    let xlen = positions[1][0] - positions[0][0]
    let ylen = positions[2][1] - positions[0][1]
    let x = positions[0][0]
    let y = positions[0][1]
    textures[ntextures] = (alpha, cast[uint16](xlen), cast[uint16](ylen), x, y, clut_x, clut_y, page_x, page_y, texture_depth, tex_x, tex_y)
    ntextures += 1
