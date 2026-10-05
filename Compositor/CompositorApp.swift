import SwiftUI
import Sparkle

@main
struct CompositorApp: App {
    @NSApplicationDelegateAdaptor(CompositorApplicationDelegate.self) private var applicationDelegate
    @State private var language = Localization.shared
    private var session: EditorSession { applicationDelegate.session }
    var body: some Scene {
        Window("Compositor", id: "editor") {
            // LocalizationRoot re-identifies the tree when the language changes, which is what lets the
            // `Text(Localization.v("literal"))` and command titles below be resolved again in the new language.
            LocalizationRoot {
                ProjectWorkspaceView(applicationDelegate: applicationDelegate).roundedControls()
            }
            .environment(language)
        }
            .defaultSize(width: 1180, height: 780)
            // Files opened from Finder or dropped on the Dock icon go to the app delegate, which imports them into
            // the open window. Left to SwiftUI, each one builds a throwaway window and fades the editor out and back.
            .handlesExternalEvents(matching: [])
            // A first launch fills the screen (without going full screen); after that macOS reopens the window at the
            // size it was left.
            .defaultWindowPlacement { _, context in
                WindowPlacement(size: context.defaultDisplay.visibleRect.size)
            }
            // The project's name is already on its tab, so the toolbar doesn't repeat it as a window title.
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .commands {
                CommandGroup(replacing: .undoRedo) {
                    // Dialog text fields keep native text undo; document history
                    // is unavailable while an import or modal edit is active.
                    if session.textDraft != nil || session.levels != nil || session.isProjectBusy || session.showsNewDocument || session.showsImporter || session.renamingLayerID != nil || session.transformEdit?.persistent == true {
                        Button(Localization.v("Undo")) {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil)
                            }
                        }
                            .configuredKeyboardShortcut("z")
                        Button(Localization.v("Redo")) {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil)
                            }
                        }
                            .configuredKeyboardShortcut("z", modifiers: [.command, .shift])
                    } else {
                        Button(session.history.canUndo
                            ? Localization.v("Undo %@", session.history.undoName)
                            : Localization.v("Undo")) { session.undo() }
                            .configuredKeyboardShortcut("z").disabled(!session.canUndo)
                        Button(session.history.canRedo
                            ? Localization.v("Redo %@", session.history.redoName)
                            : Localization.v("Redo")) { session.redo() }
                            .configuredKeyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
                    }
                }
                CommandGroup(replacing: .newItem) {
                    Button(Localization.v("New Canvas…")) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.newCanvas() }
                    }.configuredKeyboardShortcut("n")
                        .disabled(!applicationDelegate.projects.canStart)
                    Button(Localization.v("Open Project…")) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.open() }
                    }
                        .configuredKeyboardShortcut("o").disabled(!applicationDelegate.projects.canStart)
                    Menu(Localization.v("Open Recent")) {
                        ForEach(RecentProjects.shared.urls, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                applicationDelegate.showEditor?()
                                Task { await applicationDelegate.projects.open(url) }
                            }
                        }
                        Divider()
                        Button(Localization.v("Clear Menu")) { RecentProjects.shared.clear() }
                            .disabled(RecentProjects.shared.urls.isEmpty)
                    }
                        .disabled(!applicationDelegate.projects.canStart)
                    Button(Localization.v("Import Images…")) { session.showsImporter = true }
                        .disabled(session.levels != nil || session.showsBusy || session.isImporting || session.showsNewDocument)
                }
                CommandGroup(replacing: .saveItem) {
                    Button(Localization.v("Save")) { Task { await applicationDelegate.projects.save() } }
                        .configuredKeyboardShortcut("s").disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(Localization.v("Save As…")) { Task { await applicationDelegate.projects.save(asNew: true) } }
                        .configuredKeyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    Button(Localization.v("Export PNG…")) { Task { await applicationDelegate.projects.exportPNG() } }
                        .configuredKeyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(Localization.v("Export JPEG…")) { Task { await applicationDelegate.projects.exportJPEG() } }
                        .configuredKeyboardShortcut("s", modifiers: [.command, .option, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    Button(Localization.v("Close Project")) {
                        if let window = applicationDelegate.projects.window {
                            Task { await applicationDelegate.projects.close(window) }
                        }
                    }.configuredKeyboardShortcut("w").disabled(!applicationDelegate.projects.canStart)
                }
                // Grouped: a commands builder takes at most ten items.
                Group {
                    CommandGroup(after: .appInfo) {
                        Button(Localization.v("Check for Updates…")) { applicationDelegate.updater.checkForUpdates(nil) }
                        Divider()
                        // The app's own strings are localized, but the ones macOS supplies around them — the menu
                        // bar's "About Compositor", "Services", "Quit" — are not: the system localizes those per app
                        // from what the bundle declares, which a running app cannot change. Switching here changes
                        // what this app draws; a relaunch is what changes what macOS draws for it. See
                        // docs/localization.md.
                        Picker(selection: Binding(get: { language.language },
                                                  set: { language.language = $0 })) {
                            ForEach(Localization.Language.allCases) { choice in
                                // `verbatim` so each language is listed in its own script and stays put whatever the
                                // current language is — a reader who cannot read the current one still has to find
                                // their own.
                                Text(verbatim: choice.endonym).tag(choice)
                            }
                        } label: {
                            Text(Localization.v("Language"))
                        }
                    }
                    CommandGroup(after: .toolbar) {
                        // With a dialog's preview open (Export JPEG), these zoom that preview rather than the canvas.
                        Button(Localization.v("Fit Canvas")) {
                            if let preview = session.previewZoom { preview(.fit) } else { session.fit() }
                        }.configuredKeyboardShortcut("0").disabled(session.document == nil)
                        Button(Localization.v("Actual Pixels")) {
                            if let preview = session.previewZoom { preview(.actual) } else { session.zoom(to: 1) }
                        }.configuredKeyboardShortcut("1").disabled(session.document == nil)
                        Button(Localization.v("Zoom In")) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomIn) } else { session.zoomKeyboard(by: 1) }
                        }
                            .configuredKeyboardShortcut("=").disabled(session.document == nil)
                        Button(Localization.v("Zoom Out")) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomOut) } else { session.zoomKeyboard(by: -1) }
                        }
                            .configuredKeyboardShortcut("-").disabled(session.document == nil)
                        Toggle(Localization.v("Pixel Grid (800% and above)"), isOn: Binding(get: { session.showsPixelGrid },
                                                                              set: { session.showsPixelGrid = $0 }))
                        Toggle(Localization.v("Snap"), isOn: Binding(get: { session.snappingEnabled },
                                                     set: { session.snappingEnabled = $0 }))
                        Toggle(Localization.v("Show Transform Controls"), isOn: Binding(get: { session.showsTransformControls },
                                                                          set: { session.showsTransformControls = $0 }))
                            .configuredKeyboardShortcut("h").disabled(session.tool != .move || session.document == nil)
                        Group {
                            Divider()
                            Menu(Localization.v("Show")) {
                                Toggle(Localization.v("Grid"), isOn: Binding(get: { session.showsGrid }, set: { session.showsGrid = $0 }))
                                    .configuredKeyboardShortcut("'").disabled(session.document == nil)
                                Toggle(Localization.v("Guides"), isOn: Binding(get: { session.showsGuides }, set: { session.showsGuides = $0 }))
                                    .configuredKeyboardShortcut(";").disabled(session.document == nil)
                            }
                            Button(Localization.v("Grid Settings…")) { Task { await applicationDelegate.projects.gridSettings() } }
                                .disabled(session.document == nil)
                            Toggle(Localization.v("Rulers"), isOn: Binding(get: { session.showsRulers }, set: { session.showsRulers = $0 }))
                                .configuredKeyboardShortcut("r").disabled(session.document == nil)
                            Divider()
                            Toggle(Localization.v("Snap"), isOn: Binding(get: { session.snapEnabled }, set: { session.snapEnabled = $0 }))
                                .configuredKeyboardShortcut(";", modifiers: [.command, .shift]).disabled(session.document == nil)
                            Menu(Localization.v("Snap To")) {
                                Toggle(Localization.v("Guides"), isOn: Binding(get: { session.snapToGuides }, set: { session.snapToGuides = $0 }))
                                    .disabled(session.document == nil)
                                Toggle(Localization.v("Grid"), isOn: Binding(get: { session.snapToGrid }, set: { session.snapToGrid = $0 }))
                                    .disabled(session.document == nil)
                                Toggle(Localization.v("Layers"), isOn: Binding(get: { session.snapToLayers }, set: { session.snapToLayers = $0 }))
                                    .disabled(session.document == nil)
                                Toggle(Localization.v("Document Bounds"), isOn: Binding(get: { session.snapToDocumentBounds },
                                                                        set: { session.snapToDocumentBounds = $0 }))
                                    .disabled(session.document == nil)
                            }
                            Divider()
                            Toggle(Localization.v("Lock Guides"), isOn: Binding(get: { session.locksGuides }, set: { session.locksGuides = $0 }))
                                .configuredKeyboardShortcut(";", modifiers: [.command, .option]).disabled(session.document == nil)
                            Button(Localization.v("Clear Guides")) { session.clearGuides() }
                                .disabled(!session.canClearGuides)
                        }
                    }
                    // ⌘H toggles the Move tool's transform controls instead of hiding the app, so Hide keeps its
                    // place in the app menu without the shortcut.
                    CommandGroup(replacing: .appVisibility) {
                        Button(Localization.v("Hide Compositor")) { NSApp.hide(nil) }
                        Button(Localization.v("Hide Others")) { NSApp.hideOtherApplications(nil) }
                            .configuredKeyboardShortcut("h", modifiers: [.command, .option])
                        Button(Localization.v("Show All")) { NSApp.unhideAllApplications(nil) }
                    }
                }
                CommandGroup(replacing: .pasteboard) {
                    // Canvas pixels when the canvas has focus; text fields keep their own editing.
                    // Cut, Copy and Paste check when chosen rather than through .disabled: what they depend on
                    // (the pasteboard, the copied pixels, the busy flag) isn't observed, so a disabled state could
                    // go stale — the first Paste after a Copy used to beep until something else refreshed the menu.
                    Button(Localization.v("Cut")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                        else if session.selection != nil, session.canCopyPixels { Task { await session.cutSelection() } }
                        else { NSSound.beep() }
                    }
                        .configuredKeyboardShortcut("x")
                    Button(Localization.v("Copy")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                        else if session.canCopyPixels || session.canCopyLayer { session.copySelection() }
                        else { NSSound.beep() }
                    }
                        .configuredKeyboardShortcut("c")
                    Button(Localization.v("Copy Merged")) { session.copyMergedSelection() }
                        .configuredKeyboardShortcut("c", modifiers: [.command, .shift]).disabled(!session.canCopyMerged)
                    Button(Localization.v("Paste")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                        else if applicationDelegate.workspace.pasteCopiedLayer() { }
                        else if session.canPaste { session.paste() }
                        else { NSSound.beep() }
                    }
                        .configuredKeyboardShortcut("v")
                }
                CommandGroup(after: .pasteboard) {
                    Divider()
                    Button(Localization.v("Keyboard Shortcuts…")) { ShortcutSettings.shared.show() }
                    // Photoshop's fill shortcuts; in a text field they keep their text meaning.
                    Button(Localization.v("Fill with Foreground Color")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteWordBackward(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .foreground) } }
                    }
                        .configuredKeyboardShortcut(.delete, modifiers: .option).disabled(!session.canEditPixels)
                    Button(Localization.v("Fill with Background Color")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .background) } }
                    }
                        .configuredKeyboardShortcut(.delete, modifiers: .command).disabled(!session.canEditPixels)
                    Button(Localization.v("Clear Selection Pixels")) { Task { await session.clearSelectedPixels() } }
                        .disabled(session.selection == nil || !session.canEditPixels)
                    Button(Localization.v("Content-Aware Fill…")) { session.beginFilter(.contentAwareFill) }
                        .configuredKeyboardShortcut(.delete, modifiers: .shift).disabled(!session.canContentAwareFill)
                }
                CommandMenu(Localization.v("Select")) {
                    // A field being edited keeps its own Select All: offer it to the responder chain
                    // first, which covers every kind of text control rather than NSTextView alone,
                    // and select the canvas only when nothing there wanted it.
                    Button(Localization.v("All")) {
                        if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) { return }
                        guard session.document != nil else { return }
                        session.selectAll()
                    }
                        // Never disabled: on macOS this menu item is what binds Cmd-A to selectAll:, so
                        // switching it off takes Select All away from every text field too. With no
                        // document and nothing being edited the action simply does nothing.
                        .configuredKeyboardShortcut("a")
                    Button(Localization.v("Deselect")) { session.deselect() }
                        .configuredKeyboardShortcut("d").disabled(session.selection == nil || !session.canEditSelection)
                    Button(Localization.v("Inverse")) { session.invertSelection() }
                        .configuredKeyboardShortcut("i", modifiers: [.command, .shift])
                        .disabled(session.selection == nil || !session.canEditSelection)
                    Button(Localization.v("Layer's Pixels")) {
                        if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer?.asset == nil || !session.canEditSelection)
                    Button(Localization.v("Subject")) { Task { await session.selectSubject() } }
                        .configuredKeyboardShortcut("a", modifiers: [.command, .option])
                        .disabled(!session.canSelectSubject)
                    Button(Localization.v("Color Range…")) { session.beginColorRange() }
                        .disabled(!session.canSelectColorRange)
                    Button(Localization.v("Mask's Black Areas")) {
                        if let id = session.activeLayerID { session.loadMaskSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer?.mask == nil || !session.canEditSelection)
                    Divider()
                    Button(Localization.v("Expand…")) { session.promptSelectionAmount(.expand) }
                        .disabled(!session.canModifySelection)
                    Button(Localization.v("Contract…")) { session.promptSelectionAmount(.contract) }
                        .disabled(!session.canModifySelection)
                    Button(Localization.v("Feather…")) { session.promptSelectionAmount(.feather) }
                        .disabled(!session.canModifySelection)
                }
                CommandMenu(Localization.v("Image")) {
                    Button(Localization.v("Curves…")) { session.beginFilter(.curves) }
                        .configuredKeyboardShortcut("m").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(Localization.v("Levels…")) { session.beginLevels() }
                        .configuredKeyboardShortcut("l").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(Localization.v("Hue/Saturation…")) { session.beginHueSaturation() }
                        .configuredKeyboardShortcut("u").disabled(!session.canAdjustColors)
                    // Spelled out rather than a `ForEach` over the five kinds: inside a `Commands` builder a
                    // `ForEach` whose label is built from a localized string resolves to SwiftUI's `Binding`
                    // overload and fails to type-check, and there are only five.
                    Button(FilterKind.blackWhite.localizedName + "…") { session.beginFilter(.blackWhite) }
                        .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(FilterKind.colorBalance.localizedName + "…") { session.beginFilter(.colorBalance) }
                        .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(FilterKind.exposure.localizedName + "…") { session.beginFilter(.exposure) }
                        .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(FilterKind.gradientMap.localizedName + "…") { session.beginFilter(.gradientMap) }
                        .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(FilterKind.grain.localizedName + "…") { session.beginFilter(.grain) }
                        .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(session.isMaskSelected ? Localization.text("Invert Mask") : Localization.text("Invert")) { Task { await session.invertPixels() } }
                        .configuredKeyboardShortcut("i")
                        .disabled(!session.canInvert)
                    Divider()
                    Button(Localization.v("Canvas Size…")) { Task { await applicationDelegate.projects.canvasSize() } }
                        .configuredKeyboardShortcut("c", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(Localization.v("Image Size…")) { Task { await applicationDelegate.projects.imageSize() } }
                        .configuredKeyboardShortcut("i", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(Localization.v("Trim…")) { Task { await applicationDelegate.projects.trim() } }
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Group {
                        Divider()
                        Button(Localization.v("Flip Canvas Horizontal")) { session.flipCanvas(horizontally: true) }
                            .disabled(!session.canEditLayers)
                        Button(Localization.v("Flip Canvas Vertical")) { session.flipCanvas(horizontally: false) }
                            .disabled(!session.canEditLayers)
                    }
                }
                CommandMenu(Localization.v("Filter")) {
                    ForEach(FilterKind.allCases.filter { $0 != .contentAwareFill && !$0.isImageAdjustment }, id: \.self) { kind in
                        Button(kind.localizedName + "…") { session.beginFilter(kind) }
                            .disabled(!(kind == .vignette ? session.canVignette : session.canAdjustColors) || session.hueSaturation != nil)
                    }
                }
                CommandMenu(Localization.v("Layer")) {
                    Menu(Localization.v("New Adjustment Layer")) {
                        ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                            Button(kind.localizedName + (kind.isEditable ? "…" : "")) { session.addAdjustment(kind) }
                        }
                    }.disabled(!session.canEditLayers || session.document == nil)
                    Button(Localization.v("Edit Adjustment…")) {
                        session.adjustmentEditingID = session.activeLayerID
                    }.disabled(!session.canEditLayers || session.activeLayer?.adjustment == nil)
                    Divider()
                    Button(session.canTransformSelection ? Localization.text("Transform Selection") : Localization.text("Transform Layer")) { session.transformCommand() }
                        .configuredKeyboardShortcut("t").disabled(!session.canTransform && !session.canTransformSelection)
                    Button(session.selection == nil ? Localization.text("Duplicate Layer") : Localization.text("Layer via Copy")) { session.layerViaCopy() }
                        .configuredKeyboardShortcut("j").disabled(!session.canCopyPixels && !(session.selection == nil && session.canEditLayers && session.activeLayer != nil))
                    Divider()
                    Button(session.activeLayer?.maskSourceID == nil ? Localization.text("Create Clipping Mask") : Localization.text("Release Clipping Mask")) {
                        if let id = session.activeLayerID { session.toggleClippingMask(id) }
                    }
                    .configuredKeyboardShortcut("g", modifiers: [.command, .option])
                    .disabled(session.activeLayerID.map { !session.canToggleClippingMask($0) } ?? true)
                    Divider()
                    Button(Localization.v("Group Selected Layers")) { session.groupSelectedLayers() }
                        .configuredKeyboardShortcut("g").disabled(!session.canEditLayers)
                    Button(Localization.v("Ungroup Layers")) { session.ungroupLayers() }
                        .configuredKeyboardShortcut("g", modifiers: [.command, .shift]).disabled(!session.canUngroupLayers)
                    Button(Localization.v("Move Out of Folder")) { session.moveActiveLayerOutOfGroup() }
                        .disabled(!session.canEditLayers || session.activeLayer?.parentID == nil)
                    Button(Localization.v("New Blank Layer")) { session.addBlankLayer() }
                        .configuredKeyboardShortcut("n", modifiers: [.command, .shift]).disabled(!session.canEditLayers)
                    Button(Localization.v("Rename Layer…")) { session.renamingLayerID = session.activeLayerID }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                    Button(session.activeLayer?.isVisible == false ? Localization.text("Show Layer") : Localization.text("Hide Layer")) {
                        if let id = session.activeLayerID { session.toggleLayerVisibility(id) }
                    }.disabled(!session.canEditLayers || session.activeLayer == nil)
                    Divider()
                    Button(Localization.v("Move Layer Up")) { session.moveActiveLayer(by: 1) }
                        .configuredKeyboardShortcut("]").disabled(!session.canMoveActiveLayer(by: 1))
                    Button(Localization.v("Move Layer Down")) { session.moveActiveLayer(by: -1) }
                        .configuredKeyboardShortcut("[").disabled(!session.canMoveActiveLayer(by: -1))
                    Group {
                        Button(session.mergeTitle) { session.mergeLayers() }
                            .configuredKeyboardShortcut("e").disabled(!session.canMergeLayers)
                        Divider()
                        Button(Localization.v("Flip Layer Horizontal")) { session.flipLayers(horizontally: true) }
                            .disabled(!session.canTransform)
                        Button(Localization.v("Flip Layer Vertical")) { session.flipLayers(horizontally: false) }
                            .disabled(!session.canTransform)
                    }
                    Divider()
                    Button(session.selectedEffect != nil ? Localization.string("Delete %@", Localization.text(session.selectedEffect!.kind.displayName)) : session.isMaskSelected && session.activeLayer?.mask != nil ? Localization.text("Delete Layer Mask") : session.selectedLayerIDs.count > 1 ? Localization.text("Delete Layers") : Localization.text("Delete Layer")) {
                        session.deleteLayerOrMask()
                    }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                }
            }
    }
}
