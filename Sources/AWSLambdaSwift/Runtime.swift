import Dispatch
import Foundation

import SwiftyRequest

public func log(_ object: Any, flush: Bool = false) {
    fputs("\(object)\n", stderr)
    if flush {
        fflush(stderr)
    }
}

public typealias JSONDictionary = [String: Any]

struct InvocationError: Codable {
    let errorMessage: String
}

public class Runtime {
    let awsLambdaRuntimeAPI: String
    let handlerName: String
    var handlers: [String: Handler]

    public init() throws {
        self.handlers = [:]

        let environment = ProcessInfo.processInfo.environment
        guard let awsLambdaRuntimeAPI = environment["AWS_LAMBDA_RUNTIME_API"],
            let handler = environment["_HANDLER"] else {
            throw RuntimeError.missingEnvironmentVariables
        }

        guard let periodIndex = handler.firstIndex(of: ".") else {
            throw RuntimeError.invalidHandlerName
        }

        self.awsLambdaRuntimeAPI = awsLambdaRuntimeAPI
        self.handlerName = String(handler[handler.index(after: periodIndex)...])
    }

    func getNextInvocation() throws -> (inputData: Data, responseHeaderFields: [AnyHashable: Any]) {
        
        let request = RestRequest(method: .get,
                                  url: "http://\(awsLambdaRuntimeAPI)/2018-06-01/runtime/invocation/next")
        
        let dispatch = DispatchSemaphore(value: 0)
        
        var error: RuntimeError? = nil
        var data: Data? = nil
        var headers: [String: Any] = [:]
        
        request.responseData { (result) in
            switch result {
            case .success(let success):
                
                data = success.body
                
                for (h, v) in success.headers {
                    headers[h] = v
                }
                
            case .failure(let failure):
                error = RuntimeError.endpointError(failure.localizedDescription)
            }
            dispatch.signal()
        }
        
        dispatch.wait()
        
        if let error = error {
            throw error
        }
        
        if let data = data {
            return (inputData: data, responseHeaderFields: headers)
        }
        
        throw RuntimeError.missingData
    }

    func postInvocationResponse(for requestId: String, httpBody: Data) {
        
        let request = RestRequest(method: .post,
                                  url: "http://\(awsLambdaRuntimeAPI)/2018-06-01/runtime/invocation/\(requestId)/response")
        request.messageBody = httpBody
        request.response { resp in
            print(resp)
        }
    }

    func postInvocationError(for requestId: String, error: Error) {
        let errorMessage = String(describing: error)
        let invocationError = InvocationError(errorMessage: errorMessage)
        let jsonEncoder = JSONEncoder()
        let httpBody = try! jsonEncoder.encode(invocationError)

        let request = RestRequest(method: .post,
                                  url: "http://\(awsLambdaRuntimeAPI)/2018-06-01/runtime/invocation/\(requestId)/error")
        request.messageBody = httpBody
        
        request.response { resp in
            print(resp)
        }
    }

    public func registerLambda(_ name: String, handlerFunction: @escaping (JSONDictionary, Context) throws -> JSONDictionary) {
        let handler = JSONSyncHandler(handlerFunction: handlerFunction)
        handlers[name] = .sync(handler)
    }

    public func registerLambda(_ name: String,
                               handlerFunction: @escaping (JSONDictionary, Context, @escaping (JSONDictionary) -> Void) -> Void) {
        let handler = JSONAsyncHandler(handlerFunction: handlerFunction)
        handlers[name] = .async(handler)
    }

    public func registerLambda<Input: Decodable, Output: Encodable>(_ name: String, handlerFunction: @escaping (Input, Context) throws -> Output) {
        let handler = CodableSyncHandler(handlerFunction: handlerFunction)
        handlers[name] = .sync(handler)
    }

    public func registerLambda<Input: Decodable, Output: Encodable>(_ name: String,
                                                                    handlerFunction: @escaping (Input, Context, @escaping (Output) -> Void) -> Void) {
        let handler = CodableAsyncHandler(handlerFunction: handlerFunction)
        handlers[name] = .async(handler)
    }

    public func start() throws {
        var counter = 0

        while true {
            let (inputData, responseHeaderFields) = try getNextInvocation()
            counter += 1
            log("Invocation-Counter: \(counter)")

            guard let handler = handlers[handlerName] else {
                throw RuntimeError.unknownLambdaHandler
            }

            if let lambdaRuntimeTraceId = responseHeaderFields["Lambda-Runtime-Trace-Id"] as? String {
                setenv("_X_AMZN_TRACE_ID", lambdaRuntimeTraceId, 0)
            }

            let environment = ProcessInfo.processInfo.environment
            let context = Context(environment: environment, responseHeaderFields: responseHeaderFields)
            let result = handler.apply(inputData: inputData, context: context)

            switch result {
            case .success(let outputData):
                postInvocationResponse(for: context.awsRequestId, httpBody: outputData)
            case .failure(let error):
                postInvocationError(for: context.awsRequestId, error: error)
            }
        }
    }
}
