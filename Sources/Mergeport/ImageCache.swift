import AppKit
import SwiftUI

/// Avatars repeat across cards, timelines and sidebars. Keep decoded images in memory and
/// responses on disk so scrolling never refetches or flashes a placeholder.
@MainActor
final class ImageCache {
  static let shared = ImageCache()

  private let memory = NSCache<NSURL, NSImage>()
  private var inFlight: [URL: Task<NSImage?, Never>] = [:]
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Mergeport/Images", isDirectory: true)
    configuration.urlCache = URLCache(
      memoryCapacity: 8 << 20, diskCapacity: 100 << 20, directory: directory)
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    return URLSession(configuration: configuration)
  }()

  private init() { memory.countLimit = 500 }

  func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

  func image(for url: URL) async -> NSImage? {
    if let image = cached(url) { return image }
    if let task = inFlight[url] { return await task.value }
    let session = session
    let task = Task<NSImage?, Never>.detached(priority: .utility) {
      guard let (data, response) = try? await session.data(from: url),
        (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
        let image = NSImage(data: data)
      else { return nil }
      return image
    }
    inFlight[url] = task
    let image = await task.value
    inFlight[url] = nil
    if let image { memory.setObject(image, forKey: url as NSURL) }
    return image
  }

  /// GitHub serves avatars at any size; ask for what we draw (at 2x) instead of the full image.
  static func sized(_ url: URL, points: CGFloat) -> URL {
    guard url.host?.hasSuffix("githubusercontent.com") == true,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    let pixels = Int((points * 2).rounded(.up))
    var items = (components.queryItems ?? []).filter { $0.name != "s" }
    items.append(URLQueryItem(name: "s", value: String(pixels)))
    components.queryItems = items
    return components.url ?? url
  }
}

/// Like AsyncImage, but backed by ImageCache so recreated views show the image immediately.
struct CachedImage<Placeholder: View>: View {
  let url: URL
  @ViewBuilder let placeholder: () -> Placeholder
  @State private var image: NSImage?

  init(url: URL, @ViewBuilder placeholder: @escaping () -> Placeholder) {
    self.url = url
    self.placeholder = placeholder
    _image = State(initialValue: ImageCache.shared.cached(url))
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
      } else {
        placeholder()
      }
    }
    .task(id: url) {
      if image == nil || ImageCache.shared.cached(url) !== image {
        image = await ImageCache.shared.image(for: url)
      }
    }
  }
}
