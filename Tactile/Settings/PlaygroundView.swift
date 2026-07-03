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
    @State private var checkedOn = true
    @State private var checkedOff = false
    @State private var sliderValue = 0.4
    @State private var text = ""
    @State private var pickedTab = "One"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                card("Buttons", note: "“Delete” plays the danger waveform; “Disabled” is felt only if Feel Disabled Controls is on.") {
                    HStack(spacing: 12) {
                        Button("Button") {}
                        Button("Delete") {}
                        Button("Disabled") {}.disabled(true)
                        Link("A link", destination: URL(string: "https://example.com")!)
                    }
                }

                card("State", note: "With state awareness on, the checked box and the selected tab add a confirmation pulse.") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("A checked checkbox", isOn: $checkedOn)
                            .toggleStyle(.checkbox)
                        Toggle("An unchecked checkbox", isOn: $checkedOff)
                            .toggleStyle(.checkbox)
                        Toggle("A switch", isOn: $checkedOn)
                            .toggleStyle(.switch)
                        Picker("Tabs", selection: $pickedTab) {
                            Text("One").tag("One")
                            Text("Two").tag("Two")
                            Text("Three").tag("Three")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }

                card("Other Elements", note: "Sliders and text fields are off by default. Turn them on in Haptics to feel these.") {
                    VStack(alignment: .leading, spacing: 12) {
                        Slider(value: $sliderValue) { Text("A slider") }
                            .frame(width: 260)
                        TextField("A text field", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                        Menu("A pop-up menu") {
                            Button("First") {}
                            Button("Second") {}
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
    private func card<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
