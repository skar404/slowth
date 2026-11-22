import SafariServices
import Foundation
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let raw: Any?
        if #available(iOS 17.0, macOS 14.0, *) {
            raw = request?.userInfo?[SFExtensionMessageKey]
        } else {
            raw = request?.userInfo?["message"]
        }

        let response = NSExtensionItem()
        let payload = (raw as? [String: Any]) ?? [:]
        let result = NativeExtensionMessageHandler.handle(payload: payload)

        if #available(iOS 17.0, macOS 14.0, *) {
            response.userInfo = [SFExtensionMessageKey: result]
        } else {
            response.userInfo = ["message": result]
        }

        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

}
