import Foundation

public class Favorites: ObservableObject {
  private let key = "favoriteResourceIDs"

  public init() {}

  func save(_ ids: Set<String>) {
    // It's a run-time exception if we pass the `Set` directly here
    UserDefaults.standard.set(Array(ids), forKey: key)
  }

  func load() -> Set<String> {
    if let ids = UserDefaults.standard.stringArray(forKey: key) {
      return Set(ids)
    }
    return []
  }

  func reset() {
    objectWillChange.send()
    save(Set())
  }

  func add(id: String) -> Set<String> {
    var ids = load()
    ids.insert(id)
    save(ids)
    return ids
  }

  func remove(id: String) -> Set<String> {
    var ids = load()
    ids.remove(id)
    save(ids)
    return ids
  }
}
