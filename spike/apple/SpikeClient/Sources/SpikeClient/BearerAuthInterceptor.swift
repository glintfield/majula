import Connect

final class BearerAuthInterceptor: UnaryInterceptor, StreamInterceptor {
  private let token: String

  init(token: String) {
    self.token = token
  }

  @Sendable
  func handleUnaryRequest<Message: ProtobufMessage>(
    _ request: HTTPRequest<Message>,
    proceed: @escaping @Sendable (Result<HTTPRequest<Message>, ConnectError>) -> Void
  ) {
    proceed(.success(authorized(request)))
  }

  @Sendable
  func handleStreamStart(
    _ request: HTTPRequest<Void>,
    proceed: @escaping @Sendable (Result<HTTPRequest<Void>, ConnectError>) -> Void
  ) {
    proceed(.success(authorized(request)))
  }

  private func authorized<T>(_ request: HTTPRequest<T>) -> HTTPRequest<T> {
    var headers = request.headers
    headers["authorization"] = ["Bearer \(token)"]
    return HTTPRequest(
      url: request.url, headers: headers, message: request.message, method: request.method,
      trailers: request.trailers, idempotencyLevel: request.idempotencyLevel
    )
  }
}
