import SwiftUI

extension EditorTool: Identifiable {
  public var id: String {
    String(describing: self)
  }
}

struct EditorToolbarModel {
  var tool: EditorTool
  var canUndo: Bool
  var isFrozen: Bool
  var isSaving: Bool
  var hasCropDraft: Bool
  var strokeWidth: CGFloat = 4
  var strokeColor: RGBAColor = .coral
  var mosaicWidth: CGFloat = 24
  var textFontDesign: EditorFontDesign = .system
  var textFontSize: CGFloat = 18
  var textRotation: Double = 0
  var textColor: RGBAColor = .coral
  var isOCRWorking = false
  var selectionIsText = false
}

enum EditorStyleMenuAction: Equatable {
  case strokeWidth(CGFloat)
  case strokeColor(RGBAColor)
  case mosaicWidth(CGFloat)
  case textFont(EditorFontDesign)
  case textFontSize(CGFloat)
  case textRotation(Double)
  case textColor(RGBAColor)
  case copyAllOCRText
  case previewStrokeColor(RGBAColor)
  case previewTextColor(RGBAColor)
  case cancelColorTransaction(RGBAColor, isText: Bool)
}

@MainActor
final class EditorToolbarViewModel: ObservableObject {
  @Published var model: EditorToolbarModel
  @Published var styleMenuPresentedTool: EditorTool?

  init(model: EditorToolbarModel) {
    self.model = model
  }
}

struct EditorToolbarView: View {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var viewModel: EditorToolbarViewModel

  let onSelectTool: (EditorTool) -> Void
  let onUndo: () -> Void
  let onSaveToDesktop: () -> Void
  let onCancel: () -> Void
  let onConfirm: () -> Void
  let onStyleAction: (EditorStyleMenuAction) -> Void
  let onPresentColorPanel: (
    RGBAColor,
    @escaping (RGBAColor) -> Void,
    @escaping (RGBAColor) -> Void,
    @escaping () -> Void
  ) -> Void

  var body: some View {
    HStack(spacing: 4) {
      toolButton(.selection, title: "选择", symbol: "cursorarrow")
      toolButton(.rectangle, title: "矩形", symbol: "rectangle")
      toolButton(.ellipse, title: "椭圆", symbol: "circle")
      toolButton(.line, title: "直线", symbol: "line.diagonal")
      toolButton(.arrow, title: "箭头", symbol: "arrow.right")
      toolButton(.text, title: "文字", symbol: "textformat")
      toolButton(.mosaic, title: "马赛克", symbol: "square.grid.3x3.fill")
      toolButton(.crop, title: "裁剪", symbol: "crop")
      toolButton(.ocr, title: "OCR", symbol: "text.viewfinder")

      divider

      actionButton("撤销", symbol: "arrow.uturn.backward", disabled: !viewModel.model.canUndo || viewModel.model.isFrozen) {
        onUndo()
      }
      actionButton(
        "保存到桌面",
        symbol: "square.and.arrow.down",
        disabled: viewModel.model.isFrozen || viewModel.model.isSaving
      ) {
        onSaveToDesktop()
      }
      actionButton("取消", symbol: "xmark", disabled: viewModel.model.isFrozen) {
        onCancel()
      }
      actionButton("确认", symbol: "checkmark", disabled: viewModel.model.isFrozen) {
        onConfirm()
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(toolbarSurface)
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(dividerColor.opacity(0.5), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .popover(item: $viewModel.styleMenuPresentedTool, arrowEdge: .bottom) { tool in
      EditorToolStylePanel(
        model: viewModel.model,
        tool: tool,
        onAction: onStyleAction,
        onDismiss: {
          viewModel.styleMenuPresentedTool = nil
        },
        onPalette: {
          let initial = tool == .text
            ? viewModel.model.textColor
            : viewModel.model.strokeColor
          onPresentColorPanel(
            initial,
            { color in
              switch tool {
              case .text:
                onStyleAction(.previewTextColor(color))
              default:
                onStyleAction(.previewStrokeColor(color))
              }
            },
            { color in
              switch tool {
              case .text:
                onStyleAction(.textColor(color))
              default:
                onStyleAction(.strokeColor(color))
              }
            },
            {
              onStyleAction(
                .cancelColorTransaction(
                  initial,
                  isText: tool == .text
                )
              )
            }
          )
        }
      )
    }
  }

  private func toolButton(
    _ tool: EditorTool,
    title: String,
    symbol: String
  ) -> some View {
    let isSelected = viewModel.model.tool == tool
    return Button {
      onSelectTool(tool)
    } label: {
      VStack(spacing: 2) {
        if tool == .text {
          Text("T")
            .font(.system(size: 17, weight: .bold))
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
        } else {
          Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
        }
        if tool == .crop, viewModel.model.hasCropDraft {
          Circle()
            .fill(accent)
            .frame(width: 5, height: 5)
        }
      }
      .frame(width: 38, height: 44)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? accent.opacity(0.22) : Color.clear)
      }
      .foregroundStyle(isSelected ? accent : secondaryText)
    }
    .buttonStyle(.plain)
    .disabled(viewModel.model.isFrozen)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func actionButton(
    _ title: String,
    symbol: String,
    disabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 34, height: 34)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : primaryText)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .help(title)
    .accessibilityLabel(title)
  }

  private var divider: some View {
    Rectangle()
      .fill(dividerColor)
      .frame(width: 1, height: 24)
      .padding(.horizontal, 3)
  }

  private var toolbarSurface: Color {
    colorScheme == .dark
      ? Color(nsColor: .windowBackgroundColor).opacity(0.96)
      : Color.white.opacity(0.96)
  }

  private var dividerColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.1)
  }

  private var primaryText: Color {
    colorScheme == .dark ? Color.white : Color.black.opacity(0.85)
  }

  private var secondaryText: Color {
    primaryText.opacity(0.65)
  }

  private var accent: Color {
    Color(red: 0xE9 / 255.0, green: 0x65 / 255.0, blue: 0x48 / 255.0)
  }
}

private struct EditorToolStylePanel: View {
  let model: EditorToolbarModel
  let tool: EditorTool
  let onAction: (EditorStyleMenuAction) -> Void
  let onDismiss: () -> Void
  let onPalette: () -> Void
  @State private var hasSelectedWidth = false
  @State private var hasSelectedColor = false

  var body: some View {
    Group {
      switch tool {
      case .rectangle, .ellipse, .line, .arrow:
        shapeMenu
      case .text:
        textMenu
      case .mosaic:
        mosaicMenu
      case .ocr:
        ocrMenu
      case .selection:
        if model.selectionIsText {
          textMenu
        } else {
          shapeMenu
        }
      default:
        EmptyView()
      }
    }
    .padding(12)
    .frame(width: 320)
  }

  private var shapeMenu: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        ForEach([CGFloat(2), 4, 8], id: \.self) { width in
          Button {
            hasSelectedWidth = true
            onAction(.strokeWidth(width))
            if hasSelectedWidth && hasSelectedColor {
              onDismiss()
            }
          } label: {
            Circle()
              .fill(model.strokeColor.color)
              .frame(
                width: width == 2 ? 8 : width == 4 ? 11 : 14,
                height: width == 2 ? 8 : width == 4 ? 11 : 14
              )
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.plain)
        }
      }
      Rectangle()
        .fill(Color.black.opacity(0.12))
        .frame(width: 1, height: 34)
      colorRow(selected: model.strokeColor) { color in
        hasSelectedColor = true
        onAction(.strokeColor(color))
        if hasSelectedWidth && hasSelectedColor {
          onDismiss()
        }
      } onPalette: {
        onPalette()
      }
    }
  }

  private var mosaicMenu: some View {
    HStack(spacing: 6) {
      ForEach([CGFloat(12), 24, 40], id: \.self) { width in
        Button {
          onAction(.mosaicWidth(width))
          onDismiss()
        } label: {
          Circle()
            .fill(Color.black.opacity(0.75))
            .frame(width: width, height: width)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var ocrMenu: some View {
    VStack(spacing: 10) {
      Text("整图文字识别")
        .font(.headline)
      Button {
        onAction(.copyAllOCRText)
      } label: {
        Label("复制全部文字", systemImage: "doc.on.doc")
          .frame(maxWidth: .infinity)
      }
      .disabled(model.isOCRWorking)
      if model.isOCRWorking {
        ProgressView()
          .controlSize(.small)
      }
    }
  }

  private var textMenu: some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(EditorFontDesign.allCases, id: \.self) { design in
          Button {
            onAction(.textFont(design))
          } label: {
            if design == model.textFontDesign {
              Label(design.shortName, systemImage: "checkmark")
            } else {
              Text(design.shortName)
            }
          }
        }
      } label: {
        Text("T")
          .font(.system(size: 15, weight: .bold))
          .frame(width: 34, height: 28)
          .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      Menu {
        ForEach([10, 12, 14, 16, 18, 24, 32, 48, 64, 72, 96], id: \.self) { size in
          Button {
            onAction(.textFontSize(CGFloat(size)))
          } label: {
            if size == Int(model.textFontSize) {
              Label("\(size) pt", systemImage: "checkmark")
            } else {
              Text("\(size) pt")
            }
          }
        }
      } label: {
        Text("\(Int(model.textFontSize))")
          .font(.system(size: 14))
          .frame(width: 38, height: 28)
          .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      colorRow(selected: model.textColor) { color in
        onAction(.textColor(color))
      } onPalette: {
        onPalette()
      }
    }
  }

  private func colorRow(
    selected: RGBAColor,
    action: @escaping (RGBAColor) -> Void,
    onPalette: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 6) {
      ForEach([RGBAColor.coral, .red, .green, .blue, .white, .graphite], id: \.self) { color in
        Button {
          action(color)
        } label: {
          Circle()
            .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
            .background(Circle().fill(color.color))
            .frame(width: 22, height: 22)
            .overlay {
              if color == selected {
                Image(systemName: "checkmark")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundStyle(color.isDark ? Color.white : Color.black)
              }
            }
        }
        .buttonStyle(.plain)
      }
      Button {
        onPalette()
      } label: {
        Image(systemName: "paintpalette")
          .font(.system(size: 15))
          .frame(width: 22, height: 22)
          .overlay {
            Circle()
              .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
          }
      }
      .buttonStyle(.plain)
    }
  }
}

private extension EditorFontDesign {
  var shortName: String {
    switch self {
    case .system:
      return "黑体"
    case .serif:
      return "衬线"
    case .rounded:
      return "圆体"
    case .monospaced:
      return "等宽"
    }
  }
}

private extension RGBAColor {
  var color: Color {
    Color(red: red, green: green, blue: blue, opacity: alpha)
  }

  var isDark: Bool {
    let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
    return luminance < 0.5
  }
}
