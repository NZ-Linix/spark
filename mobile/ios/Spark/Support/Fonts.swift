import SwiftUI

extension Font {
  /** Geist at a size that still follows Dynamic Type. */
  static func geist(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: TextStyle = .body) -> Font {
    let name =
      switch weight {
      case .medium: "Geist-Medium"
      case .semibold: "Geist-SemiBold"
      case .bold, .heavy, .black: "Geist-Bold"
      default: "Geist-Regular"
      }
    return .custom(name, size: size, relativeTo: style)
  }

  static func geistMono(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: TextStyle = .body) -> Font {
    .custom(weight == .regular ? "GeistMono-Regular" : "GeistMono-Medium", size: size, relativeTo: style)
  }
}

extension UIFont {
  static func geist(_ size: CGFloat, _ name: String = "Geist-SemiBold") -> UIFont {
    UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
  }
}
