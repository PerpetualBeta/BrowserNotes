import SwiftUI

struct BrowserNotesSettingsContent: View {
    let delegate: AppDelegate

    var body: some View {
        Section("Behaviour") {
            Toggle("Enable Browser Notes", isOn: Binding(
                get: { delegate.engine.isEnabled },
                set: { delegate.engine.isEnabled = $0 }
            ))
        }

        Section("Shortcuts") {
            JorvikShortcutRecorder(
                label: "Add Note",
                keyCode: Binding(
                    get: { delegate.addNoteKeyCode },
                    set: { delegate.addNoteKeyCode = $0 }
                ),
                modifiers: Binding(
                    get: { delegate.addNoteModifiers },
                    set: { delegate.addNoteModifiers = $0 }
                ),
                displayString: { delegate.addNoteShortcutDisplayString() },
                onChanged: nil,
                eventTapToDisable: nil
            )

            JorvikShortcutRecorder(
                label: "Notes Browser",
                keyCode: Binding(
                    get: { delegate.notesBrowserKeyCode },
                    set: { delegate.notesBrowserKeyCode = $0 }
                ),
                modifiers: Binding(
                    get: { delegate.notesBrowserModifiers },
                    set: { delegate.notesBrowserModifiers = $0 }
                ),
                displayString: { delegate.notesBrowserShortcutDisplayString() },
                onChanged: nil,
                eventTapToDisable: nil
            )
        }

        Section("Permissions") {
            HStack {
                Text("Accessibility")
                Spacer()
                if AXIsProcessTrusted() {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button("Grant Access") {
                        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
                        AXIsProcessTrustedWithOptions(opts)
                    }
                    .font(.caption)
                }
            }
        }

        MenuBarPillSettings {
            delegate.refreshPill()
        }
    }
}
