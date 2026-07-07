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
