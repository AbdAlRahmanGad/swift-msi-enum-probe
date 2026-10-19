# swift-msi-enum-probe

Finds every Swift toolchain, SDK and runtime installed by the official Windows installer, using only what Windows Installer has registered. It never opens the cached `.msi`, hard-codes no component GUIDs, and needs no change to the installer. It only reads.

```
swift build -c release --build-system native
.build\release\swift-msi-enum-probe.exe
```

## How it works

1. `MsiEnumProductsExW` lists the products visible to the current user. Keep the ones whose `Publisher` is `swift.org`, and note which install contexts they use.
2. `MsiEnumComponentsExW` lists every component registered in those contexts. Windows Installer has no "components of this product" call, so this is the only way in without the package.
3. For each component, `MsiEnumClientsExW` lists the products that use it. Skip any that aren't Swift.
4. `MsiGetComponentPathExW` returns the installed path of the component's key file. A path ending in `swift.exe`, `SDKSettings.json` or `swiftCore.dll` identifies the toolchain, SDK or runtime, as in swift-msi-probe.

Every step uses documented APIs, and the path comes from where the file was actually installed, so a changed install folder doesn't matter.

## Example output

A machine with Swift 6.4.0, plus the 6.2.4 runtime and Android SDK but no 6.2.4 toolchain. Release build:

```
Swift packages (Publisher = swift.org): 11, found in 0.92 seconds

  Swift 6.2.4
    toolchain  (not installed)
    SDK        Android.sdk  %LOCALAPPDATA%\Programs\Swift\Platforms\6.2.4\Android.platform\Developer\SDKs\Android.sdk
    runtime    %LOCALAPPDATA%\Programs\Swift\Runtimes\6.2.4\usr\bin

  Swift 6.4.0
    toolchain  %LOCALAPPDATA%\Programs\Swift\Toolchains\6.4.0+Asserts
    SDK        Android.sdk  %LOCALAPPDATA%\Programs\Swift\Platforms\6.4.0\Android.platform\Developer\SDKs\Android.sdk
    SDK        Windows.sdk  %LOCALAPPDATA%\Programs\Swift\Platforms\6.4.0\Windows.platform\Developer\SDKs\Windows.sdk
    runtime    %LOCALAPPDATA%\Programs\Swift\Runtimes\6.4.0\usr\bin
```

That matches swift-msi-probe exactly.

## Cost

The test machine had about 19,000 registered components, roughly 7,500 per user and 11,500 per machine. Walking all of them took about 2 s, and roughly 1.75 s of that went to `MsiEnumClientsExW`, one call per component. Swift installs per user, so limiting step 2 to the contexts the Swift products use skips the per-machine components and brought it to about 0.9 s. swift-msi-probe took 0.13 to 0.22 s on the same machine, because the cached `.msi` lets it look up a handful of components directly.

So expect around a second per lookup on a machine with that many components. If that's too slow for `swiftly list`, swiftly can cache the result, using the set of Swift product codes as the key: the cache is valid until a product is installed or removed.

## Other routes I tried

Both are faster, and both have problems that rule them out as the main method.

**Fixed-GUID `PATH` components.** Each package adds its `bin` folder to `PATH` through a component called `UserPathVariable`, and those GUIDs are hard-coded in the WiX source. The component has no key file, so `MsiGetComponentPathExW` returns its folder directly. On 6.4.0 it returned `Toolchains\6.4.0+Asserts\usr\bin\`, `Runtimes\6.4.0\usr\bin\` and `...\Windows.sdk\` instantly. But:

- The runtime and SDK GUIDs differ between releases (`b83f6521…` for the 6.2 runtime, `bc309c80…` for 6.4), so swiftly would need a table of them.
- From 6.4 on, the toolchain component is conditioned on `ADDTOOLCHAINTOPATH=1`. With Asserts and NoAsserts both installed, only the default one has it.
- Every one is conditioned on `NOT ALLUSERS=1`, so per-machine installs, which `main` now supports, don't have them.

**The bundle's persisted variables.** Burn 4 (engine 4.0.5.0 in both the 6.4.0 and 6.2.4 bundles) writes persisted variables to `HKCU\...\Uninstall\{bundle code}\variables`. `InstallRoot` is there, but as the raw formatted string, `[LocalAppDataFolder]Programs\Swift`, which swiftly would have to expand. On top of that:

- It's Burn's private storage, not an interface.
- It gives only the root, so swiftly would have to build `Toolchains\<version>+Asserts` itself from the layout.
- It records what the bundle asked for, not where the MSIs actually put their files.
- I haven't checked what it holds after an install to a custom folder.
