import Foundation

public class Favorites: ObservableObject {
  private static let key = "favoriteResourceIDs"
  @Published private(set) var ids: Set<String> = Favorites.load()

  public init() {}

  func contains(_ id: String) -> Bool {
    return ids.contains(id)
  }

  func reset() {
    objectWillChange.send()
    ids = Set()
    Favorites.save(ids)
  }

  func add(_ id: String) {
    objectWillChange.send()
    ids.insert(id)
    Favorites.save(ids)
  }

  func remove(_ id: String) {
    objectWillChange.send()
    ids.remove(id)
    Favorites.save(ids)
  }

  private static func save(_ ids: Set<String>) {
    // It's a run-time exception if we pass the `Set` directly here
    UserDefaults.standard.set(Array(ids), forKey: key)
  }

  private static func load() -> Set<String> {
    if let ids = UserDefaults.standard.stringArray(forKey: key) {
      return Set(ids)
    }
    return []
  }
}
