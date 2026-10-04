// Isolated: node quickshell/tests/wallpaper.cjs (no Quickshell instance or user prefs).
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")
const { spawnSync } = require("node:child_process")

const shellDir = path.resolve(__dirname, "..")
const wallpaper = vm.createContext({})
vm.runInContext(fs.readFileSync(path.join(shellDir, "Wallpaper.js"), "utf8"), wallpaper)
const paths = vm.createContext({})
vm.runInContext(fs.readFileSync(path.join(shellDir, "Paths.js"), "utf8"), paths)
const fixture = fs.mkdtempSync(path.join(__dirname, ".wallpaper-"))
let checks = 0
function equal(actual, expected) { assert.equal(actual, expected); checks++ }
function file(relative) {
    const target = path.join(fixture, relative)
    fs.mkdirSync(path.dirname(target), { recursive: true })
    fs.writeFileSync(target, "fixture")
    return target
}
function request(dir, name = "jellybeans", current = "", remembered = "", keepCurrent = true) {
    return { name, folder: path.join(dir, name, "backgrounds"), current, remembered, keepCurrent, revision: 3, id: 7 }
}
function scan(dir, r) {
    const [program, ...args] = wallpaper.scanCommand(dir, r)
    const result = spawnSync(program, args, { encoding: "utf8" })
    assert.equal(result.status, 0, result.stderr)
    return wallpaper.firstFile(result.stdout)
}

try {
    const dir = path.join(fixture, "installed # % ? ' $()", "quickshell", "themes")
    const first = file(path.relative(fixture, dir) + "/jellybeans/backgrounds/A image\n#%?.PNG")
    const last = file(path.relative(fixture, dir) + "/jellybeans/backgrounds/z.webp")
    const other = file(path.relative(fixture, dir) + "/gruvbox/backgrounds/a.jpg")
    file(path.relative(fixture, dir) + "/jellybeans/backgrounds/0.txt")
    file(path.relative(fixture, dir) + "/jellybeans/backgrounds/nested/0.jpg")
    const custom = file("custom image.jpeg")
    const missing = path.join(fixture, "missing.png")
    equal(scan(dir, request(dir)), first)
    equal(scan(dir, request(dir, "jellybeans", missing)), first)
    equal(scan(dir, request(dir, "jellybeans", "", last)), last)
    equal(scan(dir, request(dir, "jellybeans", "", missing)), first)
    equal(scan(dir, request(dir, "jellybeans", dir, dir)), first)
    equal(scan(dir, request(dir, "jellybeans", custom, last)), custom)
    equal(scan(dir, request(dir, "jellybeans", "", custom)), custom)
    equal(scan(dir, request(dir, "empty")), other)
    equal(scan(dir, request(dir, "empty", "", custom)), custom)
    equal(scan(dir, request(dir, "jellybeans", custom, last, false)), last)
    equal(scan(dir, request(dir, "empty", custom, "", false)), custom)
    equal(scan(dir, request(dir, "empty", missing, "", false)), other)
    const emptyDir = path.join(fixture, "no-themes")
    equal(scan(emptyDir, request(emptyDir)), "")
    equal(scan(emptyDir, request(emptyDir, "empty", missing, missing)), "")
    fs.unlinkSync(last)
    equal(scan(dir, request(dir, "jellybeans", last, last)), first)
    fs.symlinkSync(missing, path.join(dir, "jellybeans/backgrounds/0-broken.jpg"))
    equal(scan(dir, request(dir)), first)

    const link = path.join(fixture, "config-quickshell")
    fs.symlinkSync(path.dirname(dir), link)
    const linkedDir = paths.fromFileUrl(new URL("themes", paths.toFileUrl(link + "/")).href)
    equal(scan(linkedDir, request(linkedDir)), path.join(linkedDir, "jellybeans/backgrounds", path.basename(first)))
    equal(paths.fromFileUrl(paths.toFileUrl(dir)), dir)

    const r = request(dir)
    const current = (overrides = {}) => {
        const now = { name: r.name, revision: r.revision, id: r.id, pending: null,
                      current: r.current, remembered: r.remembered, ...overrides }
        return wallpaper.isCurrent(r, now.name, now.revision, now.id, now.pending, now.current, now.remembered)
    }
    equal(current(), true)
    for (const change of [{ name: "nord" }, { revision: 4 }, { id: 8 }, { pending: {} },
                          { current: custom }, { remembered: custom }]) equal(current(change), false)

    // Exercise the actual QML queue functions with inert Process and preferences objects.
    const qml = fs.readFileSync(path.join(shellDir, "Theme.qml"), "utf8")
    const queued = []
    const state = vm.createContext({ Wallpaper: wallpaper, Qt: { callLater: f => queued.push(f) },
        shell: { prefsReady: false, prefs: { wallpaper: "", themeWallpapers: {} } },
        pendingTheme: null, transaction: null, pendingWalls: null, walls: { request: null },
        dir, name: "jellybeans", wallsDir: r.folder, wallpaperRevision: 3, themeRevision: 7 })
    for (const name of ["wallpaperBusy", "ensureWallpaper", "startWalls"]) {
        const source = qml.match(new RegExp("    function " + name + "\\(\\) \\{[\\s\\S]*?\\n    \\}"))[0]
        vm.runInContext(source, state)
    }
    vm.runInContext(qml.match(/    function rememberedWallpaper[^\n]+/)[0], state)
    state.ensureWallpaper()
    equal(state.walls.request, null)
    state.shell.prefsReady = true
    state.transaction = {}
    state.ensureWallpaper()
    equal(state.walls.request, null)
    state.transaction = null
    state.pendingTheme = {}
    state.ensureWallpaper()
    equal(state.walls.request, null)
    state.pendingTheme = null
    state.transaction = { name: "jellybeans", live: false }
    state.pendingTheme = { name: "jellybeans", live: false }
    equal(state.wallpaperBusy(), false)
    state.ensureWallpaper()
    equal(state.walls.request.current, "")
    state.walls.request = null
    state.transaction = null
    state.pendingTheme = null
    state.pendingWalls = { keepCurrent: false }
    state.ensureWallpaper()
    equal(state.pendingWalls.keepCurrent, false)
    state.pendingWalls = null
    state.ensureWallpaper()
    equal(state.walls.request.current, "")
    state.shell.prefs.wallpaper = custom
    state.wallpaperRevision++
    state.ensureWallpaper()
    equal(state.pendingWalls.current, custom)
    equal(state.walls.request.current, "")

    // Run the real completion handler: stale or failed scans cannot write preferences.
    state.theme = state
    state.wallsOutput = { text: first + "\0" }
    const wallsQml = qml.slice(qml.indexOf("        id: walls\n"))
    const handler = wallsQml.match(/        onExited: (\(code, status\) => \{[\s\S]*?\n        \})/)[1]
    const complete = vm.runInContext("(" + handler + ")", state)
    state.request = state.walls.request
    complete(0, 0)
    equal(state.shell.prefs.wallpaper, custom)
    equal(state.request, null)
    state.shell.prefs.wallpaper = missing
    state.request = { ...r, revision: state.wallpaperRevision, current: missing }
    complete(1, 0)
    equal(state.shell.prefs.wallpaper, missing)
    state.request = { ...r, revision: state.wallpaperRevision, current: missing }
    complete(0, 0)
    equal(state.shell.prefs.wallpaper, first)
    state.shell.prefs.wallpaper = missing
    state.request = { ...r, revision: state.wallpaperRevision, current: missing }
    state.wallsOutput.text = ""
    complete(0, 0)
    equal(state.shell.prefs.wallpaper, "")

    // Fresh-install assets: exercise the same selection against the shipped themes.
    equal(qml.includes('shell.prefs.theme || "jellybeans"'), true)
    const shippedDir = path.join(shellDir, "themes")
    const shipped = scan(shippedDir, request(shippedDir))
    equal(path.basename(shipped), "cyber-noir-woman-at-the-door.png")
    equal(fs.statSync(shipped).isFile(), true)
    console.log(`${checks} wallpaper selection and stale-scan checks passed`)
} finally {
    fs.rmSync(fixture, { recursive: true, force: true })
}
