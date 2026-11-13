//
//  SheetStyle.swift
//  CueSyncUI
//
//  Text for the More and Settings sheets' section headers and footnotes.
//  The system secondary grey measured 3.29 : 1 on the grouped background
//  (the independent re-score); these are the same quiet grey at 4.5 : 1 or
//  better, in both appearances (SheetStyleTests).
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension Theme {
    /// The footnote / header grey, adapting to light and dark.
    public static var sheetSecondary: Color {
        #if canImport(UIKit)
        Color(UIColor { traits in
            let token = traits.userInterfaceStyle == .dark ? sheetSecondaryDark : sheetSecondaryLight
            return UIColor(red: token.red, green: token.green, blue: token.blue, alpha: 1)
        })
        #else
        sheetSecondaryLight.color
        #endif
    }
}

/// A section footnote.
public struct SheetFootnote: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text).foregroundStyle(Theme.sheetSecondary)
    }
}

/// A section header.
public struct SheetHeader: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text).foregroundStyle(Theme.sheetSecondary)
    }
}

/// A picker row whose current value is readable. The system picker draws the
/// value in the secondary grey, which measured 3.4 : 1 ("Open") and 4.0 : 1
/// ("Medium") on the row; this draws it in `Theme.sheetSecondary`, at least
/// 4.5 : 1 on the row in both appearances. It behaves as the menu picker
/// does: a tap opens the same list with a check on the current one.
public struct SheetPickerRow<Value: Hashable>: View {
    private let title: String
    private let selection: Binding<Value>
    private let options: [(value: Value, title: String)]

    public init(_ title: String, selection: Binding<Value>,
                options: [(value: Value, title: String)]) {
        self.title = title
        self.selection = selection
        self.options = options
    }

    private var currentTitle: String {
        options.first { $0.value == selection.wrappedValue }?.title ?? ""
    }

    public var body: some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title).tag(options[index].value)
                }
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(currentTitle).foregroundStyle(Theme.sheetSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.sheetSecondary)
            }
            .contentShape(Rectangle())
        }
        // A menu tints its label with the accent; the row's own text is
        // primary, as the system picker draws it.
        .tint(.primary)
        .accessibilityLabel(title)
        .accessibilityValue(currentTitle)
    }
}
#endif
