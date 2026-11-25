import SwiftUI

/**
 * The message box. At rest it's a pill sitting concentric with the screen's corners: as far from the
 * sides and the bottom as makes its round ends run parallel to them. Once you type it widens into a
 * box with room for a few lines. Where and how the chat runs (folder, model, effort) sits above it.
 */
struct Composer<Accessories: View, Trailing: View>: View {
  @Binding var text: String
  var focused: FocusState<Bool>.Binding
  let running: Bool
  let enabled: Bool
  let send: () -> Void
  let stop: () -> Void
  var placeholder = "Message spark"
  var working = "spark is working…"
  /** a terminal's field: mono, and Return sends instead of making a new line */
  var command = false
  var canSendWhileRunning = false
  var actionEnabled = true
  @ViewBuilder var accessories: Accessories
  /** inside the box, beside the send button: how the chat runs, always on the glass so it reads */
  @ViewBuilder var trailing: Trailing

  /** the pill's height at rest */
  private static var height: CGFloat { 52 }
  /** a capsule of that height is concentric with the screen when this far from its edges */
  private static var inset: CGFloat { max(12, Screen.cornerRadius - height / 2) }

  private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var live: Bool { enabled && actionEnabled && (running || hasText) }
  private var isStop: Bool { running && !(hasText && canSendWhileRunning) }
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

  /** open with something to show beside the send button: a row of its own under the text */
  private var toolbar: Bool { open && Trailing.self != EmptyView.self }

  private var box: some View {
    // Return makes a new line; the button sends. Open, the box is two lines high, and the field grows
    // a line at a time up to eight.
    TextField(running ? working : placeholder, text: $text, axis: .vertical)
      .font(command ? .geistMono(16) : .geist(17))
      .textInputAutocapitalization(command ? .never : nil)
      .autocorrectionDisabled(command)
      .onChange(of: text) { _, new in
        // a vertical field takes Return as a new line; a command runs on it instead
        guard command, new.hasSuffix("\n") else { return }
        text = String(new.dropLast())
        if !running, hasText { send() }
      }
      .lineSpacing(3)
      // open with a toolbar, the text's one line and the toolbar's make the two
      .lineLimit(open && !toolbar ? 2...8 : 1...8)
      .focused(focused)
      .disabled(!enabled)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
      // beside the send button on one line; open with a toolbar, the text gets the whole width
      // and the row sits under it
      .padding(.trailing, toolbar ? 0 : 44)
      .padding(.bottom, toolbar ? 40 : 0)
      // the send button never moves: it stays in the corner while the box grows up from it
      .overlay(alignment: .bottomTrailing) {
        HStack(spacing: 8) {
          // The chip is laid out where the open box will end up, while the box still rides up
          // with the keyboard: shown at once, it would float above the box and drop into it. It
          // waits for the box to land, then fades in; closing hides it at once.
          trailing
            .frame(height: 36)
            .fixedSize(horizontal: true, vertical: false)
            .animation(toolbar ? .easeOut(duration: 0.18).delay(0.3) : nil) {
              $0.opacity(toolbar ? 1 : 0)
            }
            .allowsHitTesting(toolbar)
            .accessibilityHidden(!toolbar)
          sendButton
        }
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

  private var sendButton: some View {
    Button {
      isStop ? stop() : send()
    } label: {
      Image(systemName: isStop ? "stop.fill" : "arrow.up")
        .font(.system(size: isStop ? 12 : 15, weight: .bold))
        .foregroundStyle(live ? .black : Color.faint)
        .frame(width: 36, height: 36)
        .background(live ? Color.white : Color.white.opacity(0.08), in: .circle)
        .contentShape(.circle)
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.plain)
    // Return makes a new line; with a hardware keyboard, Command-Return sends (it never stops)
    .keyboardShortcut(isStop ? nil : KeyboardShortcut(.return, modifiers: .command))
    .accessibilityLabel(isStop ? "Stop" : "Send")
    .disabled(!live)
  }
}

extension Composer where Accessories == EmptyView, Trailing == EmptyView {
  init(
    text: Binding<String>, focused: FocusState<Bool>.Binding, running: Bool, enabled: Bool,
    placeholder: String = "Message spark", working: String = "spark is working…", command: Bool = false,
    send: @escaping () -> Void, stop: @escaping () -> Void
  ) {
    self.init(text: text, focused: focused, running: running, enabled: enabled, send: send, stop: stop, placeholder: placeholder, working: working, command: command, accessories: { EmptyView() }, trailing: { EmptyView() })
  }
}

extension Composer where Accessories == EmptyView {
  init(
    text: Binding<String>, focused: FocusState<Bool>.Binding, running: Bool, enabled: Bool,
    placeholder: String = "Message spark", working: String = "spark is working…", canSendWhileRunning: Bool = false,
    actionEnabled: Bool = true, send: @escaping () -> Void, stop: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing
  ) {
    self.init(text: text, focused: focused, running: running, enabled: enabled, send: send, stop: stop, placeholder: placeholder, working: working, command: false, canSendWhileRunning: canSendWhileRunning, actionEnabled: actionEnabled, accessories: { EmptyView() }, trailing: trailing)
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
    .buttonStyle(QuietPress())
  }
}

/**
 * How the chat runs, as one chip: the model, then the effort, with a quote mark when a library
 * prompt is chosen. It opens one sheet with the effort slider, the prompt, and the models, so the
 * row above the composer never has to fit four names.
 */
struct ConfigChips: View {
  let options: [ConfigOption]
  let set: (String, String) -> Void
  /** a new chat's library prompts and the one chosen; a running chat keeps its prompt */
  var prompts: [PromptSummary] = []
  var prompt: Binding<String>? = nil
  var mcpNames: [String] = []
  var mcpDisabled: Binding<Set<String>>? = nil
  var mcpEditable = true
  var refreshMcp: (() async -> Void)? = nil
  /** inside the composer: a small filled pill with a short name, so it reads over anything */
  var compact = false
  var modelsPending = false
  @State private var open = false

  private var model: ConfigOption? { options.first { $0.id == "model" } }
  private var effort: ConfigOption? {
    options.first { $0.id == "effort" && Effort.levels($0).count > 1 }
  }
  private var modelName: String {
    if modelsPending { return "Model" }
    guard let model else { return "" }
    let name = model.current.map { $0.label(model.id) } ?? ConfigOption.Choice.pretty(model.currentValue)
    guard compact else { return name }
    // the maker's family name says little next to the send button: "Claude Opus 4.6" reads "Opus 4.6"
    let words = name.split(separator: " ")
    if words.count > 2, words[0].lowercased() == "claude" {
      return words.dropFirst().joined(separator: " ")
    }
    return name
  }
  private var promptChosen: Bool {
    guard let name = prompt?.wrappedValue, !name.isEmpty else { return false }
    return prompts.contains { $0.name == name }
  }

  var body: some View {
    if let model {
      Button {
        // a menu in the sheet gives focus back to the last field when it closes; with the composer
        // still holding it, that would raise the keyboard over the sheet
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        open = true
      } label: {
        HStack(spacing: 5) {
          if promptChosen {
            Image(systemName: "text.quote")
              .font(.system(size: 10.5, weight: .semibold))
              .foregroundStyle(Color.dim)
          }
          Text(modelName)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: compact ? 200 : nil, alignment: .leading)
            .fixedSize(horizontal: !compact, vertical: false)
          if !modelsPending, let effort, let level = Effort.current(effort) {
            Text(Effort.name(level))
              .foregroundStyle(Effort.accent)
              .lineLimit(1)
              .fixedSize()
          }
          if !compact {
            Image(systemName: "chevron.down")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(Color.faint)
          }
        }
        .font(.geist(compact ? 12.5 : 13.5, .medium))
        .foregroundStyle(compact ? Color(white: 0.82) : Color.dim)
        .padding(.horizontal, compact ? 10 : ComposerOption.slop)
        .frame(height: compact ? 30 : 30)
        .background { if compact { Capsule().fill(Color.white.opacity(0.09)) } }
        .contentShape(.capsule)
        .contentTransition(.opacity)
      }
      .buttonStyle(QuietPress())
      .accessibilityLabel("Model")
      .accessibilityValue([model.current?.label(model.id), effort.flatMap(Effort.current).map(Effort.name)].compactMap { $0 }.joined(separator: ", "))
      .sheet(isPresented: $open) {
        ModelSheet(options: options, set: set, prompts: prompts, prompt: prompt, mcpNames: mcpNames, mcpDisabled: mcpDisabled, mcpEditable: mcpEditable, modelsPending: modelsPending)
          .task { await refreshMcp?() }
      }
    }
  }
}

/** Dims the label while pressed, the quiet press every chip above the composer shares. */
struct QuietPress: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.45 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

// MARK: Effort

/** The levels a model offers and how they read. */
enum Effort {
  static let accent = Color(red: 0.69, green: 0.55, blue: 0.98)

  /** the levels the model offers; "auto" is spark's own default, not a level to pick */
  static func levels(_ option: ConfigOption) -> [ConfigOption.Choice] {
    option.options.filter { $0.value != "auto" }
  }

  /**
   * The level a new chat starts on: the one last picked, on whichever host, when this model has it;
   * else the host's own; else High, or the top level, while the host leaves it to spark.
   */
  static func fallback(_ option: ConfigOption, last: String) -> String? {
    let levels = levels(option)
    return (levels.first { $0.value == last } ?? current(option) ?? levels.first { $0.value == "high" } ?? levels.last)?.value
  }

  /** the chosen level, or nil while spark picks */
  static func current(_ option: ConfigOption) -> ConfigOption.Choice? {
    levels(option).first { $0.value == option.currentValue }
  }

  static func name(_ level: ConfigOption.Choice) -> String {
    switch level.name.lowercased() {
    case "xhigh", "x-high": return "X-High"
    default: return level.name.prefix(1).uppercased() + level.name.dropFirst()
    }
  }
}

/** Reasoning effort on the stop slider, one stop per level the model offers. */
struct EffortSlider: View {
  let option: ConfigOption
  let set: (String) -> Void

  var body: some View {
    StopSlider(
      stops: Effort.levels(option).map { .init(value: $0.value, name: Effort.name($0)) },
      current: option.currentValue, placeholder: "Effort", label: "Reasoning effort", set: set)
  }
}

/** The chat's context limit on the same slider as effort, with a way back to the model's own window. */
struct ContextSlider: View {
  let option: ConfigOption
  let set: (String) -> Void

  /** k is 1024 tokens, as in `/context 64k` */
  static let stops: [StopSlider.Stop] = [32, 64, 100, 128, 200, 256, 300, 400, 500, 512, 1024].map { k in
    .init(value: String(k * 1024), name: k == 1024 ? "1M" : "\(k)k")
  }

  private var auto: Bool { option.currentValue == "auto" }

  var body: some View {
    StopSlider(
      stops: Self.stops, current: option.currentValue,
      placeholder: auto ? "Model default" : (option.current?.name ?? "\(option.currentValue) tokens"),
      suffix: " context", label: "Context limit", set: set)
      .overlay(alignment: .topTrailing) {
        if !auto {
          Button { set("auto") } label: {
            Image(systemName: "arrow.counterclockwise")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(Color.dim)
              .frame(width: 28, height: 28)
              .background(Color.white.opacity(0.08), in: .circle)
              .contentShape(.circle)
          }
          .buttonStyle(QuietPress())
          .accessibilityLabel("Use the model default")
          .transition(.scale(0.8).combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.22, bounce: 0.15), value: auto)
  }
}

/**
 * A track with a stop for each value. Tap a stop or drag the knob: it snaps to the nearest stop as
 * the finger moves, and the value is set the moment the finger lifts.
 */
struct StopSlider: View {
  struct Stop {
    let value: String
    let name: String
  }

  let stops: [Stop]
  let current: String
  /** the title while no stop is chosen */
  let placeholder: String
  /** after a chosen stop's name in the title */
  var suffix = ""
  let label: String
  let set: (String) -> Void
  /** the stop under the finger while it's down */
  @State private var dragging: Int?
  @State private var width: CGFloat = 0

  private static let height: CGFloat = 44
  private static let knob: CGFloat = 36
  private static let pad: CGFloat = 4

  /** nil while none is chosen: no stop is lit and there's no knob until one is tapped */
  private var chosen: Int? { stops.firstIndex { $0.value == current } }
  private var shown: Int? { dragging ?? chosen }
  private var picked: Bool { shown != nil }

  var body: some View {
    VStack(spacing: 14) {
      Text(shown.map { stops[$0].name + suffix } ?? placeholder)
        .font(.geist(17, .semibold))
        .foregroundStyle(picked ? Effort.accent : Color.dim)
        .contentTransition(.numericText())
        .frame(maxWidth: .infinity)
        .frame(height: 28)
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.09))
        if let i = shown, picked {
          Capsule()
            .fill(Effort.accent)
            .frame(width: x(i) + Self.knob / 2 + Self.pad)
        }
        ForEach(stops.indices, id: \.self) { i in
          Circle()
            .fill(Color.white.opacity(i <= (shown ?? -1) ? 0.55 : 0.28))
            .frame(width: 6, height: 6)
            .position(x: x(i), y: Self.height / 2)
        }
        Circle()
          .fill(.white)
          .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
          .frame(width: Self.knob, height: Self.knob)
          .scaleEffect(dragging == nil ? 1 : 1.08)
          .opacity(picked ? 1 : 0)
          .position(x: x(shown ?? 0), y: Self.height / 2)
      }
      .frame(height: Self.height)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      .contentShape(.capsule)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { g in dragging = index(g.location.x) }
          .onEnded { g in
            let i = index(g.location.x)
            dragging = nil
            if stops[i].value != current { set(stops[i].value) }
          }
      )
    }
    .animation(.spring(duration: 0.22, bounce: 0.15), value: shown)
    .animation(.spring(duration: 0.22, bounce: 0.15), value: dragging == nil)
    .sensoryFeedback(.selection, trigger: shown)
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue(shown.map { stops[$0].name + suffix } ?? placeholder)
    .accessibilityAdjustableAction { direction in
      let i = chosen.map { direction == .increment ? min($0 + 1, stops.count - 1) : max($0 - 1, 0) } ?? 0
      set(stops[i].value)
    }
  }

  /** the center of stop `i` */
  private func x(_ i: Int) -> CGFloat {
    let start = Self.pad + Self.knob / 2
    guard stops.count > 1, width > 0 else { return start }
    return start + CGFloat(i) * (width - 2 * start) / CGFloat(stops.count - 1)
  }

  /** the stop nearest `x` */
  private func index(_ x: CGFloat) -> Int {
    guard stops.count > 1, width > 0 else { return 0 }
    let start = Self.pad + Self.knob / 2
    let step = (width - 2 * start) / CGFloat(stops.count - 1)
    return min(max(Int(((x - start) / step).rounded()), 0), stops.count - 1)
  }
}

// MARK: Models

/**
 * How the chat runs. The effort slider sits up top and takes effect as you let go; provider, mode,
 * and a new chat's prompt are menus below it; then the models: tap one and you're done.
 */
struct ModelSheet: View {
  let options: [ConfigOption]
  let set: (String, String) -> Void
  var prompts: [PromptSummary] = []
  var prompt: Binding<String>? = nil
  var mcpNames: [String] = []
  var mcpDisabled: Binding<Set<String>>? = nil
  var mcpEditable = true
  var modelsPending = false
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private var model: ConfigOption? { options.first { $0.id == "model" } }
  private var effort: ConfigOption? {
    modelsPending ? nil : options.first { $0.id == "effort" && Effort.levels($0).count > 1 }
  }
  private var context: ConfigOption? { modelsPending ? nil : options.first { $0.id == "context" } }
  private var showsPrompt: Bool { prompt != nil && !prompts.isEmpty }
  private var menus: [ConfigOption] {
    options.filter { option in ["provider", "mode"].contains(option.id) && option.options.contains { $0.value != option.currentValue } }
  }

  private var shown: [ConfigOption.Choice] {
    guard !modelsPending, let model else { return [] }
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return model.options.filter { q.isEmpty || $0.value.lowercased().contains(q) || $0.label("model").lowercased().contains(q) }
  }

  /** a short list gets a sheet just its size */
  private var fits: Bool { mcpNames.isEmpty && (model?.options.count ?? 0) <= 8 }
  private var fitHeight: CGFloat {
    64 + (effort == nil ? 0 : 138) + (menus.isEmpty && !showsPrompt ? 0 : 44)
      + (context == nil ? 0 : 138) + CGFloat(model?.options.count ?? 0) * 52 + 40
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

      if let effort {
        EffortSlider(option: effort) { set(effort.id, $0) }
          .padding(14)
          .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 26, style: .continuous))
          .padding(.horizontal, 12)
          .padding(.bottom, 14)
      }

      if let context {
        ContextSlider(option: context) { set(context.id, $0) }
          .padding(14)
          .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 26, style: .continuous))
          .padding(.horizontal, 12)
          .padding(.bottom, 14)
      }

      if !menus.isEmpty || showsPrompt {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            if showsPrompt, let prompt { PromptMenu(prompts: prompts, selection: prompt) }
            ForEach(menus) { o in OptionMenu(option: o) { set(o.id, $0) } }
          }
          .padding(.horizontal, 20)
        }
        .padding(.bottom, 12)
      }

      if !modelsPending, (model?.options.count ?? 0) > 8 {
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
          if query.isEmpty, let mcpDisabled, !mcpNames.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
              Text("MCP Servers").font(.geist(13, .medium)).foregroundStyle(Color.dim)
              ForEach(mcpNames, id: \.self) { name in
                let on = !mcpDisabled.wrappedValue.contains(name)
                Button {
                  var disabled = mcpDisabled.wrappedValue
                  if on { disabled.insert(name) } else { disabled.remove(name) }
                  mcpDisabled.wrappedValue = disabled
                } label: {
                  HStack {
                    Text(name).font(.geist(15))
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                      .font(.system(size: 20))
                      .foregroundStyle(on ? Effort.accent : Color.dim)
                  }
                  .frame(minHeight: 44)
                  .contentShape(.rect)
                }
                .buttonStyle(QuietPress())
                .accessibilityLabel(name)
                .accessibilityValue(on ? "On" : "Off")
              }
            }
            .disabled(!mcpEditable)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
          }
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
        if modelsPending {
          Text("Models for this provider aren’t loaded yet.").font(.geist(15)).foregroundStyle(Color.dim)
        } else if shown.isEmpty, !query.isEmpty {
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

/** Which library prompt a new chat runs with; spark's own when none is chosen. */
private struct PromptMenu: View {
  let prompts: [PromptSummary]
  @Binding var selection: String

  var body: some View {
    let current = prompts.first { $0.name == selection }
    Menu {
      Picker("Prompt", selection: $selection) {
        Text("Default").tag("")
        ForEach(prompts) { p in Text(p.name).tag(p.name) }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "text.quote")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.dim)
        Text(current?.name ?? "Default")
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
    .accessibilityLabel(current.map { "Prompt \($0.name)" } ?? "Choose a prompt")
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
