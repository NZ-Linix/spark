import SwiftUI

/**
 * A file's icon, after the editor icon themes: a language shows as its short name on a tint of its
 * colour, and everything else as a symbol in a colour of its kind.
 */
struct FileIcon: View {
  let name: String
  let dir: Bool
  var size: CGFloat = 22

  var body: some View {
    let style = FileStyle.of(name, dir: dir)
    Group {
      switch style.glyph {
      case .symbol(let symbol):
        Image(systemName: symbol)
          .font(.system(size: size * 0.74, weight: .medium))
          .foregroundStyle(style.color)
      case .badge(let label):
        Text(label)
          .font(.system(size: size * (label.count > 2 ? 0.33 : 0.42), weight: .heavy, design: .rounded))
          .kerning(-0.2)
          .foregroundStyle(style.color)
          .frame(width: size, height: size * 0.86)
          .background(style.color.opacity(0.16), in: .rect(cornerRadius: size * 0.24, style: .continuous))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct FileStyle {
  enum Glyph {
    case symbol(String)
    case badge(String)
  }

  let glyph: Glyph
  let color: Color

  private init(_ glyph: Glyph, _ hex: UInt32) {
    self.glyph = glyph
    color = Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }

  private static func badge(_ label: String, _ hex: UInt32) -> FileStyle { FileStyle(.badge(label), hex) }
  private static func symbol(_ name: String, _ hex: UInt32) -> FileStyle { FileStyle(.symbol(name), hex) }

  private static let folder = symbol("folder.fill", 0x8FA3B8)
  private static let plain = symbol("doc.text", 0x8C8C8C)
  private static let lock = symbol("lock.fill", 0x7A7A7A)
  private static let config = symbol("gearshape.fill", 0x8C8C8C)
  private static let git = symbol("arrow.triangle.branch", 0xF1502F)
  private static let docker = symbol("shippingbox.fill", 0x2496ED)
  private static let env = symbol("key.fill", 0xE6C84F)
  private static let image = symbol("photo.fill", 0xA77BCA)
  private static let shell = symbol("terminal.fill", 0x89E051)

  static func of(_ name: String, dir: Bool) -> FileStyle {
    if dir { return folder }
    let lower = name.lowercased()
    if let s = names[lower] { return s }
    if lower.hasPrefix(".env") { return env }
    if lower.hasPrefix("readme") { return symbol("book.closed.fill", 0x42A5F5) }
    if lower.hasPrefix("license") || lower.hasPrefix("licence") || lower.hasPrefix("copying") { return symbol("checkmark.seal.fill", 0xD4B13F) }
    if lower.hasPrefix("tsconfig") { return badge("TS", 0x3178C6) }
    if lower.hasPrefix("dockerfile") || lower.hasPrefix("docker-compose") { return docker }
    if lower.hasSuffix(".lock") || lower.hasSuffix("-lock.json") || lower.hasSuffix("-lock.yaml") { return lock }
    if lower.hasPrefix("."), lower.hasSuffix("rc") || lower.hasSuffix("ignore") { return config }
    guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return plain }
    return extensions[String(lower[lower.index(after: dot)...])] ?? plain
  }

  private static let names: [String: FileStyle] = [
    "package.json": badge("npm", 0xCB3837),
    "go.mod": badge("GO", 0x00ADD8), "go.sum": lock,
    "cargo.toml": badge("RS", 0xDEA584),
    "build.zig": badge("ZIG", 0xF7A41D), "build.zig.zon": badge("ZIG", 0xF7A41D),
    "gemfile": badge("RB", 0xCC342D), "podfile": badge("RB", 0xCC342D),
    "makefile": symbol("hammer.fill", 0xE37933), "justfile": symbol("hammer.fill", 0xE37933),
    ".gitignore": git, ".gitattributes": git, ".gitmodules": git, ".gitkeep": git,
    ".dockerignore": docker, "compose.yml": docker, "compose.yaml": docker,
    "bun.lockb": lock, "bun.lock": lock,
    "agents.md": symbol("sparkles", 0xB08CFA), "claude.md": symbol("sparkles", 0xB08CFA),
    ".editorconfig": config, ".ds_store": config,
  ]

  private static let extensions: [String: FileStyle] = {
    var m: [String: FileStyle] = [:]
    func add(_ keys: [String], _ s: FileStyle) { for k in keys { m[k] = s } }
    add(["ts", "mts", "cts"], badge("TS", 0x3178C6))
    add(["tsx"], badge("TSX", 0x3178C6))
    add(["js", "mjs", "cjs"], badge("JS", 0xE8D44D))
    add(["jsx"], badge("JSX", 0xE8D44D))
    add(["json", "jsonc", "json5"], badge("{ }", 0xCBCB41))
    add(["md", "mdx", "markdown"], badge("M\u{2193}", 0x519ABA))
    add(["swift"], symbol("swift", 0xF05138))
    add(["py", "pyi"], badge("PY", 0x4B8BBE))
    add(["ipynb"], badge("NB", 0xF37726))
    add(["rs"], badge("RS", 0xDEA584))
    add(["go"], badge("GO", 0x00ADD8))
    add(["zig", "zon"], badge("ZIG", 0xF7A41D))
    add(["c", "h"], badge("C", 0x6E8CBF))
    add(["cc", "cpp", "cxx", "hpp", "hh", "hxx"], badge("C++", 0xF34B7D))
    add(["m", "mm"], badge("OBJ", 0x438EFF))
    add(["cs"], badge("C#", 0x68217A))
    add(["java"], badge("JV", 0xE76F00))
    add(["kt", "kts"], badge("KT", 0xA97BFF))
    add(["rb"], badge("RB", 0xCC342D))
    add(["php"], badge("PHP", 0x777BB4))
    add(["lua"], badge("LUA", 0x5A7BD6))
    add(["ex", "exs"], badge("EX", 0x9B6FBF))
    add(["hs"], badge("HS", 0x8F7FC0))
    add(["dart"], badge("DT", 0x29B6F6))
    add(["html", "htm"], badge("<>", 0xE44D26))
    add(["xml", "plist", "xib", "storyboard"], badge("<>", 0xE37933))
    add(["css"], badge("#", 0x42A5F5))
    add(["scss", "sass", "less"], badge("#", 0xCF649A))
    add(["vue"], badge("V", 0x41B883))
    add(["svelte"], badge("S", 0xFF3E00))
    add(["astro"], badge("A", 0xFF5D01))
    add(["sh", "bash", "zsh", "fish", "command"], shell)
    add(["yml", "yaml"], badge("YML", 0xCB4A4A))
    add(["toml"], badge("TML", 0x9C7A5B))
    add(["ini", "cfg", "conf", "properties", "xcconfig", "editorconfig"], config)
    add(["env"], env)
    add(["sql", "db", "sqlite", "sqlite3"], symbol("cylinder.split.1x2.fill", 0xE38C00))
    add(["graphql", "gql"], badge("GQL", 0xE535AB))
    add(["proto"], badge("PB", 0x6D8086))
    add(["tla"], badge("TLA", 0x8A9BA8))
    add(["svg"], badge("SVG", 0xFFB13B))
    add(["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "ico", "icns"], image)
    add(["mp4", "mov", "m4v", "webm", "avi", "mkv"], symbol("film.fill", 0xFF7A59))
    add(["mp3", "wav", "aac", "m4a", "flac", "ogg", "aiff"], symbol("waveform", 0xEF5B8A))
    add(["pdf"], symbol("doc.richtext.fill", 0xE5484D))
    add(["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg"], symbol("doc.zipper", 0xA0896B))
    add(["csv", "tsv", "xlsx", "xls", "numbers"], symbol("tablecells.fill", 0x4CAF50))
    add(["txt", "text", "rtf"], plain)
    add(["log", "out"], symbol("list.bullet.rectangle", 0x8C8C8C))
    add(["lock", "lockb"], lock)
    add(["pem", "key", "crt", "cer", "p12", "pub"], symbol("key.horizontal.fill", 0xE6C84F))
    add(["ttf", "otf", "woff", "woff2"], symbol("textformat", 0xE57373))
    add(["wasm"], badge("WA", 0x654FF0))
    add(["diff", "patch"], symbol("plus.forwardslash.minus", 0x8BC34A))
    add(["fxtape"], symbol("record.circle", 0xE5484D))
    return m
  }()
}
