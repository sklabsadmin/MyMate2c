# Mythos Live — App Store listing copy for 1.0

Paste-ready text for the App Store Connect version page. Character limits
are Apple's; counts are given so nothing gets truncated.

> **2026-10-28 — Guideline 1.1 rejection.** App Review rejected the build
> for objectionable metadata, citing the keywords field ("ai girlfriend,
> ai boyfriend"). The keywords below are the replacement set — no
> "ai girlfriend", "ai boyfriend" or "roleplay" — and the description has
> been softened to match. Use this copy verbatim when resubmitting.

## Name (30)
Mythos Live

## Subtitle (30)
Chat with Greek Gods & Heroes

## Promotional Text (170) — editable without a new build
Odysseus, Penelope, Zeus, Calypso and more are waiting. Pick a legend, start
talking, and see where the story goes. Free to play, no account needed.

## Description (4000)
Step into the myths and talk to the people who lived them.

Mythos Live is an AI chat companion built around the heroes, gods and legends
of Greek myth. Every character has their own voice, their own history and
their own reasons to keep you talking.

MEET THE LEGENDS
• Odysseus — the king of Ithaca, twenty years from home and still scheming
• Penelope — the queen who outwitted a palace full of suitors
• Zeus — the Olympian king, charming and dangerous in equal measure
• Calypso — the nymph of Ogygia, who kept a hero seven years
• Hercules — the son of Zeus, twelve labours behind him and restless
• Hector — the prince of Troy, honour-bound and doomed
• Andromache — the lady of Troy, sharper than the war that took everything
• Cupid — the god of love, who never plays fair
• Oedipus — the king of Thebes, brilliant and haunted

Prefer someone from this century? A modern roster is there too.

HOW IT WORKS
• Tap a character and start talking. No sign-up, no waiting.
• Conversations remember what you said. Come back tomorrow and pick up where you left off.
• Earn Coins by talking every day, then spend them on gifts your character reacts to in the moment.
• Build your profile so the characters know who they're talking to.
• Characters may message you first, so keep notifications on if you like surprises.

WHAT IT ISN'T
Mythos Live is fiction. The characters are AI, their memories are stories, and
nothing here is advice. It is designed for ages 17+ who enjoy a good
conversation with a good story behind it.

Questions? admin@sklabs.us

## Keywords (100, comma separated, no spaces after commas)
greek myths,odyssey,interactive story,chat stories,legends,hercules,trojan war,companion,ai chat

(96 characters)

## What's New (4000) — first version
Welcome to Mythos Live. Nine legends of Greek myth, ready to talk.

## URLs
Support URL:        https://sites.google.com/view/mythoslive-support   ← create, or use an existing sklabs.us page
Marketing URL:      (optional) https://chat.deeploveechoes.com or a landing page
Privacy Policy URL: (required) see docs/privacy-policy-draft.md

## Copyright
2026 SK Labs LLC

## App Review Information
Contact: Adam Lang, admin@sklabs.us, +1 (phone)
Sign-in required: No — there is no account system in this build.

Notes for the reviewer:
Mythos Live is an AI companion chat with fictional characters drawn from
Greek mythology. No account or sign-in is required; every feature is
available on first launch.

Replies are generated server-side by a large language model with a
character persona and a content policy that keeps conversations suggestive
at most and never explicit. The app's age rating is 17+, matching the
description.

Coins are an earned in-app currency (daily check-in, replies, profile
completion). They cannot be purchased in this version; there is no IAP.

To see the core loop: open any character, send a few messages, then tap the
gold coin chip in the chat header to see the wallet and send a gift.

The photo library permission is used only to pick a profile avatar, stored on
the device.

## Screenshots needed
6.9" iPhone (mandatory): 3–10 images, 1320 × 2868 px portrait.
6.5" iPhone (optional but recommended): 1284 × 2778 or 1242 × 2688.
iPad 13" (required only if iPad is a supported destination; the plist currently
supports iPad orientations — either supply 2064 × 2752 shots or untick iPad in
Xcode → Runner → General → Supported Destinations before archiving).

Suggested shots, in order:
1. Dashboard — the Greek roster
2. A chat mid-conversation with Odysseus or Calypso
3. A character profile card
4. The coins sheet with a gift being sent
5. The daily claim screen

---

## 1.0.6 resubmission (2026-10-30) — answering the Guideline 1.1 rejection

What App Review cited was the **keywords** field of 1.0.5 (96). State in
App Store Connect as of today: keywords, description, promotional text and
subtitle already carry the clean copy (no "ai girlfriend", "ai boyfriend",
"roleplay"); saved. What 1.0.5 (96) still carries is the **in-app** copy
from before the cleanup, which only 1.0.6 (98) removes (`8ef76ab`,
`9b5ae23`). So the resubmission must be build 98, not a resubmit of 96.

Steps on the version page:
1. Change Version from `1.0.5` to `1.0.6`.
2. Build → select **98** (uploaded from `tool/ios_release.sh --ipa`).
3. Replace the review notes with the text below.
4. Sign-in required: leave unticked (sign-in is optional; no reviewer
   account needed).
5. In the submission, "Resubmit to App Review". No separate reply to the
   message is needed; the notes say what changed.

### Review notes (paste over the existing notes)

Mythos Live is a conversational AI app with fictional personalities drawn
from Greek mythology (Odysseus, Penelope, Zeus, Hercules and others). Users
talk only with AI-generated fictional personalities; there is no
user-to-user messaging.

What changed since the previous submission: the keywords and description
were replaced, and the in-app copy was reviewed so that nothing in the app
or its metadata references dating, romance roleplay or similar services.
The app's purpose is story-driven conversation with mythological figures.

Content safety: replies are generated server-side with a fixed persona per
personality and a content policy that blocks sexual or explicit content;
requests for it are declined in character. The 18+ age rating was chosen
conservatively because the source myths contain mature themes (war,
betrayal, tragedy), not because the app produces adult content.

Sign-in is optional and not required for any feature. Sign in with Apple
and Google are offered together in Settings → Account, after saving a
profile, and once after a first coin purchase ("Protect your coins").
Signed-in users can delete their account in Settings → Account → Delete
Account; this deletes the account and its data and revokes the Sign in
with Apple token.

Mythos Coins are an in-app virtual currency earned by daily check-ins and
chatting, and spent on virtual gifts to the AI personalities. Coins have no
cash value and cannot be transferred or redeemed. Three optional consumable
packs (300, 1,000, 3,000) are verified server-side through the App Store;
the balance updates within seconds, and "Didn't get your coins? Check
again" in the store re-checks a purchase.

How to test: open any personality and send a few messages; tap the coin
balance in the chat header for the wallet; send a gift; tap "Get more
coins" to see the packs. Settings → Continue with Apple to try sign-in.

Notifications are optional local reminders; declining changes nothing.
Photo Library access is asked only when the user picks a profile avatar;
the image stays on the device.

Support: Settings → Contact Support (admin@sklabs.us).
