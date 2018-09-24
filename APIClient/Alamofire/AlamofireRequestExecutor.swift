import Foundation
import Alamofire

public protocol Cancelable {
    func cancel()
}

public enum AlamofireExecutorError: Error {
    case canceled
    case connection
    case unauthorized
    case internalServer
    case undefined
}

open class AlamofireRequestExecutor: RequestExecutor {
    
    open let manager: SessionManager
    open let baseURL: URL
    
    public init(baseURL: URL, manager: SessionManager = SessionManager.default) {
        self.manager = manager
        self.baseURL = baseURL
    }
    
    public func execute(request: APIRequest, completion: @escaping APIResultResponse) -> Cancelable {
        let cancellationSource = CancellationTokenSource()
        let requestPath = path(for: request)
        let request = manager
            .request(
                requestPath,
                method: request.alamofireMethod,
                parameters: request.parameters,
                encoding: request.alamofireEncoding,
                headers: request.headers    
            )
            .response { response in
                guard let httpResponse = response.response, let data = response.data else {
                    AlamofireRequestExecutor.defineError(response.error, completion: completion)
                    return
                }
                completion(.success((httpResponse, data)))
        }
        
        cancellationSource.token.register {
            request.cancel()
        }
        
        return cancellationSource
    }
    
    public func execute(downloadRequest: APIRequest, destinationPath: URL?, completion: @escaping APIResultResponse) -> Cancelable {
        let cancellationSource = CancellationTokenSource()
        let requestPath = path(for: downloadRequest)
        
        var request = manager.download(
            requestPath,
            method: downloadRequest.alamofireMethod,
            parameters: downloadRequest.parameters,
            encoding: downloadRequest.alamofireEncoding,
            headers: downloadRequest.headers,
            to: destination(for: destinationPath)
        )
        
        if let progressHandler = downloadRequest.progressHandler {
            request = request.downloadProgress { progress in
                progressHandler(progress)
            }
        }
        
        request.responseData { response in
            guard let httpResponse = response.response, let data = response.result.value else {
                AlamofireRequestExecutor.defineError(response.error, completion: completion)
                return
            }
            
            completion(.success((httpResponse, data)))
        }
        
        cancellationSource.token.register {
            request.cancel()
        }
        
        return cancellationSource
    }
    
    public func execute(multipartRequest: APIRequest, completion: @escaping APIResultResponse) -> Cancelable {
        guard let multipartFormData = multipartRequest.multipartFormData else {
            fatalError("Missing multipart form data")
        }
        
        let cancellationSource = CancellationTokenSource()
        let requestPath = path(for: multipartRequest)
        
        manager
            .upload(
                multipartFormData: multipartFormData,
                to: requestPath,
                method: multipartRequest.alamofireMethod,
                headers: multipartRequest.headers,
                encodingCompletion: { encodingResult in
                    switch encodingResult {
                    case .success(var request, _, _):
                        cancellationSource.token.register {
                            request.cancel()
                        }
                        
                        if let progressHandler = multipartRequest.progressHandler {
                            request = request.uploadProgress { progress in
                                progressHandler(progress)
                            }
                        }
                        request.responseJSON(completionHandler: { response in
                            guard let httpResponse = response.response, let data = response.data else {
                                AlamofireRequestExecutor.defineError(response.error, completion: completion)
                                return
                            }
                            
                            completion(.success((httpResponse, data)))
                        })
                        
                    case .failure(let error):
                        completion(.failure(error))
                    }
            })
        
        return cancellationSource
    }
    
    private func path(for request: APIRequest) -> String {
        return baseURL
            .appendingPathComponent(request.path)
            .absoluteString
            .removingPercentEncoding!
    }
    
    private func destination(for url: URL?) -> DownloadRequest.DownloadFileDestination? {
        guard let url = url else {
            return nil
        }
        let destination: DownloadRequest.DownloadFileDestination = { _, _ in
            return (url, [.removePreviousFile, .createIntermediateDirectories])
        }
        
        return destination
    }
    
    private class func defineError(_ error: Error?, completion: @escaping APIResultResponse) {
        guard let error = error else {
            completion(.failure(AlamofireExecutorError.undefined))
            return
        }
        
        switch (error as NSError).code {
        case NSURLErrorCancelled:
            completion(.failure(AlamofireExecutorError.canceled))
        case NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut:
            completion(.failure(AlamofireExecutorError.connection))
        case 401:
            completion(.failure(AlamofireExecutorError.unauthorized))
        case 500:
            completion(.failure(AlamofireExecutorError.internalServer))
        default:
            completion(.failure(error))
        }
    }
    
}

extension Alamofire.MultipartFormData: MultipartFormDataType {}
