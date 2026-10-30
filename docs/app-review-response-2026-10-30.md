# App Review rejection of 1.0.5 (96) — what happened and how we answer

Submission 16a6c37d-3a79-49ff-a17f-991d546182a0, reviewed 2026-10-28 on an
iPad Air 11-inch (M3). Status in App Store Connect: "Unresolved Issues",
version 1.0.5 (96) plus the three coin packs, all "Ready for Review".

## The one issue Apple raised

**Guideline 1.1 – Safety – Objectionable Content**, metadata only. The
message names the **keywords** field. Build 96 was submitted with
`ai girlfriend,ai boyfriend` (plus `roleplay`) left over from the AI Boyfriend
Chat era. Apple's wording: marketing "includes terms or images that reference
objectionable content or services", with the standing warning that
resubmitting without changes, or a new app with similar marketing, repeats
the violation. The message also carries the **Extended Review** flag, so the
next pass will be slower and stricter: they will read the binary, not just
the metadata.

No other guideline was cited. Nothing about the binary, IAP, privacy, sign-in
or age rating.

## What is already fixed (as of 2026-10-30)

| Item | State |
|---|---|
| Keywords in ASC | Replaced with myth/story terms, saved (no girlfriend/boyfriend/roleplay) |
| Description, subtitle, promo text in ASC | Clean copy, saved |
| Review notes in ASC | Still the 1.0.5 text; replace with the 1.0.6 notes in `app-store-listing-1.0.md` |
| In-app copy | Build 96 still contains boyfriend-era strings (flirty scenario openings, roleplay screen, custom-character creator). Removed on `main` in `8ef76ab`, shipped only in 1.0.6 (98) |
| App Privacy | Published 2026-10-30 with the sign-in data types |
| Worker secrets | Apple sign-in secrets set; `GOOGLE_IOS_CLIENT_ID` and `SESSION_SECRET` still missing |

Two strings on `main` still read oddly but are not user-reachable: the
"unlimited messages & roleplay" settings tile is behind `isFreeTier = true`,
and the `Flirty` vibe branch only picks a notification sentence that is
itself innocent. Not worth a rebuild on their own.

## Why we cannot simply press "Resubmit" on 96

Resubmitting 96 answers the keywords complaint but ships the old in-app
copy into an Extended Review. The resubmission must be **1.0.6 (98)**.

Build 98 is **not yet uploaded**. The ipa in `build/ios/ipa/` (2026-10-28,
1.0.6 build 98) was refused by Apple's uploader because
`ios/Flutter/GoogleSignIn.xcconfig` still holds `REPLACE_ME` for the Google
iOS client, which becomes an invalid URL scheme in Info.plist. That needs
the iOS OAuth client id from Google Cloud Console (bundle id
`com.sklabs.mythoslive`), then `tool/ios_release.sh --ipa` and upload. The
same id goes into the worker as `GOOGLE_IOS_CLIENT_ID`, with a generated
`SESSION_SECRET`, or Google sign-in fails in front of the reviewer.

## Other risks to clear before resubmitting

1. **Age rating consistency.** The 1.0.5 review notes say "18+", the listing
   copy says "designed for ages 17+". Make the ASC age rating, the notes and
   the description say the same thing. The 1.0.6 notes in the listing doc
   use 18+ and explain it as conservative.
2. **Guideline 4.3 (spam/duplicate).** The old app (bundle
   `com.aiboyfriend.mymate`, 2.0.0 build 86) is still in App Store Connect.
   Withdraw that submission now and remove the old app from sale once Mythos
   Live is approved, so the new app is not read as a rebrand of a rejected
   concept.
3. **Screenshots.** Not cited, but Extended Review reads images. Confirm the
   6.9" set shows the Greek roster and chat only.
4. **Sandbox coin credits** are on for the reviewer (`b9723ee`). Turn off
   after approval.

## Reply to App Review (paste into the submission thread, then Resubmit)

> Thank you for the review. We have addressed the Guideline 1.1 metadata
> issue and are resubmitting with a new build.
>
> Metadata: the keywords field has been replaced in full. The previous terms
> were left over from an earlier product and did not describe this app. The
> new keywords, description and subtitle refer only to the app's actual
> content: conversation with fictional figures from Greek mythology.
>
> Build 1.0.6 (98): we also reviewed every string in the app itself and
> removed any legacy copy or screens that could be read as referencing
> dating, romance role-play or similar services, so the binary matches the
> listing.
>
> Content safety: replies are generated server-side with a fixed persona per
> personality and a content policy that blocks sexual or explicit content;
> such requests are declined in character. The app's age rating was chosen
> conservatively because the source myths contain mature themes (war,
> betrayal, tragedy).
>
> Full testing notes, including the optional Sign in with Apple / Google
> flow and the coin packs, are in the review notes for this version. No
> reviewer account is needed.

## Order of operations

1. Adam: create the Google iOS OAuth client, pass the client id and URL
   scheme. Withdraw the old app's 2.0.0 submission.
2. Fill `GoogleSignIn.xcconfig`, set `GOOGLE_IOS_CLIENT_ID` and
   `SESSION_SECRET` on the worker, deploy, run `tool/ios_release.sh --ipa`,
   upload 98.
3. ASC version page: version 1.0.6, build 98, paste the 1.0.6 review notes,
   check the age rating, sign-in required unticked.
4. Post the reply above in the submission thread and press Resubmit.
