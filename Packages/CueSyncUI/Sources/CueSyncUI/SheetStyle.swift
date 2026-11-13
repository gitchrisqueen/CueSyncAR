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
#endif
