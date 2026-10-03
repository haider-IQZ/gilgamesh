// Local music: plays the music folder with our own mpv (no window, no user config), controlled
// over mpv's JSON IPC socket. mpv is its own process, so music keeps playing when the bar
// restarts; on startup we reconnect to it if it's still running.
// Also downloads audio from a link with yt-dlp into the same folder.
// Exposes the same names as an MprisPlayer (trackTitle, isPlaying, next()...) so the bar and
// the media card can treat it like any other player.
import Quickshell
import Quickshell.Io
import QtQuick

Scope {
    id: music
    required property var shell
    readonly property string folder: shell.musicFolder
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string sock: runtimeDir + "/gilgamesh-music.sock"
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || shell.home + "/.cache") + "/gilgamesh"
    readonly property var audioExt: ["mp3", "flac", "opus", "ogg", "oga", "m4a", "aac", "wav", "webm", "mka", "wma", "aiff", "ape", "wv"]
    readonly property var nameFilters: audioExt.map(e => "*." + e).concat(audioExt.map(e => "*." + e.toUpperCase()))

    property var tracks: []          // audio files under the folder, sorted
    property bool idle: true         // mpv has nothing loaded
    property string path: ""         // file playing now (kept while mpv switches tracks)
    property bool paused: false
    property real position: 0
    property real length: 0
    property var meta: ({})
    property string trackArtUrl: ""  // cover pulled out of the file by ffmpeg, "" = none
    property bool shuffle: false
    property real volume: 1          // 0..1 (mpv's own volume, separate from the system's)
    property bool muted: false

    // MprisPlayer-like surface
    readonly property bool connected: ipcLoader.item?.connected ?? false
    readonly property bool active: connected && !idle
    readonly property bool isPlaying: active && !paused
    readonly property string identity: "Music"
    readonly property string trackTitle: metaGet("title") || name(path)
    readonly property string trackArtist: metaGet("artist") || metaGet("album_artist")
    readonly property bool canSeek: active
    readonly property bool canGoNext: active
    readonly property bool canGoPrevious: active
    readonly property bool canTogglePlaying: true

    function metaGet(key) {
        for (const k in meta) if (k.toLowerCase() === key) return String(meta[k])
        return ""
    }
    function name(p) {
        const f = p.slice(p.lastIndexOf("/") + 1)
        const dot = f.lastIndexOf(".")
        return dot > 0 ? f.slice(0, dot) : f
    }
    // path relative to the music folder, without the extension ("Album/01 Song")
    function label(p) {
        const rel = p.startsWith(folder + "/") ? p.slice(folder.length + 1) : p
        const dot = rel.lastIndexOf(".")
        return dot > rel.lastIndexOf("/") + 1 ? rel.slice(0, dot) : rel
    }

    // ---------- controls ----------
    // Plays tracks[i]. The mpv playlist is the folder rotated to start at i, looping, so
    // next/previous follow folder order and wrap around.
    function play(i) {
        if (i < 0 || i >= tracks.length) return
        const order = tracks.slice(i).concat(tracks.slice(0, i))
        const cmds = [["set", "loop-playlist", "inf"], ["loadfile", order[0], "replace"]]
        for (let k = 1; k < order.length; k++) cmds.push(["loadfile", order[k], "append"])
        if (shuffle) cmds.push(["playlist-shuffle"])
        cmds.push(["set", "pause", "no"])
        run(cmds)
    }
    function togglePlaying() {
        if (active) send(["cycle", "pause"])
        else if (tracks.length > 0) play(0)
    }
    function next() { send(["playlist-next", "force"]) }
    function previous() {
        // like every player: back to the start first, the previous track only near the start
        if (position > 3) send(["seek", 0, "absolute"])
        else send(["playlist-prev", "force"])
    }
    function seekTo(seconds) { send(["seek", seconds, "absolute"]); position = seconds }
    function stop() { send(["stop"]) }
    // set_property, not set: mpv's "set" only takes text and rejects a number
    function setVolume(v) { volume = v; send(["set_property", "volume", Math.round(v * 100)]) }
    function toggleMute() { send(["cycle", "mute"]) }
    // remembered in settings.json (once you stop dragging), so a fresh mpv starts at it
    Timer { id: saveVolume; interval: 800; onTriggered: if (Math.abs(music.shell.prefs.musicVolume - music.volume) > 0.001) music.shell.prefs.musicVolume = music.volume }
    function setShuffle(on) {
        shuffle = on
        if (active) send([on ? "playlist-shuffle" : "playlist-unshuffle"])
    }

    // ---------- the mpv process + socket ----------
    property var queued: []          // commands waiting for mpv to start
    function send(cmd) { run([cmd]) }
    function run(cmds) {
        if (connected) { write(cmds); return }
        queued = queued.concat(cmds)
        if (!starting.running) {
            Quickshell.execDetached(["mpv", "--no-config", "--idle=yes", "--no-video", "--no-terminal",
                                     "--volume=" + Math.round(shell.prefs.musicVolume * 100),
                                     "--input-ipc-server=" + sock])
            starting.tries = 0
            starting.start()
        }
    }
    function write(cmds, socket) {
        const s = socket || ipcLoader.item
        if (!s) return
        for (const c of cmds) s.write(JSON.stringify({ command: c }) + "\n")
        s.flush()
    }

    // A Socket that failed to connect never retries, so every attempt gets a fresh one.
    function reconnect() { ipcLoader.active = false; ipcLoader.active = true }
    Timer {
        id: starting
        property int tries: 0
        interval: 150
        repeat: true
        onTriggered: {
            if (music.connected || ++tries > 40) { stop(); return }
            music.reconnect()
        }
    }
    // an mpv left running from before a bar restart: reconnect if its socket is there
    Process {
        running: true
        command: ["test", "-S", music.sock]
        onExited: code => { if (code === 0) music.reconnect() }
    }

    LazyLoader {
        id: ipcLoader
        Socket {
            id: ipcSocket
            path: music.sock
            connected: true
            onConnectedChanged: {
                if (connected) {
                    const props = ["idle-active", "pause", "duration", "metadata", "path", "volume", "mute"]
                    // (written through ipcSocket: the loader may not have handed us out yet)
                    music.write(props.map((p, i) => ["observe_property", i + 1, p]), ipcSocket)
                    if (music.queued.length > 0) { music.write(music.queued, ipcSocket); music.queued = [] }
                } else {
                    music.idle = true   // mpv quit
                }
            }
            parser: SplitParser { onRead: line => music.handle(line) }
        }
    }

    function handle(line) {
        let m
        try { m = JSON.parse(line) } catch (e) { return }
        if (m.event === "property-change") {
            switch (m.name) {
            case "idle-active": idle = m.data !== false; break
            case "pause": paused = m.data === true; break
            case "duration": length = m.data || 0; break
            case "volume": volume = (m.data ?? 100) / 100; saveVolume.restart(); break
            case "mute": muted = m.data === true; break
            case "metadata": meta = m.data || {}; break
            case "path":
                if (m.data && m.data !== path) { path = m.data; position = 0; extractArt() }
                break
            }
        } else if (m.request_id === 7) {
            position = m.data || 0
        }
    }

    // position: asked for once a second while playing (cheaper than observing time-pos),
    // and once on pause/resume so a paused track shows where it stopped
    function askPosition() {
        if (!connected) return
        ipcLoader.item.write(JSON.stringify({ command: ["get_property", "time-pos"], request_id: 7 }) + "\n")
        ipcLoader.item.flush()
    }
    onPausedChanged: askPosition()
    Timer {
        interval: 1000
        repeat: true
        running: music.isPlaying
        triggeredOnStart: true
        onTriggered: music.askPosition()
    }

    // ---------- cover art ----------
    // ffmpeg copies the picture embedded in the file (yt-dlp embeds the thumbnail).
    // A new file name every time, so the Image doesn't show a cached old cover.
    property int artSerial: 0
    function extractArt() {
        trackArtUrl = ""
        artSerial++
        artProc.out = cacheDir + "/cover-" + artSerial
        artProc.running = false
        artProc.running = true
    }
    Process {
        id: artProc
        property string out: ""
        command: ["sh", "-c", "mkdir -p \"$1\" && rm -f \"$1\"/cover-* && ffmpeg -v error -y -i \"$2\" -map 0:v:0 -frames:v 1 -c copy -f image2 \"$3\" && echo ok",
                  "sh", music.cacheDir, music.path, out]
        stdout: StdioCollector {
            onStreamFinished: if (this.text.trim() === "ok" && artProc.out.endsWith("-" + music.artSerial)) music.trackArtUrl = "file://" + artProc.out
        }
    }

    // ---------- the track list ----------
    function refresh() { lister.running = false; lister.running = true }
    onFolderChanged: refresh()
    Process {
        id: lister
        command: ["find", music.folder, "-type", "f", "-not", "-path", "*/.*"]
        stdout: StdioCollector {
            onStreamFinished: {
                const ext = f => f.slice(f.lastIndexOf(".") + 1).toLowerCase()
                music.tracks = this.text.split("\n")
                    .filter(f => f !== "" && music.audioExt.includes(ext(f)))
                    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" }))
            }
        }
    }

    // ---------- yt-dlp downloads ----------
    // Audio only, best quality without re-encoding, named after the title, with the title,
    // artist and thumbnail embedded in the file.
    property bool downloading: false
    property real dlPercent: 0
    property string dlTitle: ""
    property string dlStatus: ""     // last result: "Saved …" or the error
    property bool dlFailed: false
    property int dlDone: 0

    function download(url) {
        url = url.trim()
        if (!url || downloading) return
        downloading = true
        dlPercent = 0; dlTitle = ""; dlStatus = ""; dlFailed = false; dlDone = 0; dlCancelled = false
        dl.command = ["yt-dlp", "--no-playlist", "--extract-audio",
                      "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg",
                      "--paths", folder, "--output", "%(title)s.%(ext)s",
                      "--newline", "--progress", "--progress-template", "download:GIL|%(info.title)s|%(progress._percent_str)s",
                      "--print", "after_move:DONE|%(filepath)s", url]
        dl.running = true
    }
    property bool dlCancelled: false
    function cancelDownload() { dlCancelled = true; dl.signal(15) }

    Process {
        id: dl
        property string lastError: ""
        stdout: SplitParser {
            onRead: line => {
                const p = line.split("|")
                if (p[0] === "GIL") {
                    music.dlTitle = p[1]
                    music.dlPercent = parseFloat(p[2]) || 0
                } else if (p[0] === "DONE") {
                    music.dlDone++
                    music.dlTitle = music.name(p[1])
                    // already playing: put it in the queue too
                    if (music.active) music.send(["loadfile", p[1], "append"])
                }
            }
        }
        stderr: SplitParser {
            onRead: line => { if (line.startsWith("ERROR:")) dl.lastError = line.slice(6).trim() }
        }
        onStarted: lastError = ""
        onExited: (code, status) => {
            music.downloading = false
            if (code === 0 && music.dlDone > 0) {
                music.dlStatus = "Saved " + (music.dlDone > 1 ? music.dlDone + " tracks" : music.dlTitle)
            } else {
                music.dlFailed = true
                music.dlStatus = music.dlCancelled ? "Cancelled" : (lastError || "Download failed")
            }
            music.refresh()
        }
    }
}
