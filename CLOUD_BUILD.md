# Cloud builds → TestFlight (no Mac needed)

> **Build checks** run on GitHub Actions on every push. They're free because the repo is
> public: see the Actions tab. Codemagic below is an optional alternative, and its
> TestFlight workflow is the way to get the app onto your phone.

Builds run on [Codemagic](https://codemagic.io). The free personal plan gives you 500 Mac
build minutes a month. A build check takes a few minutes; a TestFlight build takes about
10–15 minutes.

## 1. Build check (free, no Apple account needed)

1. Sign up at codemagic.io with your GitHub account. Use a **personal** account: free
   minutes don't apply to teams.
2. **Add application** → GitHub → `point-and-shoot` → choose the
   **codemagic.yaml** configuration.
3. That's it. Every push now compiles the app. A failed build shows the exact errors;
   paste them to Claude to get them fixed.

## 2. Get the app on your iPhone with TestFlight

Requires the **Apple Developer Program** ($99/year, developer.apple.com/programs). All of
these steps happen in a web browser.

1. **Pick a bundle ID** that's yours, e.g. `com.yourname.pointandshoot`.
   - developer.apple.com → Certificates, Identifiers & Profiles → **Identifiers** → **+** →
     App IDs → App → enter the bundle ID → Continue → Register.
2. **Create the app record.**
   - appstoreconnect.apple.com → **Apps** → **+** → New App → iOS → choose that bundle ID →
     any name and SKU → Create.
3. **Create an API key** so Codemagic can sign and upload for you.
   - App Store Connect → **Users and Access** → **Integrations** → App Store Connect API →
     **+** → name it "Codemagic", access **App Manager** → Generate.
   - Write down the **Issuer ID** and **Key ID**.
   - **Download** the `.p8` file. You can only download it once.
4. **Make a signing key.** Codemagic can generate one for you: in your app's
   Codemagic settings, look for code signing and "generate a private key". Or, on any
   computer with a terminal:
   `ssh-keygen -t rsa -b 2048 -m PEM -f cert_key -q -N ""` → use the contents of `cert_key`.
5. **In Codemagic**, open your app → **Environment variables**. Add these, all in a group
   named `app_store`, and mark the keys **Secret**:

   | Variable | Value |
   |---|---|
   | `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from step 3 |
   | `APP_STORE_CONNECT_KEY_IDENTIFIER` | Key ID from step 3 |
   | `APP_STORE_CONNECT_PRIVATE_KEY` | full contents of the `.p8` file |
   | `CERTIFICATE_PRIVATE_KEY` | full contents of `cert_key` from step 4 |
   | `BUNDLE_ID` | your bundle ID from step 1 |

6. **Add yourself as a tester.** App Store Connect → your app → **TestFlight** → Internal
   Testing → **+** → create a group → add your Apple ID.
7. **Start a build:** Codemagic → your app → **Start new build** → workflow **TestFlight**.
8. Install **TestFlight** from the App Store on your iPhone. The build appears there
   within roughly 10–30 minutes, once Apple finishes processing it. Tap Install.

Each TestFlight build lasts 90 days. Start a new build whenever you want the latest version.
