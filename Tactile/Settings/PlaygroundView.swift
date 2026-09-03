//
//  PlaygroundView.swift
//  Tactile
//
//  A canvas of real controls to hover while tuning. These are ordinary
//  SwiftUI controls, so the actual pipeline - accessibility hit-testing and
//  all - is what makes them tick.
//
//  Deliberately NOT built with Form/List: SwiftUI collapses buttons inside a
//  List row into inert groups, so only the row would tick, not the buttons.
//  A plain ScrollView/VStack keeps every control's real accessibility role,
//  which is the whole point of a playground.
//

import SwiftUI

struct PlaygroundView: View {
    @EnvironmentObject private var localization: LocalizationController
    @State private var checkedOn = true
    @State private var checkedOff = false
    @State private var sliderValue = 0.4
    @State private var text = ""
    @State private var pickedTab = "One"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                card(
                    titleKey: "settings.playground.buttons.title",
                    noteKey: "settings.playground.buttons.note"
                ) {
                    HStack(spacing: 12) {
                        Button("settings.playground.buttons.button") {}
                        Button("settings.playground.buttons.delete") {}
                        Button("settings.playground.buttons.disabled") {}.disabled(true)
                        Link("settings.playground.buttons.link", destination: URL(string: "https://example.com")!)
                    }
                }

                card(
                    titleKey: "settings.playground.state.title",
                    noteKey: "settings.playground.state.note"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("settings.playground.state.checked-checkbox", isOn: $checkedOn)
                            .toggleStyle(.checkbox)
                        Toggle("settings.playground.state.unchecked-checkbox", isOn: $checkedOff)
                            .toggleStyle(.checkbox)
                        Toggle("settings.playground.state.switch", isOn: $checkedOn)
                            .toggleStyle(.switch)
                        Picker("settings.playground.state.tabs", selection: $pickedTab) {
                            Text("settings.playground.state.tab-one").tag("One")
                            Text("settings.playground.state.tab-two").tag("Two")
                            Text("settings.playground.state.tab-three").tag("Three")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }

                card(
                    titleKey: "settings.playground.other-elements.title",
                    noteKey: "settings.playground.other-elements.note"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Slider(value: $sliderValue) { Text("settings.playground.other-elements.slider") }
                            .frame(width: 260)
                        TextField("settings.playground.other-elements.text-field", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                        Menu("settings.playground.other-elements.menu") {
                            Button("settings.playground.other-elements.first") {}
                            Button("settings.playground.other-elements.second") {}
                        }
                        .frame(width: 160)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A titled, softly-boxed group - the visual grouping a Form gave us,
    /// without the List that breaks the controls' accessibility.
    private func card<Content: View>(
        titleKey: LocalizedStringKey,
        noteKey: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titleKey)
                .font(.headline)
            content()
            Text(noteKey)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
