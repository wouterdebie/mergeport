import Foundation
import Testing
@testable import MergeportCore

struct RequestCancellationTests {
  @Test func swiftAndURLSessionCancellationsAreRecognized() {
    #expect(RequestCancellation.matches(CancellationError()))
    #expect(RequestCancellation.matches(URLError(.cancelled)))
    #expect(RequestCancellation.matches(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
  }

  @Test func realErrorsAndWorkflowCancellationRemainVisible() {
    #expect(!RequestCancellation.matches(URLError(.timedOut)))
    #expect(!RequestCancellation.matches(URLError(.notConnectedToInternet)))
    #expect(!RequestCancellation.matches(MergeportError.message("cancelled")))
    #expect(!RequestCancellation.matches(NSError(domain: "Other", code: NSURLErrorCancelled)))
    #expect(PullRequestCheck(id: "cancelled", name: "Tests", state: "cancelled", url: nil).outcome == .failing)
  }
}
