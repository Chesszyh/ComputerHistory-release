import Foundation
import Security

// This executable deliberately has no dependency on the activity collector or its business logic.
// Installation retains this executable while the protocol is unchanged. Bump it for helper fixes requiring replacement.
let version = "1"
if CommandLine.arguments.contains("--protocol-version") { print(version); exit(0) }
var response: [String: Any] = [:]
do {
    try CredentialStore.configureInteraction(allow: false)
    let bytes = FileHandle.standardInput.readDataToEndOfFile()
    guard let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          let operation = request["operation"] as? String,
          let rootPath = request["root"] as? String else {
        throw NSError(domain: "CredentialRequest", code: 1, userInfo: [NSLocalizedDescriptionKey: "密钥请求格式无效。"])
    }
    let root = URL(fileURLWithPath: rootPath)
    let group = request["groupID"] as? String
    let fallback = request["fallback"] as? Bool ?? false
    // Only the explicit recovery action may display system authentication UI.
    if operation == "authorize" { try CredentialStore.configureInteraction(allow: true) }
    switch operation {
    case "contains": response["exists"] = try CredentialStore.contains(root: root, fallback: fallback, groupID: group)
    case "load", "authorize":
        let key = try CredentialStore.load(root: root, fallback: fallback, groupID: group)
        response["exists"] = key != nil
        if operation == "load" { response["key"] = key }
    case "save":
        guard let key = request["key"] as? String, !key.isEmpty else {
            throw NSError(domain: "CredentialRequest", code: 2, userInfo: [NSLocalizedDescriptionKey: "密钥不能为空。"])
        }
        try CredentialStore.save(key, root: root, fallback: fallback, groupID: group)
    case "remove": try CredentialStore.remove(root: root, fallback: fallback, groupID: group)
    default: throw NSError(domain: "CredentialRequest", code: 3, userInfo: [NSLocalizedDescriptionKey: "未知密钥操作。"])
    }
    response["ok"] = true
} catch {
    response = ["ok": false, "error": String(describing: error)]
}
let output = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
FileHandle.standardOutput.write(output)
exit(response["ok"] as? Bool == true ? 0 : 1)
