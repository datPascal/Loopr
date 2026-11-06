import Foundation

/// One non-streaming tool turn. The result is either the calls the model wants or its final text.
/// Tool turns do not stream. Chat and briefings keep streaming, and food photos keep structured output.
public protocol CoachAgentTransport: Sendable {
    func turn(_ request: CoachAgentRequest, key: String) async throws -> AgentTurn
}

extension CoachURLSessionTransport: CoachAgentTransport {
    public func turn(_ request: CoachAgentRequest, key: String) async throws -> AgentTurn {
        guard !requiresExplicitStub else { throw CoachStructuredError.unstubbedTest }
        var scope: AIRequestRecordingScope?
        var httpStatus: Int?
        do {
            let provider = request.configuration.provider
            var urlRequest = try Self.urlRequest(provider: provider, path: provider == .openAI ? "/v1/responses" : "/v1/messages", key: key)
            let body = try request.payload()
            urlRequest.httpMethod = "POST"; urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            scope = AIRequestRecordingScope(recorder: recorder, provider: provider, model: request.configuration.model,
                                            context: request.recording, body: body,
                                            toolCalls: request.recordedToolCalls, denials: request.recordedDenials)
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let response = response as? HTTPURLResponse, response.url == urlRequest.url else { throw CoachProviderError.malformedResponse }
            httpStatus = response.statusCode
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < CoachAgentDecoder.maxResponseBytes else { throw CoachProviderError.malformedResponse }
                data.append(byte)
            }
            guard (200..<300).contains(response.statusCode) else { throw CoachProviderError.response(status: response.statusCode, body: data) }
            guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true else {
                throw CoachProviderError.malformedResponse
            }
            let turn = try CoachAgentDecoder.decode(data, provider: provider)
            scope?.finish(.succeeded, httpStatus: httpStatus)
            return turn
        } catch let error as CoachStructuredError { scope?.finish(error: error, httpStatus: httpStatus); throw error }
        catch let error as CoachAgentError { scope?.finish(error: error, httpStatus: httpStatus); throw error }
        catch { scope?.finish(error: error, httpStatus: httpStatus); throw CoachProviderError.normalize(error) }
    }
}
