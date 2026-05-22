package game

import "vendor:portmidi"
import rl "vendor:raylib"
import "core:encoding/json"
import "core:os"
import "core:mem"
import "core:math"
import "core:fmt"
import "core:strings"
import "core:path/filepath"

Coordinate :: f32
Speed      :: f32
Time       :: f32
Thickness  :: f32
Radius     :: f32
Dimension  :: f32

ScreenCoord :: i32
FontSize    :: i32
PixelCount  :: i32

STATE_ARENA_SIZE :: 4 * 1024 * 1024
MENU_ARENA_SIZE :: 1 * 1024 * 1024

PLAYER_RADIUS  :: Radius(8)
CONSTRUCTOR_WALL_LENGTH :: f32(100)  

Screen :: enum { MAIN_MENU, IN_GAME, GAME_OVER }

GameState :: struct
{
    screen:         Screen,
    menu:           MenuState,
    state:          ^State,
    stateAllocator: StateAllocator,
}

BulletType :: enum { BOUNCER, CONSTRUCTOR, BULLDOZER }
Bullet :: struct
{
    position: rl.Vector2,
    velocity: rl.Vector2,
    radius:   Radius,
    type:     BulletType,
}

Wall :: struct
{
    p1, p2:      rl.Vector2,
    thickness:   Thickness,
    invulnerable: bool,
}
Spawner :: struct
{
    position:       rl.Vector2,
    spawnFrequency: Time,
    speed:          Speed,
    bulletType:     BulletType,
    timer:          Time,
}
State :: struct
{
    playerPosition: rl.Vector2,
    playerVelocity: rl.Vector2,
    playerSpeed:    Speed,
    wallThickness:  Thickness,
    bullets:        [dynamic]Bullet,
    walls:          [dynamic]Wall,
    spawners:       [dynamic]Spawner,
    timeSurvived:   Time,
    mapSize:        [2]Dimension,
}

StateAllocator :: struct
{
    buffer: []byte,
    arena: mem.Arena,
}

MapConfig :: struct {
    player_speed:   i32,
    bullet_spawners: []struct {
        x, y:            i32,
        spawn_frequency: Time,
        velocity:        i32,
        bullet_type:     string,
    },
    walls: []struct {
        x1, y1, x2, y2: i32,
        invulnerable:    bool,
    },
    map_width:      i32,
    map_height:     i32,
    wall_thickness: i32,
}

MenuState :: struct
{
    arena:        mem.Arena,
    buffer:       []byte,
    mapFiles:       [dynamic]string,
    selected:       PixelCount,
    dropdownOpen:   bool,
    itemsText:      string,  
}


StateAllocatorInit :: proc(stateAllocator: ^StateAllocator)
{
    stateAllocator.buffer = make([]byte, STATE_ARENA_SIZE)
    mem.arena_init(&stateAllocator.arena, stateAllocator.buffer)
}

StateAllocatorFree :: proc(stateAllocator: ^StateAllocator)
{
    delete(stateAllocator.buffer)
}

WallClosestPoint :: proc(wall: Wall, center: rl.Vector2) -> (closest: rl.Vector2, dist: f32)
{
    d := wall.p2 - wall.p1
    lenSq := d.x*d.x + d.y*d.y

    t := f32(0)
    if lenSq > 0 do t = clamp(((center.x - wall.p1.x)*d.x + (center.y - wall.p1.y)*d.y) / lenSq, 0, 1)

    closest = {wall.p1.x + t*d.x, wall.p1.y + t*d.y}
    diff   := center - closest
    dist     = math.sqrt(diff.x*diff.x + diff.y*diff.y)
    return
}

ResolveWallCollisions :: proc(state: ^State)
{
    center := &state.playerPosition

    for wall in state.walls
    {
        if !rl.CheckCollisionCircleLine(center^, PLAYER_RADIUS + wall.thickness/2, wall.p1, wall.p2) do continue

        closest, dist := WallClosestPoint(wall, center^)
        minDist := PLAYER_RADIUS + wall.thickness / 2

        if dist > 0
        {
            n := (center^ - closest) / dist
            center^ += n * (minDist - dist)
        }
        else
        {
            d := wall.p2 - wall.p1
            l  := math.sqrt(d.x*d.x + d.y*d.y)
            center^ += {( d.x / l) * minDist, (-d.y / l) * minDist}
        }
    }
}

LoadMap :: proc(path: string, stateAllocator: ^StateAllocator) -> (state: ^State, ok: bool)
{
    data, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil do return
    defer delete(data)

    config: MapConfig
    if json.unmarshal(data, &config) != nil do return

    alloc  := mem.arena_allocator(&stateAllocator.arena)
    state   = new(State, alloc)

    state.playerPosition = {400, 300}
    state.playerSpeed    = Speed(config.player_speed)
    state.wallThickness  = Thickness(config.wall_thickness)
    state.spawners       = make([dynamic]Spawner, 0, len(config.bullet_spawners), alloc)
    state.walls          = make([dynamic]Wall, 0, 4, alloc)
    state.mapSize        = {Dimension(config.map_width), Dimension(config.map_height)}

    for s in config.bullet_spawners
    {
        type := BulletType.BOUNCER
        if s.bullet_type == "constructor" do type = .CONSTRUCTOR
        if s.bullet_type == "bulldozer"   do type = .BULLDOZER

        append(&state.spawners, Spawner{
            position       = {Coordinate(s.x), Coordinate(s.y)},
            spawnFrequency = s.spawn_frequency,
            speed          = Speed(s.velocity),
            bulletType     = type,
        })
    }

    t := Thickness(config.wall_thickness)
    w := Dimension(config.map_width)
    h := Dimension(config.map_height)

    append(&state.walls, Wall{ p1 = {0, 0}, p2 = {w, 0}, thickness = t, invulnerable = true })
    append(&state.walls, Wall{ p1 = {0, h}, p2 = {w, h}, thickness = t, invulnerable = true })
    append(&state.walls, Wall{ p1 = {0, 0}, p2 = {0, h}, thickness = t, invulnerable = true })
    append(&state.walls, Wall{ p1 = {w, 0}, p2 = {w, h}, thickness = t, invulnerable = true })

    for wall in config.walls
    {
        append(&state.walls, Wall{
            p1           = {Coordinate(wall.x1), Coordinate(wall.y1)},
            p2           = {Coordinate(wall.x2), Coordinate(wall.y2)},
            thickness    = t,
            invulnerable = wall.invulnerable,
        })
    }

    ok = true
    return
}

HandleInput :: proc(state: ^State)
{
    state.playerVelocity = {0, 0}
    if rl.IsKeyDown(.LEFT)  do state.playerVelocity.x = -1
    if rl.IsKeyDown(.RIGHT) do state.playerVelocity.x =  1
    if rl.IsKeyDown(.UP)    do state.playerVelocity.y = -1
    if rl.IsKeyDown(.DOWN)  do state.playerVelocity.y =  1
}

Update :: proc(state : ^State) -> bool
{
    dt := rl.GetFrameTime()
    state.timeSurvived += dt
    state.playerPosition += state.playerVelocity * state.playerSpeed * dt
    ResolveWallCollisions(state)
    UpdateSpawners(state)
    UpdateBullets(state)

    for bullet in state.bullets
    {
        if rl.CheckCollisionCircles(state.playerPosition, PLAYER_RADIUS, bullet.position, bullet.radius) do return true
    }
    return false
}

UpdateSpawners :: proc(state: ^State)
{
    dt := rl.GetFrameTime()

    for &spawner in state.spawners
    {
        spawner.timer += dt
        if spawner.timer < spawner.spawnFrequency do continue

        spawner.timer = 0

        // Fire towards player
        dir := state.playerPosition - spawner.position
        length := math.sqrt(dir.x*dir.x + dir.y*dir.y)
        if length == 0 do continue

        append(&state.bullets, Bullet{position = spawner.position, velocity = (dir / length) * spawner.speed, radius = 5, type = spawner.bulletType})
    }
}

SpawnConstructorWall :: proc(state: ^State, impact: rl.Vector2, velocity: rl.Vector2)
{
    speed := math.sqrt(velocity.x*velocity.x + velocity.y*velocity.y)
    if speed == 0 do return

    perp := rl.Vector2{-velocity.y, velocity.x} / speed

    half := CONSTRUCTOR_WALL_LENGTH / 2
    p1   := rl.Vector2{impact.x - perp.x * half, impact.y - perp.y * half}
    p2   := rl.Vector2{impact.x + perp.x * half, impact.y + perp.y * half}

    append(&state.walls, Wall{p1 = p1, p2 = p2, thickness = state.wallThickness, invulnerable = false})
}

UpdateBullets :: proc(state: ^State)
{
    dt := rl.GetFrameTime()
    bulletsToRemove := make([dynamic]int, context.temp_allocator)
    wallsToRemove   := make([dynamic]int, context.temp_allocator)

    for bulletIndex in 0..<len(state.bullets)
    {
        bullet := &state.bullets[bulletIndex]
        bullet.position += bullet.velocity * dt

        for wallIndex in 0..<len(state.walls)
        {
            wall := &state.walls[wallIndex]
            if !rl.CheckCollisionCircleLine(bullet.position, bullet.radius + wall.thickness/2, wall.p1, wall.p2) do continue

            switch bullet.type
            {
            case .CONSTRUCTOR:
                SpawnConstructorWall(state, bullet.position, bullet.velocity)
                append(&bulletsToRemove, bulletIndex)

            case .BULLDOZER:
                if !wall.invulnerable
                {
                    append(&wallsToRemove,   wallIndex)
                    append(&bulletsToRemove, bulletIndex)
                }
                else
                {
                    BounceOffWall(bullet, wall^)
                }

            case .BOUNCER:
                BounceOffWall(bullet, wall^)
            }
            break
        }
    }

    for i := len(wallsToRemove)   - 1; i >= 0; i -= 1 do unordered_remove(&state.walls,   wallsToRemove[i])
    for i := len(bulletsToRemove) - 1; i >= 0; i -= 1 do unordered_remove(&state.bullets, bulletsToRemove[i])
}

BounceOffWall :: proc(bullet: ^Bullet, wall: Wall)
{
    closest, dist := WallClosestPoint(wall, bullet.position)
    minDist := bullet.radius + wall.thickness / 2

    if dist > 0
    {
        n := (bullet.position - closest) / dist
        bullet.position += n * (minDist - dist)
        dot := bullet.velocity.x*n.x + bullet.velocity.y*n.y
        bullet.velocity -= 2 * dot * n
    }
    else
    {
        d := wall.p2 - wall.p1
        l  := math.sqrt(d.x*d.x + d.y*d.y)
        n := rl.Vector2{-d.y / l, d.x / l}
        bullet.position += n * minDist
        dot := bullet.velocity.x*n.x + bullet.velocity.y*n.y
        bullet.velocity -= 2 * dot * n
    }
}

Draw :: proc(state : ^State)
{
    screenWidth := Coordinate(rl.GetScreenWidth())
    screenHeight := Coordinate(rl.GetScreenHeight())

    camera := rl.Camera2D{
        offset   = {(screenWidth - state.mapSize.x) / 2, (screenHeight - state.mapSize.y) / 2},
        target   = {0, 0},
        rotation = 0,
        zoom     = 1,
    }

    rl.BeginDrawing()
    rl.ClearBackground(rl.BLACK)

    rl.BeginMode2D(camera)

        rl.ClearBackground(rl.WHITE)

        rl.DrawCircleV(state.playerPosition, PLAYER_RADIUS, rl.BLUE)

        for spawner in state.spawners do rl.DrawCircleV(spawner.position, 24, rl.GREEN)

        for bullet in state.bullets
        {
            switch bullet.type
            {
            case .BOUNCER:     rl.DrawCircleV(bullet.position, bullet.radius, rl.RED)
            case .CONSTRUCTOR: rl.DrawCircleV(bullet.position, bullet.radius, rl.ORANGE)
            case .BULLDOZER:   rl.DrawCircleV(bullet.position, bullet.radius, rl.MAROON)
            }
        }

        for wall in state.walls do rl.DrawLineEx(wall.p1, wall.p2, wall.thickness, rl.GRAY)

    rl.EndMode2D()

    DrawHUD(state)   
    rl.EndDrawing()
}

DrawHUD :: proc(state: ^State)
{
    dt  := rl.GetFrameTime()
    fps := rl.GetFPS()

    minutes := int(state.timeSurvived) / 60
    seconds := int(state.timeSurvived) % 60

    lines := [?]string{
        fmt.tprintf("Bullets:       %d",      len(state.bullets)),
        fmt.tprintf("Walls:         %d",      len(state.walls)),
        fmt.tprintf("Frame time:    %.2f", dt * 1000),
        fmt.tprintf("FPS:           %d",      fps),
        fmt.tprintf("Time survived: %02d:%02d", minutes, seconds),
    }

    x     :: 10
    y     :: 10
    size  :: 24
    gap   :: 32

    for line, i in lines
    {
        rl.DrawText(strings.clone_to_cstring(line, context.temp_allocator), x, y + i32(i) * gap, size, rl.DARKGRAY)
    }
}

DrawMainMenu :: proc(gameState: ^GameState) -> bool
{
    rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), 40)
    menuState := &gameState.menu
    screenWidth := f32(rl.GetScreenWidth())
    screenHeight := f32(rl.GetScreenHeight())
    rl.BeginDrawing()
    rl.ClearBackground(rl.BLACK)

    titleSize := i32(100)
    title := rl.MeasureText("BULLET DODGE", titleSize)
    rl.DrawText("BULLET DODGE", (rl.GetScreenWidth() - title) / 2, 160, titleSize, rl.WHITE)

    dropMenuX := (screenWidth - 500) / 2
    dropMenuY := screenHeight / 2 - 100

    dropMenuBounds := rl.Rectangle{dropMenuX, dropMenuY, 500, 60}
    buttonBounds := rl.Rectangle{dropMenuX, dropMenuY + 150, 500, 60}
    wasOpen  := menuState.dropdownOpen

    if rl.GuiDropdownBox(dropMenuBounds, strings.clone_to_cstring(menuState.itemsText, context.temp_allocator), &menuState.selected, menuState.dropdownOpen) == true
    {
        menuState.dropdownOpen = !menuState.dropdownOpen
        if !wasOpen do RefreshMapList(menuState)
    }

    loaded := false
    if !menuState.dropdownOpen
    {
        if rl.GuiButton(buttonBounds, "PLAY") == true && len(menuState.mapFiles) > 0
        {
            loaded = true
        }
    }

    rl.EndDrawing()
    return loaded
}

DrawGameOver :: proc(state: ^State)
{
    minutes := int(state.timeSurvived) / 60
    seconds := int(state.timeSurvived) % 60

    screenWidth := rl.GetScreenWidth()
    screenHeight := rl.GetScreenHeight()

    rl.BeginDrawing()
    rl.ClearBackground(rl.BLACK)

    title  : cstring = "YOU DIED"
    titleSize :: 72
    titleWidth := rl.MeasureText(title, titleSize)
    rl.DrawText(title, (screenWidth - titleWidth) / 2, screenHeight / 3, titleSize, rl.RED)

    survived := strings.clone_to_cstring(fmt.tprintf("Time survived: %02d:%02d", minutes, seconds), context.temp_allocator)
    survivedSize :: 32
    survivedWidth := rl.MeasureText(survived, survivedSize)
    rl.DrawText(survived, (screenWidth - survivedWidth) / 2, screenHeight / 3 + 100, survivedSize, rl.WHITE)

    hint  : cstring = "Press ENTER to return to menu"
    hintSize :: 20
    hintWidth := rl.MeasureText(hint, hintSize)
    rl.DrawText(hint, (screenWidth - hintWidth) / 2, screenHeight / 3 + 160, hintSize, rl.DARKGRAY)

    rl.EndDrawing()
}

LoadMapFileList :: proc(allocator: mem.Allocator) -> (files: [dynamic]string, ok: bool)
{
    files = make([dynamic]string, allocator)

    handle, err := os.open("Maps")
    if err != nil do return

    defer os.close(handle)

    infos, _ := os.read_dir(handle, -1, context.temp_allocator)
    for info in infos
    {
        if filepath.ext(info.name) == ".json"
        {
            append(&files, fmt.aprintf("maps/%s", info.name, allocator = allocator))
        }
    }

    ok = true
    return
}

MenuStateInit :: proc(menuState: ^MenuState)
{
    menuState.buffer = make([]byte, MENU_ARENA_SIZE)
    mem.arena_init(&menuState.arena, menuState.buffer)
    RefreshMapList(menuState)
}

MenuStateFree :: proc(menuState: ^MenuState)
{
    delete(menuState.buffer)
}

BuildItemsText :: proc(files: [dynamic]string, allocator: mem.Allocator) -> string
{
    names := make([dynamic]string, context.temp_allocator)
    for f in files do append(&names, filepath.base(f))
    return strings.join(names[:], ";", allocator)
}

RefreshMapList :: proc(menuState: ^MenuState) -> bool
{
    mem.arena_free_all(&menuState.arena)
    alloc := mem.arena_allocator(&menuState.arena)

    menuState.mapFiles  = LoadMapFileList(alloc) or_return
    menuState.itemsText = BuildItemsText(menuState.mapFiles, alloc)
    return true
}

main :: proc()
{
    rl.InitWindow(1920, 1080, "Bullet Dodge")
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    rl.SetTargetFPS(60)

    gameState: GameState
    gameState.screen = .MAIN_MENU
    StateAllocatorInit(&gameState.stateAllocator)
    defer StateAllocatorFree(&gameState.stateAllocator)
    MenuStateInit(&gameState.menu)
    defer MenuStateFree(&gameState.menu)

    rl.SetExitKey(.KEY_NULL)
    for !rl.WindowShouldClose()
    {
        switch gameState.screen
        {
            case .MAIN_MENU:
                if DrawMainMenu(&gameState)
                {
                    mem.arena_free_all(&gameState.stateAllocator.arena)
                    state, ok := LoadMap(gameState.menu.mapFiles[gameState.menu.selected], &gameState.stateAllocator)
                    if ok
                    {
                        gameState.state  = state
                        gameState.screen = .IN_GAME
                    }
                }

            case .IN_GAME:
                if rl.IsKeyPressed(.ESCAPE)
                {
                    gameState.screen = .MAIN_MENU
                    continue
                }
                HandleInput(gameState.state)
                if Update(gameState.state) do gameState.screen = .GAME_OVER
                else do Draw(gameState.state)
            
            case .GAME_OVER:
                DrawGameOver(gameState.state)
                if rl.IsKeyPressed(.ENTER)
                {
                    gameState.screen = .MAIN_MENU
                }
            
        }

        mem.free_all(context.temp_allocator)
        
    }
}