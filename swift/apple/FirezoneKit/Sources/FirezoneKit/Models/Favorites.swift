import Foundation

public final class Favorites: ObservableObject {
  private static let key = "favoriteResourceIDs"
  private var ids: Set<String>

  public init() {
    ids = Favorites.load()
  }

  func contains(_ id: String) -> Bool {
    return ids.contains(id)
  }

  func reset() {
    objectWillChange.send()
    ids = Set()
    save()
  }

  func add(_ id: String) {
    objectWillChange.send()
    ids.insert(id)
    save()
  }

  func remove(_ id: String) {
    objectWillChange.send()
    ids.remove(id)
    save()
  }

  func isEmpty() -> Bool {
    return ids.isEmpty
  }

  // swiftlint:disable no_userdefaults_standard - standalone model, not DI-managed
  private func save() {
    // It's a run-time exception if we pass the `Set` directly here
    let ids = Array(ids)
    UserDefaults.standard.set(ids, forKey: Favorites.key)
  }

  private static func load() -> Set<String> {
    if let ids = UserDefaults.standard.stringArray(forKey: key) {
      // swiftlint:enable no_userdefaults_standard
      return Set(ids)
    }
    return []
  }
}
