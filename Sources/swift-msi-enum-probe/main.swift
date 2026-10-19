// Finds where each Swift toolchain, SDK and runtime lives using only the
// Windows Installer registration: no cached .msi, no hard-coded component GUIDs.
//
// Usage: swift-msi-enum-probe

import CMsi

let ERROR_MORE_DATA: UInt32 = 234
let ERROR_NO_MORE_ITEMS: UInt32 = 259

// MARK: - Wide string helpers

func withWide<R>(_ s: String?, _ body: (UnsafePointer<MsiChar>?) -> R) -> R {
  guard let s else { return body(nil) }
  return s.withCString(encodedAs: UTF16.self) { body($0) }
}

func string(from buffer: [MsiChar]) -> String {
  String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
}

/// Calls an MSI "fill this buffer" API, growing the buffer on ERROR_MORE_DATA.
func readString(_ call: (UnsafeMutablePointer<MsiChar>, UnsafeMutablePointer<UInt32>) -> UInt32) -> String? {
  var capacity: UInt32 = 256
  while true {
    var buffer = [MsiChar](repeating: 0, count: Int(capacity))
    var length = capacity
    let result = call(&buffer, &length)
    if result == ERROR_MORE_DATA { capacity = length + 1; continue }
    return result == 0 ? string(from: buffer) : nil
  }
}

/// Drives one of the MsiEnum*ExW APIs, which all return a GUID, a context and a SID per index.
func enumerate(_ call: (UInt32, UnsafeMutablePointer<MsiChar>, UnsafeMutablePointer<Int32>,
                        UnsafeMutablePointer<MsiChar>, UnsafeMutablePointer<UInt32>) -> UInt32)
  -> [(code: String, context: Int32, sid: String?)] {
  var items: [(code: String, context: Int32, sid: String?)] = []
  var index: UInt32 = 0
  while true {
    var code = [MsiChar](repeating: 0, count: 39)
    var context = Int32(MSI_CONTEXT_NONE)
    var sid = [MsiChar](repeating: 0, count: 256)
    var sidLength: UInt32 = 256
    let result = call(index, &code, &context, &sid, &sidLength)
    if result == ERROR_NO_MORE_ITEMS { break }
    if result != 0 {
      print("warning: enumeration failed at index \(index) with error \(result)")
      break
    }
    let sidString = string(from: sid)
    items.append((string(from: code), context, sidString.isEmpty ? nil : sidString))
    index += 1
  }
  return items
}

// MARK: - Products

struct Product {
  let code: String
  let context: Int32
  let sid: String?

  func info(_ property: String) -> String? {
    readString { buffer, length in
      withWide(code) { code in
        withWide(sid) { sid in
          withWide(property) { property in
            MsiGetProductInfoExW(code, sid, context, property, buffer, length)
          }
        }
      }
    }
  }

  var name: String { info("ProductName") ?? "?" }
  var version: String { info("VersionString") ?? "?" }
  var publisher: String { info("Publisher") ?? "" }

  /// Full path of the key file (or key folder) of `componentId`, if it's installed locally.
  func componentPath(_ componentId: String) -> String? {
    var capacity: UInt32 = 512
    while true {
      var buffer = [MsiChar](repeating: 0, count: Int(capacity))
      var length = capacity
      let state = withWide(code) { code in
        withWide(componentId) { component in
          withWide(sid) { sid in
            MsiGetComponentPathExW(code, component, sid, context, &buffer, &length)
          }
        }
      }
      if state == MSI_INSTALLSTATE_MOREDATA { capacity = length + 1; continue }
      return state == MSI_INSTALLSTATE_LOCAL ? string(from: buffer) : nil
    }
  }
}

/// Every product visible to the current user: their per-user installs plus per-machine ones.
func installedProducts() -> [Product] {
  enumerate { index, code, context, sid, sidLength in
    MsiEnumProductsExW(nil, nil, UInt32(MSI_CONTEXT_ALL), index, code, context, sid, sidLength)
  }.map { Product(code: $0.code, context: $0.context, sid: $0.sid) }
}

/// Paths of every locally installed component that belongs to one of `products`.
/// Windows Installer has no "components of this product" API, so walk the registered
/// components once and ask which products use them. Only the install contexts the
/// products live in are walked: a per-user Swift install skips every per-machine component.
func installedPaths(of products: [String: Product]) -> [String: [String]] {
  var paths: [String: [String]] = [:]
  let contexts = products.values.reduce(UInt32(0)) { $0 | UInt32($1.context) }
  guard contexts != 0 else { return paths }
  let components = enumerate { index, code, context, sid, sidLength in
    MsiEnumComponentsExW(nil, contexts, index, code, context, sid, sidLength)
  }
  for component in components {
    let clients = withWide(component.code) { componentCode in
      enumerate { index, code, context, sid, sidLength in
        MsiEnumClientsExW(componentCode, nil, UInt32(MSI_CONTEXT_ALL), index, code, context, sid, sidLength)
      }
    }
    for client in clients {
      guard let product = products[client.code], let path = product.componentPath(component.code) else { continue }
      paths[client.code, default: []].append(path)
    }
  }
  return paths
}

// MARK: - Locating Swift pieces

enum Role: String {
  case toolchain = "toolchain"
  case sdk = "SDK"
  case runtime = "runtime"
  case other = "other"
}

/// Key files that identify a package, in priority order. Build Tools also ships a
/// swiftCore.dll, so swift.exe has to win over it.
let keyFiles: [(file: String, role: Role, dirsUp: Int)] = [
  ("swift.exe", .toolchain, 2),        // <root>\usr\bin\swift.exe
  ("SDKSettings.json", .sdk, 0),       // <sdk>\SDKSettings.json
  ("swiftCore.dll", .runtime, 0),      // Runtimes\<ver>\usr\bin\swiftCore.dll
]

func parent(of path: String, dirsUp: Int) -> String {
  var parts = path.split(separator: "\\", omittingEmptySubsequences: false)
  parts.removeLast(min(parts.count, dirsUp + 1))
  return parts.joined(separator: "\\")
}

func fileName(_ path: String) -> String {
  String(path.split(separator: "\\").last ?? Substring(path)).lowercased()
}

struct SwiftPackage {
  let name: String
  let version: String
  let role: Role
  let location: String?
}

func locate(_ product: Product, paths: [String]) -> SwiftPackage {
  for key in keyFiles {
    if let path = paths.first(where: { fileName($0) == key.file.lowercased() }) {
      return SwiftPackage(name: product.name, version: product.version, role: key.role,
                          location: parent(of: path, dirsUp: key.dirsUp))
    }
  }
  return SwiftPackage(name: product.name, version: product.version, role: .other,
                      location: paths.first.map { parent(of: $0, dirsUp: 0) })
}

// MARK: - Main

let clock = ContinuousClock()
let start = clock.now

let swiftProducts = Dictionary(
  installedProducts().filter { $0.publisher == "swift.org" }.map { ($0.code, $0) },
  uniquingKeysWith: { first, _ in first })
let paths = installedPaths(of: swiftProducts)
let packages = swiftProducts.values.map { locate($0, paths: paths[$0.code] ?? []) }

let elapsed = clock.now - start
print("Swift packages (Publisher = swift.org): \(packages.count), found in \(elapsed)")

let byVersion = Dictionary(grouping: packages, by: \.version)
for version in byVersion.keys.sorted() {
  let group = byVersion[version]!
  func locations(_ role: Role) -> [String] {
    group.filter { $0.role == role }.compactMap(\.location).sorted()
  }
  print("\n  Swift \(version)")
  let toolchains = locations(.toolchain)
  print("    toolchain  \(toolchains.isEmpty ? "(not installed)" : toolchains.joined(separator: "\n               "))")
  for sdk in locations(.sdk) {
    let platform = sdk.split(separator: "\\").last.map(String.init) ?? sdk
    print("    SDK        \(platform.padding(12)) \(sdk)")
  }
  if locations(.sdk).isEmpty { print("    SDK        (none)") }
  let runtimes = locations(.runtime)
  print("    runtime    \(runtimes.isEmpty ? "(not installed)" : runtimes.joined(separator: ", "))")
}

extension String {
  func padding(_ width: Int) -> String {
    count >= width ? self : self + String(repeating: " ", count: width - count)
  }
}
