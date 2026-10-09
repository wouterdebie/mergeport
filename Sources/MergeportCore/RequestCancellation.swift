import Foundation

public enum RequestCancellation {
  public static func matches(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }
}
