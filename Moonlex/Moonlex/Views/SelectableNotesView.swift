import SwiftUI
import UIKit

/// `UITextView` that wraps to the view width so SwiftUI can measure height correctly in a `ScrollView`.
private final class WrappingNotesTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        layoutManager.ensureLayout(for: textContainer)
        var h = layoutManager.usedRect(for: textContainer).height
        h += textContainerInset.top + textContainerInset.bottom
        return CGSize(width: UIView.noIntrinsicMetric, height: max(ceil(h), 1))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        if w > 0 {
            let next = CGSize(width: w, height: .greatestFiniteMagnitude)
            if textContainer.size != next {
                textContainer.size = next
            }
        }
        invalidateIntrinsicContentSize()
    }
}

final class NotesSelectionReader: ObservableObject {
    init() {}

    weak var textView: UITextView?

    var selectedExcerpt: String? {
        guard let tv = textView else { return nil }
        let r = tv.selectedRange
        guard r.length > 0, let t = tv.text else { return nil }
        let sub = (t as NSString).substring(with: r)
        return sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sub
    }
}

struct SelectableNotesView: UIViewRepresentable {
    let text: String
    @ObservedObject var reader: NotesSelectionReader

    func makeUIView(context: Context) -> UITextView {
        let tv = WrappingNotesTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.text = text
        reader.textView = tv
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        reader.textView = uiView
    }
}
