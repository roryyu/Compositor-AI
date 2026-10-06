import SwiftUI
import UniformTypeIdentifiers

/// The open filter's panel: its settings, Preview, and Cancel / OK.
struct FilterSheet: View {
    @Bindable var session: EditorSession
    private var edit: FilterEdit? { session.filterEdit }
    private var settings: FilterSettings { edit?.settings ?? FilterSettings() }
    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: edit?.preview ?? true)
    }

    private var isCameraRaw: Bool { edit?.kind == .cameraRaw }

    /// Displace's map choices: the document's raster layers other than the one being filtered.
    private var displaceMapLayers: [ImageLayer] {
        guard let edit, let layers = session.document?.layers else { return [] }
        return layers.filter { $0.asset != nil && !$0.isGroup && $0.id != edit.layerID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch edit?.kind ?? .gaussianBlur {
            case .curves:
                CurvesControls(settings: Binding(get: { settings.curves }, set: { new in update { $0.curves = new } }))
            case .exposure:
                control("Exposure", \.exposure.exposure, range: ExposureSettings.exposureRange, unit: "", decimals: 2, logarithmic: false)
                control("Offset", \.exposure.offset, range: ExposureSettings.offsetRange, unit: "", decimals: 4, logarithmic: false)
                control("Gamma", \.exposure.gamma, range: ExposureSettings.gammaRange, unit: "", decimals: 2, logarithmic: true)
            case .gradientMap:
                GradientMapControls(settings: Binding(get: { settings.gradientMap }, set: { new in update { $0.gradientMap = new } }),
                                    pick: { session.openGradientMapColorPicker(highlights: $0) })
            case .blackWhite:
                // Each slider says how bright that family of colors becomes, as Photoshop's do.
                control("Reds", \.blackWhite.reds, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Yellows", \.blackWhite.yellows, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Greens", \.blackWhite.greens, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Cyans", \.blackWhite.cyans, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Blues", \.blackWhite.blues, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Magentas", \.blackWhite.magentas, range: BlackWhiteSettings.range, unit: "%", decimals: 0, logarithmic: false)
                Toggle("Tint", isOn: flag(\.blackWhite.tint))
                    .help("Color the result while keeping its tones, for a sepia or a cyanotype")
                if settings.blackWhite.tint {
                    control("Hue", \.blackWhite.tintHue, range: 0...360, unit: "°", decimals: 0, logarithmic: false)
                    control("Saturation", \.blackWhite.tintSaturation, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                }
            case .cameraRaw:
                CameraRawControls(session: session)
                    .frame(maxHeight: .infinity, alignment: .top)
            case .colorBalance:
                Text("Shadows").font(.headline)
                control("Cyan / Red", \.colorBalance.shadowCyanRed, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false)
                control("Magenta / Green", \.colorBalance.shadowMagentaGreen, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false)
                control("Yellow / Blue", \.colorBalance.shadowYellowBlue, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false)
                Text("Midtones").font(.headline)
                control("Cyan / Red", \.colorBalance.midCyanRed, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false)
                control("Magenta / Green", \.colorBalance.midMagentaGreen, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false)
                control("Yellow / Blue", \.colorBalance.midYellowBlue, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false)
                Text("Highlights").font(.headline)
                control("Cyan / Red", \.colorBalance.highlightCyanRed, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false)
                control("Magenta / Green", \.colorBalance.highlightMagentaGreen, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false)
                control("Yellow / Blue", \.colorBalance.highlightYellowBlue, range: ColorBalanceSettings.range, unit: "", decimals: 0, logarithmic: false)
                Toggle("Preserve Luminosity", isOn: flag(\.colorBalance.preserveLuminosity))
                    .help("Put each pixel's brightness back afterwards, so only the color moves")
            case .grain:
                control("Amount", \.grain.amount, range: GrainSettings.amountRange, unit: "", decimals: 0, logarithmic: false)
                control("Size", \.grain.size, range: GrainSettings.sizeRange, unit: "px", decimals: 1, logarithmic: true)
                control("Roughness", \.grain.roughness, range: GrainSettings.roughnessRange, unit: "", decimals: 0, logarithmic: false)
            case .vibrance:
                control("Vibrance", \.vibrance.amount, range: VibranceSettings.range, unit: "", decimals: 0, logarithmic: false)
                control("Saturation", \.vibrance.saturation, range: VibranceSettings.range, unit: "", decimals: 0, logarithmic: false)
            case .shadowsHighlights:
                control("Shadows", \.shadowsHighlights.shadows, range: ShadowsHighlightsSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Highlights", \.shadowsHighlights.highlights, range: ShadowsHighlightsSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Radius", \.shadowsHighlights.radius, range: ShadowsHighlightsSettings.radiusRange, unit: "px", decimals: 0, logarithmic: false)
            case .posterize:
                control("Levels", \.posterize.levels, range: PosterizeSettings.levelsRange, unit: "", decimals: 0, logarithmic: false)
            case .threshold:
                control("Level", \.threshold.level, range: ThresholdSettings.levelRange, unit: "", decimals: 0, logarithmic: false)
            case .desaturate:
                control("Amount", \.desaturate.amount, range: DesaturateSettings.range, unit: "%", decimals: 0, logarithmic: false)
            case .photoFilter:
                control("Hue", \.photoFilter.hue, range: 0...360, unit: "°", decimals: 0, logarithmic: false)
                control("Density", \.photoFilter.density, range: PhotoFilterSettings.densityRange, unit: "%", decimals: 0, logarithmic: false)
                Toggle("Preserve Luminosity", isOn: flag(\.photoFilter.preserveLuminosity))
                    .help("Put each pixel's brightness back afterwards, so the filter only recolors")
            case .channelMixer:
                Text("Red").font(.headline)
                control("Red", \.channelMixer.redRed, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Green", \.channelMixer.redGreen, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Blue", \.channelMixer.redBlue, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Constant", \.channelMixer.redConstant, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                Text("Green").font(.headline)
                control("Red", \.channelMixer.greenRed, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Green", \.channelMixer.greenGreen, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Blue", \.channelMixer.greenBlue, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Constant", \.channelMixer.greenConstant, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                Text("Blue").font(.headline)
                control("Red", \.channelMixer.blueRed, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Green", \.channelMixer.blueGreen, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Blue", \.channelMixer.blueBlue, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                control("Constant", \.channelMixer.blueConstant, range: ChannelMixerSettings.range, unit: "%", decimals: 0, logarithmic: false)
                Toggle("Monochrome", isOn: Binding(
                    get: { settings.channelMixer.monochrome },
                    set: { on in
                        update {
                            $0.channelMixer.monochrome = on
                            // Checking it from the untouched image starts from luminance-ish weights,
                            // as Photoshop's does, rather than from a mix that changes nothing.
                            if on && $0.channelMixer.isIdentity {
                                $0.channelMixer.redRed = 40; $0.channelMixer.redGreen = 40; $0.channelMixer.redBlue = 20
                            }
                        }
                    }))
                    .help("Send the Red row to all three channels, for a custom black-and-white conversion")
            case .colorLookup:
                HStack(spacing: 8) {
                    Text("LUT").frame(minWidth: 60, alignment: .leading).fixedSize()
                    Button("Choose…") { chooseLUT() }
                    if settings.colorLookup.cube != nil {
                        Text(settings.colorLookup.lutName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                control("Intensity", \.colorLookup.intensity, range: ColorLookupSettings.intensityRange, unit: "%", decimals: 0, logarithmic: false)
                    .disabled(settings.colorLookup.cube == nil)
                if settings.colorLookup.cube == nil {
                    Text("Choose a .cube 3D lookup table; its data is stored inside the document, as Photoshop does.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .removeBackground:
                Text("Hide the background behind a layer mask, keeping the foreground subjects. The pixels stay, so the background can be painted back at any time.")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Quality", selection: Binding(get: { settings.backgroundQuality },
                                                     set: { new in update { $0.backgroundQuality = new } })) {
                    ForEach(BackgroundQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Basic is quick; Advanced refines the mask against the layer's own detail, for hair and fur")
                if settings.backgroundQuality == .advanced {
                    control("Refine", \.refineEdges, range: 0...40, unit: "px", decimals: 0, logarithmic: false)
                        .help("Pull the mask onto the image's own edges, which recovers hair and fur")
                    control("Contrast", \.matteContrast, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                        .help("Clear the haze that leaves background showing through thin areas")
                    control("Shift Edge", \.shiftEdge, range: -10...10, unit: "px", decimals: 0, logarithmic: false)
                        .help("Shrink the mask to drop the rim of background color around the subject, or grow it")
                }
            case .contentAwareFill:
                Text("Fill the selection using surrounding pixels from this layer.")
                    .fixedSize(horizontal: false, vertical: true)
            case .gaussianBlur:
                control("Radius", \.radius, range: 0.1...250, unit: "px", decimals: 1, logarithmic: true)
            case .motionBlur:
                control("Angle", \.angle, range: -90...90, unit: "°", decimals: 0, logarithmic: false)
                control("Distance", \.distance, range: 1...2000, unit: "px", decimals: 0, logarithmic: true)
            case .addNoise:
                control("Amount", \.amount, range: 0.1...400, unit: "%", decimals: 1, logarithmic: true)
                Picker("Distribution", selection: flag(\.gaussian)) {
                    Text("Uniform").tag(false)
                    Text("Gaussian").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Monochromatic", isOn: flag(\.monochromatic))
            case .vignette:
                HStack(spacing: 8) {
                    Text("Color").frame(width: 95, alignment: .leading)
                    Button { session.openVignetteColorPicker() } label: {
                        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                        shape.fill(Color(.sRGB, red: settings.vignetteColor.red,
                                         green: settings.vignetteColor.green, blue: settings.vignetteColor.blue))
                            .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1.5) }
                            .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                            .frame(width: 24, height: 24)
                            .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    .help("Choose the vignette color")
                    Spacer()
                }
                control("Amount", \.vignetteAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                    .help("Blend the chosen color into the edges while keeping the center unchanged")
                control("Midpoint", \.vignetteMidpoint, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                control("Roundness", \.vignetteRoundness, range: -100...100, unit: "", decimals: 0, logarithmic: false)
                control("Feather", \.vignetteFeather, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                control("Highlights", \.vignetteHighlights, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                    .help("Protect bright areas near the edge")
            case .bloomGlow:
                control("Amount", \.bloomAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                control("Radius", \.bloomRadius, range: 1...150, unit: "px", decimals: 0, logarithmic: true)
            case .tonalContrast:
                control("Amount", \.tonalAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
                control("Shadows", \.tonalShadows, range: -100...100, unit: "%", decimals: 0, logarithmic: false)
                control("Midtones", \.tonalMidtones, range: -100...100, unit: "%", decimals: 0, logarithmic: false)
                control("Highlights", \.tonalHighlights, range: -100...100, unit: "%", decimals: 0, logarithmic: false)
                control("Radius", \.tonalRadius, range: 1...100, unit: "px", decimals: 0, logarithmic: true)
            case .lensCorrection:
                control("Remove Distortion", \.distortion, range: -100...100, unit: "", decimals: 0, logarithmic: false)
                Text("Positive straightens lines that bow outward (barrel); negative, lines that bow inward (pincushion).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .sharpen:
                control("Amount", \.sharpenAmount, range: 0...100, unit: "%", decimals: 0, logarithmic: false)
            case .unsharpMask:
                control("Amount", \.unsharpAmount, range: 0...500, unit: "%", decimals: 0, logarithmic: false)
                control("Radius", \.radius, range: 0.1...100, unit: "px", decimals: 1, logarithmic: true)
            case .boxBlur:
                control("Radius", \.radius, range: 0.1...250, unit: "px", decimals: 1, logarithmic: true)
            case .discBlur:
                control("Radius", \.radius, range: 0.1...250, unit: "px", decimals: 1, logarithmic: true)
            case .tiltShift:
                control("Radius", \.radius, range: 0.1...100, unit: "px", decimals: 1, logarithmic: true)
                Text("Blurs above and below a horizontal band across the middle, for a miniature effect.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .zoomBlur:
                control("Amount", \.zoomAmount, range: 0...200, unit: "", decimals: 0, logarithmic: false)
            case .pixelate:
                control("Cell Size", \.pixelateScale, range: 1...100, unit: "px", decimals: 0, logarithmic: true)
            case .crystallize:
                control("Radius", \.crystallizeRadius, range: 1...100, unit: "px", decimals: 0, logarithmic: true)
            case .pointillize:
                control("Radius", \.pointillizeRadius, range: 1...100, unit: "px", decimals: 0, logarithmic: true)
            case .twirl:
                control("Angle", \.twirlAngle, range: -360...360, unit: "°", decimals: 0, logarithmic: false)
            case .ripple:
                control("Scale", \.rippleScale, range: 0...100, unit: "", decimals: 0, logarithmic: false)
            case .displace:
                Picker("Map", selection: Binding(get: { settings.displaceMapLayerID },
                                                 set: { new in session.updateDisplaceMap(layerID: new) })) {
                    Text("None").tag(UUID?.none)
                    ForEach(displaceMapLayers, id: \.id) { layer in Text(layer.name).tag(UUID?.some(layer.id)) }
                }
                control("Scale", \.displaceScale, range: 0...100, unit: "", decimals: 0, logarithmic: false)
                Text("The map layer's red channel pushes pixels horizontally and its green vertically; neutral gray leaves them in place.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Preview", isOn: Binding(get: { edit?.preview ?? true },
                                            set: { session.updateFilter(settings, preview: $0) }))
            if let error = edit?.previewError {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if session.adjustmentOriginal == nil && session.selection != nil {
                Text("Limited to the selection").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Cancel") { session.cancelFilter() }.configuredNativeShortcut(.escape)
                Spacer()
                // While the preview is being worked out (Remove Background's mask, Content-Aware Fill) OK waits, so
                // the panel says what it is waiting for rather than showing a disabled button and nothing else.
                if edit?.committing == true || edit?.preparing == true {
                    ProgressView().controlSize(.small)
                    Text(edit?.committing == true ? "Applying…" : "Working…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("OK") { Task { await session.commitFilter() } }
                    .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                    .disabled(edit?.kind.isAutomatic == true && (edit?.preparing == true || edit?.previewError != nil))
            }
        }
        .padding(24)
        .frame(width: isCameraRaw ? FloatingPanelController.dockedWidth : 380)
        .frame(maxHeight: isCameraRaw ? .infinity : nil, alignment: .top)
        .fixedSize(horizontal: false, vertical: !isCameraRaw)

        .disabled(edit?.committing == true)
        // Filter colors preview live while the app's color picker is open.
        .onChange(of: session.colorPicker?.color) { _, _ in
            session.previewGradientMapColor()
            session.previewVignetteColor()
        }
    }

    private func flag(_ key: WritableKeyPath<FilterSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }

    /// Color Lookup's file chooser: parses the picked `.cube` right away and shows why it failed inline.
    private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let lut = try CubeLUT.load(url: url)
            edit?.previewError = nil
            update {
                $0.colorLookup.cube = lut.data
                $0.colorLookup.dimension = lut.dimension
                $0.colorLookup.lutName = url.deletingPathExtension().lastPathComponent
            }
        } catch let error as CubeLUT.Error {
            edit?.previewError = switch error {
            case .oneDimensional: "That is a 1D LUT; only 3D .cube tables are supported."
            case .missingSize: "No LUT_3D_SIZE line found in that file."
            case .unsupportedSize: "The table size is outside the supported 2–65 range."
            case .truncatedTable: "The file has fewer samples than its declared size."
            case .badValue: "The file contains values that could not be read."
            }
        } catch {
            edit?.previewError = "The file could not be read."
        }
    }

    /// A slider plus an exact field. Logarithmic sliders give the small values used most most of the travel.
    private func control(_ title: String, _ key: WritableKeyPath<FilterSettings, Double>, range: ClosedRange<Double>,
                         unit: String, decimals: Int, logarithmic: Bool) -> some View {
        let step = pow(10, Double(decimals))
        return HStack(spacing: 10) {
            Text(title).frame(minWidth: 60, alignment: .leading).fixedSize()
            Slider(value: Binding(get: { logarithmic ? log(settings[keyPath: key]) : settings[keyPath: key] },
                                  set: { value in update { $0[keyPath: key] = ((logarithmic ? exp(value) : value) * step).rounded() / step } }),
                   in: logarithmic ? log(range.lowerBound)...log(range.upperBound) : range)
            TextField(title, value: Binding(get: { settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } }),
                      format: .number.precision(.fractionLength(0...decimals)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .unitSuffix(unit)
        }
    }
}

/// Gradient Map's two colors, the gradient they make, and Reverse. The colors are swatches like the
/// tool rail's, and open the app's own color picker.
struct GradientMapControls: View {
    @Binding var settings: GradientMapSettings
    /// Opens the color picker on an end: false for Shadows, true for Highlights.
    let pick: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let ends = settings.ends
            LinearGradient(colors: [color(ends.dark), color(ends.light)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.35)) }
                .accessibilityHidden(true)
            HStack(spacing: 20) {
                swatch("Shadows", settings.shadows) { pick(false) }
                swatch("Highlights", settings.highlights) { pick(true) }
                Spacer()
            }
            Toggle("Reverse", isOn: $settings.reversed)
        }
    }

    private func color(_ value: AdjustmentColor) -> Color { Color(.sRGB, red: value.red, green: value.green, blue: value.blue) }

    private func swatch(_ title: String, _ value: AdjustmentColor, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return HStack(spacing: 8) {
            Button(action: action) {
                shape
                    .fill(color(value))
                    .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1.5) }
                    .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                    .frame(width: 24, height: 24)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .help("Choose the \(title.lowercased()) color")
            .accessibilityLabel("\(title) color")
            Text(title)
        }
    }
}
