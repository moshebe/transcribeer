import SwiftUI

struct ModelSelectionField: View {
    @Binding var selection: String
    let models: [String]
    let onSubmit: () -> Void

    var body: some View {
        HStack {
            TextField("Model", text: $selection)
                .onSubmit(onSubmit)
            Menu("Choose…") {
                ForEach(models, id: \.self) { model in
                    Button(model) { selection = model }
                }
            }
            .fixedSize()
            .disabled(models.isEmpty)
            .accessibilityLabel("Choose model")
            .help("Choose a model, or type a custom model name in the field.")
        }
    }
}
