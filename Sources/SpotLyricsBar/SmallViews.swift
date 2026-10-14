import SwiftUI

struct LabelText: View {
    let label: String
    let text: String
    let color: Color

    init(_ label: String, _ text: String, color: Color = SpotifyDesign.secondaryText) {
        self.label = label
        self.text = text
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SpotifyDesign.primaryText.opacity(0.9))
            Text(text)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
