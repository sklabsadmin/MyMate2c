# MyMate (AI Boyfriend Chat)

Welcome to the **MyMate (AI Boyfriend Chat)** repository. This documentation provides a complete, end-to-end guide to the architecture, services, and setup instructions required to take ownership, modify, and deploy this application.

## 📱 Tech Stack & Architecture

This application is built with modern, scalable technologies to ensure security, high performance, and ease of maintainability.

- **Frontend Framework:** [Flutter](https://flutter.dev/) (Dart) - targeting iOS and Android.
- **State Management:** [Riverpod](https://riverpod.dev/) (`flutter_riverpod`)
- **Routing:** [GoRouter](https://pub.dev/packages/go_router)
- **In-App Purchases (Subscriptions):** [RevenueCat](https://www.revenuecat.com/) (`purchases_flutter`)
- **AI/LLM Provider:** OpenAI API (Defaulting to `gpt-4o-mini`)
- **Secure Backend Proxy:** Cloudflare Workers (JavaScript) - Used to securely hide OpenAI API keys from the client and enforce rate-limiting.

### Project Structure

The project follows a modular, feature-based architecture:

```text
app/
├── backend/                  # Cloudflare Worker code for secure API proxying
│   └── src/worker.js         # The main proxy script handling HMAC and Rate Limiting
├── lib/
│   ├── main.dart             # App entry point
│   └── src/
│       ├── app.dart          # Root widget and routing setup
│       ├── core/             # Core utilities, config, services (RevenueCat, etc.)
│       └── features/         # Feature modules (e.g., chat, home, onboarding)
├── assets/                   # Images, fonts, and other static files
├── .env                      # Environment variables (MUST BE CONFIGURED)
└── pubspec.yaml              # Flutter dependencies and project metadata
```

---

## 🛠️ Initial Setup & Configuration

Follow these steps to get the app running on your local machine.

### 1. Prerequisites
- Install [Flutter SDK](https://docs.flutter.dev/get-started/install) (Version 3.10.0 or higher recommended).
- Set up an IDE (VS Code, Android Studio, or IntelliJ).
- Install the [Cloudflare Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/install-and-update/) if you plan to deploy the backend.

### 2. Install Dependencies
Run the following command in the root of the Flutter project to install all Dart dependencies:
```bash
flutter pub get
```

### 3. Environment Variables (`.env`)
The app uses a `.env` file to securely load API endpoints and secrets. 
1. Copy `.env.example` to a new file named `.env` in the root directory.
2. Fill in the required variables:

```env
OPENAI_API_KEY=your_openai_api_key_here
OPENAI_BASE_URL=https://your-worker-name.your-subdomain.workers.dev
WORKER_URL=https://your-worker-name.your-subdomain.workers.dev
APP_SECRET=your_generated_secret_key_here
```

*Note: The `APP_SECRET` must exactly match the secret configured in your Cloudflare Worker. This is used for HMAC signature generation to prevent unauthorized requests.*

---

## ☁️ Backend Setup (Cloudflare Worker)

To prevent your OpenAI API keys from being scraped from the mobile app, all AI requests are routed through a Cloudflare Worker proxy. 

### Features of the Worker:
- **HMAC Signature Verification:** Ensures requests are actually coming from your app.
- **Model Enforcement:** Forces the usage of a specific model (e.g., `gpt-4o-mini`) to control costs.
- **Rate Limiting:** Prevents abuse by limiting requests per user and per day.

### Deployment Steps:
1. Navigate to the `backend/` directory.
2. Deploy the worker using Wrangler or copy the code from `backend/src/worker.js` directly into the Cloudflare Dashboard.
3. Configure the following **Environment Variables / Secrets** in your Cloudflare Worker:
   - `OPENAI_API_KEY`: Your actual OpenAI Secret Key.
   - `APP_SECRET`: The exact same secret string you put in the app's `.env` file.
4. (Optional) Set up a KV Namespace named `RATE_LIMITER` and bind it to the worker to enable the rate-limiting functionality.

---

## 📊 Chat Logging (v2)

The worker already contains the code to log every `/api/chat` request (user message, assistant reply, token usage, errors) to a D1 database — see `persistConversationLog()` in `backend/src/worker.js` and the schema in `backend/migrations/0001_conversation_logs.sql`. Without a D1 database bound, requests just skip logging (see `REQUIRE_CHAT_LOGS` below).

The `mymate-v2` worker is the active development target; `mymate2c` is a frozen checkpoint (nothing deploys to it anymore). Its D1 database is `mymate2_db`, bound in `wrangler.jsonc` (`CHAT_LOGS_DB`). If you're setting this up fresh for a different environment/account, adjust the steps below accordingly.

### One-time setup
1. Create the database (skip if it already exists):
   ```bash
   npx wrangler d1 create mymate2_db
   ```
2. Copy the `database_id` it prints into the `d1_databases` block in `wrangler.jsonc` (or grab it from the Cloudflare dashboard: Workers & Pages → D1 → your database → overview page).
3. Apply the schema — either run this locally:
   ```bash
   npx wrangler d1 migrations apply CHAT_LOGS_DB --remote
   ```
   or paste the contents of `backend/migrations/0001_conversation_logs.sql` into the D1 database's **Console** tab in the Cloudflare dashboard and execute it.
4. Deploy (or just merge to `main` — the existing auto-deploy picks up the `wrangler.jsonc` binding):
   ```bash
   npm run deploy
   ```
5. Optional: once you've confirmed logs are landing, set `REQUIRE_CHAT_LOGS` to `"true"` in `wrangler.jsonc`'s `vars` so chat requests fail loudly instead of silently skipping the log if the database is ever unreachable.

### Viewing logs
A minimal admin viewer is served directly by the worker (kept separate from the end-user app), protected by HTTP Basic Auth:
1. Set an admin secret, either via CLI (`npx wrangler secret put ADMIN_TOKEN`) or in the dashboard: Workers & Pages → the worker → Settings → Variables and Secrets → Add → type "Secret" → name `ADMIN_TOKEN`.
2. Visit `https://<your-worker>/admin/logs` and sign in with any username and that token as the password.
3. Filter by `user_id` / `chat_id` / `status`, paginate, and click a row to see the full request/response payloads.

The same data is available as JSON at `GET /api/admin/logs` (list, supports `?user_id=`, `?chat_id=`, `?status=`, `?limit=`, `?offset=`) and `GET /api/admin/logs/:id` (single record), both behind the same Basic Auth.

Conversation logs contain full user/assistant message text — treat `ADMIN_TOKEN` as sensitive and be mindful of privacy/retention obligations for what's stored.

---

## 💰 Monetization (RevenueCat)

The app handles premium subscriptions (e.g., unlocking limits or features) via **RevenueCat**.

### Configuration Steps:
1. Create a project in your [RevenueCat Dashboard](https://app.revenuecat.com/).
2. Setup your Apple App Store and Google Play Store credentials.
3. Create an **Entitlement** named `premium_access`.
4. Open `lib/src/core/services/revenue_cat_service.dart`.
5. Update the placeholder API keys with your actual Public SDK Keys from RevenueCat:

```dart
  // lib/src/core/services/revenue_cat_service.dart
  static const String _iosApiKey = 'your_ios_api_key_here';
  static const String _androidApiKey = 'your_android_api_key_here';
```

---

## 🚀 Running and Building the App

### Running Locally
To run the app on a connected emulator or physical device:
```bash
flutter run
```

### Building for Production
**Android:**
To build an App Bundle for the Google Play Store:
```bash
flutter build appbundle
```

**iOS:**
To build an IPA for the Apple App Store (requires macOS and Xcode):
```bash
flutter build ipa
```
*Make sure to configure your signing certificates and provisioning profiles in Xcode before building.*

---

## 🎨 Modifying the App

- **Theme & Colors:** App styling is generally defined in the `ThemeData` within `lib/src/app.dart` or specific feature presentation files.
- **AI Personality/Prompts:** You can modify how the AI boyfriend responds by tweaking the initial system prompts sent to OpenAI. Look inside the `chat` feature module (`lib/src/features/chat/services/openai_service.dart` or similar).
- **Adding New Features:** Follow the existing Riverpod + feature-based structure. Create a new folder under `lib/src/features/` with `presentation`, `domain`, and `data` subdirectories.

---
*Documentation auto-generated for project handover. Best of luck with the app!*
