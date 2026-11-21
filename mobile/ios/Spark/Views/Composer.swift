import SwiftUI

/**
 * The message box. At rest it's a pill sitting concentric with the screen's corners: as far from the
 * sides and the bottom as makes its round ends run parallel to them. Once you type it widens into a
 * box with room for a few lines. Where and how the chat runs (folder, model, effort) sits above it.
 */
struct Composer<Accessories: View>: View {
  @Binding var text: String
  var focused: FocusState<Bool>.Binding
  let running: Bool
  let enabled: Bool
  let send: () -> Void
  let stop: () -> Void
  @ViewBuilder var accessories: Accessories

  /** the pill's height at rest */
  private static var height: CGFloat { 52 }
  /** a capsule of that height is concentric with the screen when this far from its edges */
  private static var inset: CGFloat { max(12, Screen.cornerRadius - height / 2) }

  private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var live: Bool { enabled && (running || hasText) }
  private var open: Bool { focused.wrappedValue || hasText }

  /** off until the screen has settled, so the bar doesn't animate into place when a screen opens */
  @State private var settled = false

  var body: some View {
    VStack(spacing: 10) {
      if Accessories.self != EmptyView.self {
        // a quiet line of words, lined up with the text below; long names shorten, nothing scrolls.
        // The row keeps its resting width and only slides when the box opens, so the words never
        // re-truncate or stretch mid-animation.
        HStack(spacing: 4) {
          accessories
          Spacer(minLength: 0)
        }
        .padding(.leading, Self.inset + 18 - ComposerOption.slop)
        .padding(.trailing, Self.inset)
        .offset(x: open ? 10 - Self.inset : 0)
      }
      box
        .padding(.horizontal, open ? 10 : Self.inset)
    }
    .padding(.bottom, open ? 8 : Self.inset)
    .ignoresSafeArea(.container, edges: open ? [] : .bottom)
    .animation(settled ? .spring(duration: 0.36, bounce: 0.08) : nil, value: open)
    .animation(.snappy(duration: 0.2), value: live)
    .animation(.snappy(duration: 0.2), value: running)
    .task {
      try? await Task.sleep(for: .milliseconds(700))
      settled = true
    }
  }

  private var box: some View {
    HStack(alignment: .bottom, spacing: 8) {
      // Return makes a new line; the button sends. Open, it keeps room for two lines so the first
      // wrap doesn't make it jump, and grows a line at a time up to eight before it scrolls.
      TextField(running ? "spark is working…" : "Message spark", text: $text, axis: .vertical)
        .font(.geist(17))
        .lineSpacing(3)
        .lineLimit(1...8)
        .focused(focused)
        .disabled(!enabled)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: open ? 64 : 36, alignment: .topLeading)
      Button {
        running ? stop() : send()
      } label: {
        Image(systemName: running ? "stop.fill" : "arrow.up")
          .font(.system(size: running ? 12 : 15, weight: .bold))
          .foregroundStyle(live ? .black : Color.faint)
          .frame(width: 36, height: 36)
          .background(live ? Color.white : Color.white.opacity(0.08), in: .circle)
          .contentShape(.circle)
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(running ? "Stop" : "Send")
      .disabled(!live)
    }
    .padding(.leading, 18)
    .padding([.trailing, .vertical], 8)
    .background {
      Color.clear
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: open ? 24 : Self.height / 2))
        .contentShape(.rect)
        .onTapGesture { if enabled { focused.wrappedValue = true } }
    }
  }
}

extension Composer where Accessories == EmptyView {
  init(text: Binding<String>, focused: FocusState<Bool>.Binding, running: Bool, enabled: Bool, send: @escaping () -> Void, stop: @escaping () -> Void) {
    self.init(text: text, focused: focused, running: running, enabled: enabled, send: send, stop: stop) { EmptyView() }
  }
}

/** One setting above the composer: just its words and a small chevron, dimming while pressed. */
struct ComposerOption: View {
  let text: String
  var mono = false
  var muted = false
  let action: () -> Void

  /** the tap area reaching past the words on each side */
  static let slop: CGFloat = 6

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(text)
          .font(mono ? .geistMono(12.5) : .geist(13.5, .medium))
          .lineLimit(1)
          .truncationMode(mono ? .head : .tail)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(Color.faint)
      }
      .foregroundStyle(muted ? Color.faint : Color.dim)
      .padding(.horizontal, Self.slop)
      .frame(height: 30)
      .contentShape(.rect)
      .contentTransition(.opacity)
    }
    .buttonStyle(Quiet())
  }

  private struct Quiet: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .opacity(configuration.isPressed ? 0.45 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
  }
}

/** The model and effort chips, each opening its own picker. */
struct ConfigChips: View {
  let options: [ConfigOption]
  let set: (String, String) -> Void
  @State private var models = false
  @State private var effort = false

  var body: some View {
    if let model = options.first(where: { $0.id == "model" }) {
      ComposerOption(text: model.current.map { $0.label(model.id) } ?? ConfigOption.Choice.pretty(model.currentValue)) {
        models = true
      }
      .accessibilityLabel("Model")
      .sheet(isPresented: $models) {
        ModelSheet(options: options, set: set)
      }
    }
    if let option = options.first(where: { $0.id == "effort" }), EffortPicker.levels(option).count > 1 {
      ComposerOption(text: EffortPicker.chip(option)) { effort = true }
      .fixedSize()
      .layoutPriority(1)
      .accessibilityLabel("Reasoning effort")
      .popover(isPresented: $effort, arrowEdge: .bottom) {
        EffortPicker(option: option) { value in
          if value != option.currentValue { set(option.id, value) }
          Task {
            try? await Task.sleep(for: .milliseconds(220))
            effort = false
          }
        }
        .presentationCompactAdaptation(.popover)
      }
    }
  }
}

// MARK: Effort

/**
 * Reasoning effort as one row of levels: tap one and it's set, the light slides over, and the
 * popover closes. Sliding a finger along the row moves the light too.
 */
struct EffortPicker: View {
  let option: ConfigOption
  let set: (String) -> Void
  @Namespace private var ns
  @State private var picked: String?
  @State private var width: CGFloat = 0

  private var levels: [ConfigOption.Choice] { Self.levels(option) }
  private var current: String { picked ?? option.currentValue }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Reasoning effort")
        .font(.geist(13, .medium))
        .foregroundStyle(Color.dim)
        .padding(.leading, 4)
      HStack(spacing: 0) {
        ForEach(levels, id: \.value) { level in
          let on = level.value == current
          Text(Self.name(level))
            .font(.geist(14, on ? .semibold : .medium))
            .foregroundStyle(on ? .black : Color(white: 0.75))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
              if on { Capsule().fill(.white).matchedGeometryEffect(id: "lit", in: ns) }
            }
            .contentShape(.capsule)
        }
      }
      .padding(3)
      .background(Color.white.opacity(0.08), in: .capsule)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { g in
            let value = levels[index(g.location.x)].value
            if value != current { picked = value }
          }
          .onEnded { g in
            let value = levels[index(g.location.x)].value
            picked = value
            // even the same level closes the popover
            set(value)
          }
      )
    }
    .padding(14)
    .frame(width: max(240, CGFloat(levels.count) * 72 + 28))
    .animation(.spring(duration: 0.24, bounce: 0.12), value: current)
    .sensoryFeedback(.selection, trigger: current)
    .accessibilityElement()
    .accessibilityLabel("Reasoning effort")
    .accessibilityValue(levels.first { $0.value == current }.map(Self.name) ?? "")
    .accessibilityAdjustableAction { direction in
      let i = levels.firstIndex { $0.value == current } ?? 0
      let next = direction == .increment ? min(i + 1, levels.count - 1) : max(i - 1, 0)
      picked = levels[next].value
      set(levels[next].value)
    }
  }

  private func index(_ x: CGFloat) -> Int {
    guard width > 0, !levels.isEmpty else { return 0 }
    return min(max(Int(x / width * CGFloat(levels.count)), 0), levels.count - 1)
  }

  /** the levels the model offers; "auto" is spark's own default, not a level to pick */
  static func levels(_ option: ConfigOption) -> [ConfigOption.Choice] {
    option.options.filter { $0.value != "auto" }
  }

  static func chip(_ option: ConfigOption) -> String {
    option.current.flatMap { $0.value == "auto" ? nil : name($0) + " effort" } ?? "Effort"
  }

  static func name(_ level: ConfigOption.Choice) -> String {
    switch level.name.lowercased() {
    case "xhigh", "x-high": return "X-High"
    case "minimal": return "Min"
    case "medium": return "Med"
    default: return level.name.prefix(1).uppercased() + level.name.dropFirst()
    }
  }
}

// MARK: Models

/** The models spark can use: tap one and you're done. Provider and mode sit up top as two menus. */
struct ModelSheet: View {
  let options: [ConfigOption]
  let set: (String, String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private var model: ConfigOption? { options.first { $0.id == "model" } }
  private var menus: [ConfigOption] {
    options.filter { ["provider", "mode"].contains($0.id) && $0.options.count > 1 }
  }

  private var shown: [ConfigOption.Choice] {
    guard let model else { return [] }
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return model.options.filter { q.isEmpty || $0.value.lowercased().contains(q) || $0.label("model").lowercased().contains(q) }
  }

  /** a short list gets a sheet just its size */
  private var fits: Bool { (model?.options.count ?? 0) <= 8 }
  private var fitHeight: CGFloat {
    64 + (menus.isEmpty ? 0 : 44) + CGFloat(model?.options.count ?? 0) * 52 + 40
  }

  private var makers: Set<String> { Set(shown.map { ConfigOption.Choice.maker($0.value) }) }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Model").font(.geist(17, .semibold))
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.dim)
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.08), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
      }
      .padding(.horizontal, 20)
      .padding(.top, 20)
      .padding(.bottom, 14)

      if !menus.isEmpty {
        HStack(spacing: 8) {
          ForEach(menus) { o in OptionMenu(option: o) { set(o.id, $0) } }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
      }

      if (model?.options.count ?? 0) > 8 {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dim)
          TextField("Search models", text: $query)
            .font(.geist(15))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color.white.opacity(0.07), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
      }

      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(shown, id: \.value) { c in
            let on = c.value == model?.currentValue
            Button {
              set("model", c.value)
              dismiss()
            } label: {
              HStack(spacing: 10) {
                Text(c.label("model"))
                  .font(.geist(16, on ? .medium : .regular))
                  .foregroundStyle(.white)
                if makers.count > 1 {
                  Text(ConfigOption.Choice.maker(c.value)).font(.geist(13)).foregroundStyle(Color.faint)
                }
                Spacer(minLength: 0)
                if on {
                  Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                }
              }
              .padding(.horizontal, 16)
              .frame(height: 50)
              .background(on ? Color.white.opacity(0.08) : .clear, in: .rect(cornerRadius: 16, style: .continuous))
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
      }
      .scrollDismissesKeyboard(.immediately)
      .overlay {
        if shown.isEmpty, !query.isEmpty {
          Text("No models match “\(query)”").font(.geist(15)).foregroundStyle(Color.faint)
        }
      }
    }
    .presentationDetents(fits ? [.height(fitHeight)] : [.medium, .large])
    .presentationDragIndicator(.hidden)
    .presentationBackground(Color(white: 0.06))
    .presentationCornerRadius(Screen.cornerRadius)
    .sensoryFeedback(.selection, trigger: options.map(\.currentValue))
  }
}

/** One option as a compact pill that opens its choices. */
private struct OptionMenu: View {
  let option: ConfigOption
  let set: (String) -> Void

  var body: some View {
    Menu {
      Picker(option.name, selection: Binding(get: { option.currentValue }, set: set)) {
        ForEach(option.options, id: \.value) { Text($0.name.prefix(1).uppercased() + $0.name.dropFirst()).tag($0.value) }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: option.id == "mode" ? "checkmark.shield" : "server.rack")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.dim)
        Text(current)
          .font(.geist(13, .medium))
          .lineLimit(1)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.faint)
      }
      .foregroundStyle(Color(white: 0.9))
      .padding(.horizontal, 12)
      .frame(height: 32)
      .background(Color.white.opacity(0.08), in: .capsule)
    }
    .menuOrder(.fixed)
    .accessibilityLabel("\(option.name): \(current)")
  }

  private var current: String {
    let n = option.current?.name ?? option.currentValue
    return n.prefix(1).uppercased() + n.dropFirst()
  }
}

extension ConfigOption.Choice {
  /** the name to show: the catalog's, or one made from the id when spark only knows the id */
  func label(_ option: String) -> String {
    guard option == "model", name == value || name.contains("/") else { return name }
    return Self.pretty(value)
  }

  /** anthropic/claude-opus-4.6 → Claude Opus 4.6 */
  static func pretty(_ id: String) -> String {
    let last = id.split(separator: "/").last.map(String.init) ?? id
    guard last.contains("-") || last == last.lowercased() else { return last }
    let words = last.split(separator: "-").map(String.init)
    var out: [String] = []
    for w in words {
      let lower = w.lowercased()
      let brands = ["deepseek": "DeepSeek", "minimax": "MiniMax", "openai": "OpenAI", "xai": "xAI"]
      if let brand = brands[lower] {
        out.append(brand)
      } else if ["gpt", "glm", "llm"].contains(lower) {
        out.append(lower.uppercased())
      } else if let prev = out.last, ["GPT", "GLM"].contains(prev), w.first?.isNumber == true {
        out[out.count - 1] = prev + "-" + w
      } else if w.first?.isNumber == true || w.count <= 2 && w.contains(where: \.isNumber) {
        out.append(w)
      } else {
        out.append(w.prefix(1).uppercased() + w.dropFirst())
      }
    }
    return out.joined(separator: " ")
  }

  /** who makes it, from the id's prefix */
  static func maker(_ id: String) -> String {
    guard let prefix = id.split(separator: "/").first, id.contains("/") else { return "" }
    switch prefix.lowercased() {
    case "openai": return "OpenAI"
    case "xai": return "xAI"
    case "deepseek": return "DeepSeek"
    case "moonshotai": return "Moonshot"
    case "zai": return "Z.ai"
    case "mistral", "mistralai": return "Mistral"
    default: return prefix.prefix(1).uppercased() + prefix.dropFirst()
    }
  }
}

/** The one solid button on a screen: white pill, sized to its words. `secondary` is the quiet one beside it. */
struct PillButton: ButtonStyle {
  var secondary = false
  var wide = false
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.geist(16, .semibold))
      .lineLimit(1)
      .foregroundStyle(secondary ? .white : .black)
      .padding(.horizontal, 22)
      .frame(maxWidth: wide ? .infinity : nil)
      .frame(height: 44)
      .background(secondary ? Color.white.opacity(0.1) : .white, in: .capsule)
      .contentShape(.capsule)
      .opacity(enabled ? 1 : 0.4)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
  }
}
