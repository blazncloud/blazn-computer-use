import SwiftUI

// A virtualized list of 500 rows. SwiftUI List lazily realizes only the rows
// in (or near) the viewport, so the AX tree exposes a small windowed subset at
// any scroll position — exactly the dense-collection viewport-windowing case
// the truth suite exercises. Row labels are zero-padded ("Row 001" ..
// "Row 500") so ordering is lexicographically stable and each row is uniquely
// addressable.
struct RowListPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Virtualized List (500 rows)").font(.headline)
            List(1...500, id: \.self) { i in
                let label = String(format: "Row %03d", i)
                Text(label)
                    .accessibilityLabel(label)
            }
            .frame(width: 300, height: 300)
            .accessibilityLabel("row-list")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }
}
