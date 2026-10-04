// Filesystem paths are data; encode each component before giving one to QML's URL properties.
function toFileUrl(path) {
    if (!path || !path.startsWith("/")) return ""
    return "file://" + path.split("/").map(encodeURIComponent).join("/")
}

function fromFileUrl(url) {
    const match = String(url).match(/^file:\/\/(?:localhost)?(\/[^?#]*)$/)
    if (!match) return ""
    try { return decodeURIComponent(match[1]) } catch (e) { return "" }
}
