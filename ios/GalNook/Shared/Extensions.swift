import SwiftUI

extension View {
    func navigationBarTitleDisplayModeLarge() -> some View {
        navigationBarTitleDisplayMode(.large)
    }

    func errorAlert(message: Binding<String?>) -> some View {
        alert("提示", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("好") { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "未知错误")
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var strippingHTML: String {
        guard let data = data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
