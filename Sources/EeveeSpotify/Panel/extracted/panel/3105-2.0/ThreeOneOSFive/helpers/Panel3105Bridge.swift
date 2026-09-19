import Combine
import Foundation
import UIKit

final class Panel3105Bridge: ObservableObject {
    enum Operation: String, Codable { case apply, inspectRestore, restore, resetToAppliedState }
    enum OperationState: String, Codable {
        case idle, sending, applying, completed, failed
        var displayName: String {
            switch self { case .idle: return ""; case .sending: return "enviando"; case .applying: return "aplicando"; case .completed: return "concluído"; case .failed: return "falhou" }
        }
    }
    struct Response: Codable {
        let requestID: UUID
        let projectID: UUID
        let state: OperationState
        let success: Bool
        let errorCode: String?
        let changedTargets: [String]
    }
    private struct Request: Codable {
        let requestID: UUID
        let projectData: Data
        let bundleID: String
        let operation: Operation
    }

    static let shared = Panel3105Bridge()
    @Published private(set) var states: [UUID: OperationState] = [:]
    private let requestType = "com.yangjiii.3105.panel-request"
    private let responsePrefix = "com.yangjiii.3105.panel-response."
    private let callbackScheme = "threeoneosfive"
    private init() {}

    func state(for projectID: UUID) -> OperationState { states[projectID] ?? .idle }

#if PANEL_HOST
    func send(projectData: Data, bundleID: String, operation: Operation, completion: @escaping (Response) -> Void) {
        guard let project = try? PropertyListDecoder().decode(PatchProject.self, from: projectData), project.allBundleIdentifiers.contains(bundleID) else {
            let id = (try? PropertyListDecoder().decode(PatchProject.self, from: projectData))?.id ?? UUID()
            let response = Response(requestID: UUID(), projectID: id, state: .failed, success: false, errorCode: "invalidProject", changedTargets: [])
            update(projectID: id, state: .failed); completion(response); return
        }
        let requestID = UUID()
        let request = Request(requestID: requestID, projectData: projectData, bundleID: bundleID, operation: operation)
        guard let requestData = try? PropertyListEncoder().encode(request) else {
            let response = Response(requestID: requestID, projectID: project.id, state: .failed, success: false, errorCode: "invalidProject", changedTargets: [])
            update(projectID: project.id, state: .failed); completion(response); return
        }
        update(projectID: project.id, state: .sending)
        UIPasteboard.general.setData(requestData, forPasteboardType: requestType)
        let callbackURL = URL(string: "\(callbackScheme)://panel3105/execute?id=\(requestID.uuidString)")!
        DispatchQueue.main.async {
            UIApplication.shared.open(callbackURL, options: [:]) { opened in
                guard opened else {
                    let response = Response(requestID: requestID, projectID: project.id, state: .failed, success: false, errorCode: "executorUnavailable", changedTargets: [])
                    self.update(projectID: project.id, state: .failed); completion(response); return
                }
                self.pollResponse(requestID: requestID, projectID: project.id, deadline: Date().addingTimeInterval(180), completion: completion)
            }
        }
    }

    private func pollResponse(requestID: UUID, projectID: UUID, deadline: Date, completion: @escaping (Response) -> Void) {
        let type = responsePrefix + requestID.uuidString
        if let data = UIPasteboard.general.data(forPasteboardType: type), let response = try? PropertyListDecoder().decode(Response.self, from: data) {
            update(projectID: projectID, state: response.state); completion(response); return
        }
        if Date() >= deadline {
            let response = Response(requestID: requestID, projectID: projectID, state: .failed, success: false, errorCode: "executorTimeout", changedTargets: [])
            update(projectID: projectID, state: .failed); completion(response); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.pollResponse(requestID: requestID, projectID: projectID, deadline: deadline, completion: completion) }
    }

    private func update(projectID: UUID, state: OperationState) { DispatchQueue.main.async { self.states[projectID] = state } }
#else
    func startReceiver() {}

    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == callbackScheme, url.host == "panel3105", url.path == "/execute",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              UUID(uuidString: id) != nil,
              let requestData = UIPasteboard.general.data(forPasteboardType: requestType),
              let request = try? PropertyListDecoder().decode(Request.self, from: requestData) else { return false }
        DispatchQueue.global(qos: .userInitiated).async { self.process(request) }
        return true
    }

    private func process(_ request: Request) {
        guard let project = try? PropertyListDecoder().decode(PatchProject.self, from: request.projectData), project.allBundleIdentifiers.contains(request.bundleID) else {
            publish(Response(requestID: request.requestID, projectID: UUID(), state: .failed, success: false, errorCode: "invalidProject", changedTargets: [])); return
        }
        publish(Response(requestID: request.requestID, projectID: project.id, state: .applying, success: false, errorCode: nil, changedTargets: []))
        do {
            try PatchPackageCodec.validate(project)
            switch request.operation {
            case .apply: _ = try DevicePatchService.apply(project: project)
            case .inspectRestore:
                let receipt = try requireReceipt(for: project.id)
                let inspection = try DevicePatchService.inspectRestore(receipt: receipt)
                publish(Response(requestID: request.requestID, projectID: project.id, state: .completed, success: true, errorCode: nil, changedTargets: inspection.changedTargets.map(\.displayPath))); return
            case .restore:
                try DevicePatchService.restore(receipt: try requireReceipt(for: project.id), allowChangedTargets: true)
            case .resetToAppliedState:
                try DevicePatchService.resetToAppliedState(receipt: try requireReceipt(for: project.id), project: project)
            }
            publish(Response(requestID: request.requestID, projectID: project.id, state: .completed, success: true, errorCode: nil, changedTargets: []))
        } catch let error as PatchPackageError {
            publish(Response(requestID: request.requestID, projectID: project.id, state: .failed, success: false, errorCode: error.localizationKey, changedTargets: []))
        } catch {
            publish(Response(requestID: request.requestID, projectID: project.id, state: .failed, success: false, errorCode: "operationFailed", changedTargets: []))
        }
    }

    private func requireReceipt(for projectID: UUID) throws -> PatchTransactionReceipt { guard let receipt = DevicePatchService.latestReceipt(projectID: projectID) else { throw PatchPackageError.restoreFailed }; return receipt }
    private func publish(_ response: Response) { guard let data = try? PropertyListEncoder().encode(response) else { return }; UIPasteboard.general.setData(data, forPasteboardType: responsePrefix + response.requestID.uuidString) }
#endif
}
