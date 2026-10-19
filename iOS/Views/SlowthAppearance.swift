import SwiftUI
import UIKit

enum SlowthAppearance {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.065, alpha: 1) : .systemGroupedBackground
    })
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.125, alpha: 1) : .secondarySystemGroupedBackground
    })
    static let sage = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.66, green: 0.81, blue: 0.62, alpha: 1)
            : UIColor(red: 0.27, green: 0.44, blue: 0.29, alpha: 1)
    })
}
