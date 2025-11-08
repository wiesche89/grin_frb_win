# grin_frb_win

A Flutter desktop wallet that embeds the official [`grin-wallet`](https://github.com/mimblewimble/grin-wallet)
codebase via a Rust bridge. The project targets Windows first, but the structure keeps the Rust core inside
`rust/` so it can be re-used on other platforms.

---

## 1. Project Structure

```
grin_frb_win/
├─ lib/                         # Flutter UI, localization, view models
│  ├─ src/ui/                   # Screens and widgets (HomeScreen is the main shell)
│  ├─ src/wallet/               # Simple stores & DTOs mirroring grin-wallet data
│  └─ src/rust/                 # flutter_rust_bridge bindings (auto-generated)
├─ rust/                        # Local Rust crate wrapping grin-wallet APIs
│  ├─ src/api.rs                # Async-safe wrapper functions exported to Flutter
│  ├─ src/wallet.rs             # Thin layer around grin-wallet’s owner API
│  └─ src/frb_generated.rs      # flutter_rust_bridge glue (generated)
├─ grin-wallet/                 # Vendored upstream repo (commit pinned via cargo patch)
└─ README.md
```

- The Rust crate depends on `grin-wallet` as a workspace member. All wallet logic is delegated to
  the upstream project so we stay in sync with protocol upgrades.
- Flutter communicates with Rust through [`flutter_rust_bridge`](https://github.com/fzyzcjy/flutter_rust_bridge),
  so any change in `rust/src/api.rs` requires regenerating the bindings (see section 3).

---

## 2. Installation (Flutter & Rust)

1. **Install Flutter**
   ```powershell
   # Grab the SDK from https://docs.flutter.dev/get-started/install
   setx PATH "$env:PATH;<flutter-sdk>\bin"
   flutter config --enable-windows-desktop
   flutter doctor      # check for missing tools
   ```
   - If `flutter doctor` reports “Visual Studio not installed”, install the **Desktop development with C++**
     workload (Windows 10/11 SDK included).

2. **Install Rust**
   ```powershell
   # Install rustup from https://www.rust-lang.org/tools/install
   rustup toolchain install stable
   rustup default stable
   rustup show   # verify stable-x86_64-pc-windows-msvc is active
   ```
   Visual Studio Build Tools from the previous step provide the MSVC linker required by Rust.

3. **Project dependencies**
   - From the repo root run `flutter pub get`.
   - Build the Rust crate once to fetch cargo dependencies:
     ```powershell
     cd rust
     cargo build
     ```

---

## 3. Development With flutter_rust_bridge (FRB) Generator

Whenever you modify `rust/src/api.rs` or the data types exposed to Flutter, regenerate the bindings:

1. Install the CLI tools (one-time):
   ```powershell
   cargo install flutter_rust_bridge_codegen
   cargo install cbindgen
   ```
2. Regenerate the glue code (example for PowerShell with long-path-safe UNC syntax):
   ```powershell
   # 1) avoid UNC in creation step so the file exists
   $rootNoUnc = "C:\ProjekteGit\github\wiesche89\grin_frb_win"
   New-Item -ItemType Directory -Force "$rootNoUnc\rust\src" | Out-Null
   [System.IO.File]::WriteAllText("$rootNoUnc\rust\src\frb_generated.rs", "")

   # 2) use the extended path prefix for the generator (handles long paths)
   $root = "\\?\C:\ProjekteGit\github\wiesche89\grin_frb_win"
   flutter_rust_bridge_codegen generate `
     --rust-root "$root\rust" `
     --rust-input crate::api `
     --dart-output "$root\lib\src\rust\frb_generated.dart" `
     --rust-output "$root\rust\src\frb_generated.rs" `
     --watch
   ```
3. Rebuild:
   ```powershell
   cd rust && cargo build
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

Tips:
- Keep the Rust API `#[frb]`-annotated and prefer simple JSON-serializable DTOs.
- The generated files (`lib/src/rust/frb_generated.dart/*` and `rust/src/frb_generated.rs`) should not be edited manually.

---

## 4. Building on Windows

1. Ensure `flutter doctor` shows no blocking issues and that the Windows desktop device is enabled.
2. From the repo root:
   ```powershell
   flutter pub get
   cd rust
   cargo build --release   # optional but ensures the bridge compiles
   cd ..
   flutter run -d windows  # or flutter build windows
   ```
3. The built executable appears under `build/windows/x64/runner/Release` when using `flutter build windows`.

For packaging/distribution you can sign the generated `.msi` or `.exe` using the standard Flutter desktop tooling.

---

Happy hacking! Contributions to both the Flutter UI and the Rust bridge are welcome. Always keep the
`grin-wallet` subtree up to date to benefit from upstream fixes and security patches.

---

## 5. Feature Overview & Usage

### Unlock Flow
- **Unlock existing wallet** – Point `Wallet directory` to an existing folder and enter the password (leave empty if none).  
- **Create & unlock** – Choose a new directory. You’ll be prompted to set a password (optional). The wallet is created and opened immediately.  
- **Restore from seed phrase** – Opens a dialog to paste the 24‑word phrase and set a new password.  
- **Logout** – Toolbar button that locks the wallet, stops auto-refresh, and returns to the unlock dialog.

> Passwords are optional for grin wallets; the UI reflects this by allowing empty inputs, but strongly recommends setting one for protection.

### Seed Phrase Handling
- **Show seed phrase** – In Overview → “Slatepack address” card, click *Show seed phrase*. You’ll be prompted for the wallet password (empty allowed). The phrase can be copied from the dialog.  
- **Restore from seed** – As described above, accessible directly from the unlock dialog.

### Wallet Operations
- **Node connection** – Change the node URL, with quick chips for `grincoin.org` and `localhost`.  
- **Overview cards** – Display tip height, spendable, awaiting, locked, immature balances, plus last update timestamp.  
- **Transactions** – Direction-aware cards with color-coded amounts, confirmations (`x/10` capped), view-slatepack button, and cancel action that automatically hides when the tx hits the pool or has confirmations.  
- **Slatepack tools** – Send/receive wizards, incoming slate inspection, S2/I2 response creation, and finalization path.  
- **Outputs & accounts** – View outputs (toggle spent) and switch accounts.  
- **Toolbar actions** – Language toggle, manual refresh, full sync, logout, and the global log panel at the bottom for status messages.

### Tips
- All dialogs are translated via `context.trNow` so they work even when triggered from button callbacks.  
- Creating/restoring a wallet never overwrites existing data silently. Use distinct directories for different wallets.  
- For seed and password dialogs, empty inputs are accepted when operating on an unprotected wallet, matching grin’s behavior.

With these pieces the Flutter shell exposes almost all `grin-wallet` functionality in a desktop-friendly way.
