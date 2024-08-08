import Foundation

struct Favorites {
  private static let key = "favoriteResourceIDs"

  static func save(_ ids: Set<String>) {
    // It's a run-time exception if we pass the `Set` directly here
    UserDefaults.standard.set(Array(ids), forKey: key)
  }

  static func load() -> Set<String> {
    if let ids = UserDefaults.standard.stringArray(forKey: key) {
      return Set(ids)
    }
    return []
  }

  static func add(id: String) -> Set<String> {
    var ids = load()
    ids.insert(id)
    save(ids)
    return ids
  }

  static func remove(id: String) -> Set<String> {
    var ids = load()
    ids.remove(id)
    save(ids)
    return ids
  }
}
