import SwiftUI

struct PenControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Pen").font(ToolHeaderStyle.titleFont)
            Picker("Draw", selection: Binding(get: { session.penStroked }, set: { session.penStroked = $0 })) {
                Text("Fill").tag(false)
                Text("Stroke").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Fill closes the path and fills it; Stroke draws the outline with the width below")
            if session.penStroked {
                HStack(spacing: 6) {
                    Text("Width")
                    Slider(value: Binding(get: { min(100, session.penLineWidth) },
                                          set: { session.penLineWidth = $0.rounded() }), in: 1...100)
                        .frame(width: 100)
                    TextField("Width", value: Binding(get: { session.penLineWidth },
                                                      set: { session.penLineWidth = $0.isFinite ? min(5000, max(1, $0)) : 2 }),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .arrowSteps(value: { session.penLineWidth },
                                    change: { session.penLineWidth = min(5000, max(1, $0)) })
                        .unitSuffix("px")
                }
            }
            HStack(spacing: 6) {
                Text(session.penStroked ? "Stroke" : "Fill")
                Button { session.openColorPicker(background: false) } label: {
                    let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    swatch.fill(Color(nsColor: session.foregroundColor.nsColor))
                        .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                        .frame(width: 36, height: 18)
                }
                .buttonStyle(.plain)
                .help("Paths draw in the foreground color; click to change it")
            }
            // While a path is being drawn, offer the same finish/cancel as Enter and Escape.
            if session.penDraft != nil {
                Button("Cancel") { session.cancelPen() }
                Button("Done") { session.finishPen() }
                    .help("Finish the path (Enter). Click its first anchor to close it as a filled shape.")
            }
            // A live path layer can become a selection or plain pixels.
            if session.activeLayer?.livePath != nil {
                Button("Selection") { session.makeSelectionFromPath() }
                    .help("Turn this path into a selection")
                Button("Rasterize") { session.rasterizePath() }
                    .help("Drop the path, leaving the pixels as an ordinary layer")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}
