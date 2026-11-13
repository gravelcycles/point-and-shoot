# Auto-updating app on your iPhone (no Mac needed)

After this one-time setup:

**a change is pushed → GitHub builds, signs, and uploads to TestFlight → your iPhone updates
itself.** It usually takes 15–25 minutes end to end. You don't click anything.

- **Build check** (`.github/workflows/build.yml`) compiles the app on every push. It's free
  because the repo is public.
- **TestFlight** (`.github/workflows/testflight.yml`) ships every push that changes the app.
  It skips itself until the secrets below are added.

You need the **Apple Developer Program** ($99/year, developer.apple.com/programs). Every
step below happens in a web browser.

## One-time setup (~15 minutes)

1. **Pick a bundle ID** that's yours, e.g. `com.yourname.pointandshoot`.
   - developer.apple.com/account → **Certificates, Identifiers & Profiles** →
     **Identifiers** → **+** → App IDs → App.
   - Description "Point & Shoot", Bundle ID *Explicit* = your ID → Continue → Register.
2. **Find your Team ID.** It's in developer.apple.com/account → **Membership details**: a
   10-character code like `A1B2C3D4E5`.
3. **Create the app record.**
   - appstoreconnect.apple.com → **Apps** → **+** → **New App** → iOS.
   - Name "Point & Shoot" (or anything that's free), pick your bundle ID, SKU
     `pointandshoot` → Create.
4. **Create an API key** so GitHub can sign and upload for you.
   - App Store Connect → **Users and Access** → **Integrations** → **App Store Connect
     API** → Team Keys → **+**.
   - Name it "GitHub", Access **Admin** (Admin is needed to create the signing
     certificate) → Generate.
   - Note the **Issuer ID** (shown above the list) and the key's **Key ID**.
   - **Download API Key** (`AuthKey_XXXX.p8`). You can only download it once.
5. **Make yourself a tester and turn on automatic distribution.**
   - App Store Connect → your app → **TestFlight** → **Internal Testing** → **+**.
   - Name the group, and tick **Enable automatic distribution** so every new build goes
     to the group without any clicks.
   - Add yourself.
6. **Add the secrets to GitHub.**
   - github.com/gravelcycles/point-and-shoot → **Settings** → **Secrets and variables** →
     **Actions** → **New repository secret**. Add each one:

   | Secret name | Value |
   |---|---|
   | `ASC_KEY_ID` | Key ID from step 4 |
   | `ASC_ISSUER_ID` | Issuer ID from step 4 |
   | `ASC_KEY_P8` | open the `.p8` file in a text editor and paste **everything**, including the BEGIN/END lines |
   | `APPLE_TEAM_ID` | Team ID from step 2 |
   | `BUNDLE_ID` | bundle ID from step 1 |

   Secrets stay hidden even though the repo is public. They never appear in logs.
7. **On your iPhone**, install **TestFlight** from the App Store and sign in with the
   same Apple ID.
8. **Ship the first build.** Go to the repo's **Actions** tab → **TestFlight** → **Run
   workflow**. About 10 minutes later the app appears in TestFlight → tap **Install**.
9. In TestFlight, open Point & Shoot and turn on **Automatic Updates**.

From then on, every change installs itself. TestFlight also sends a notification when
a new build arrives.

## Good to know

- Each TestFlight build works for 90 days. Every new push resets that clock.
- If a TestFlight run fails, the error is shown at the top of the run in the Actions tab.
  Paste it to Claude.
- `codemagic.yaml` is an optional alternative builder (500 free Mac minutes/month). You
  don't need it now that GitHub Actions is free for this repo.
