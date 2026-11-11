# Mythos Live 1.0.7: App Store submission pack

Everything to paste into App Store Connect for 1.0.7, and the order to do it
in. The listing copy that does not change (name, subtitle, keywords, URLs,
copyright) stays as in `docs/app-store-listing-1.0.md`.

App Store Connect record: **Mythos Live**, Apple ID `6817279097`, bundle
`com.sklabs.mythoslive`.

## Which path: depends on where 1.0.6 stands

Check App Store Connect ▸ App Review first. Nobody on the Mac knows the
outcome of the 1.0.6 (98) resubmission of 2026-10-30.

| 1.0.6 is | Do this |
|---|---|
| Approved and released | **+ Version** ▸ `1.0.7`. "What's New" below is required. |
| Approved, not yet released | Release 1.0.6, then **+ Version** ▸ `1.0.7` as above. |
| Waiting for Review / In Review | Leave it. Submitting 1.0.7 now would pull 1.0.6 out of the queue. Add 1.0.7 once it lands. |
| Rejected | Edit the same version: change `1.0.6` to `1.0.7`, select the new build, replace the notes. No "What's New" field on a first version. |

## Steps on the version page

1. Version: `1.0.7`.
2. Build: select the 1.0.7 build Build Boy uploaded (build number in its
   report; processing takes 10 to 30 minutes after upload).
3. What's New: paste the text below (only shown if a version is already live).
4. Promotional text and description: paste the updated ones below.
5. App Review notes: paste over the existing notes.
6. Sign-in required: leave unticked. Sign-in is optional.
7. App Privacy: see "Privacy answers" below. One thing to check.
8. Export compliance: same answer as before (standard HTTPS only).
9. Add for Review ▸ Submit. Release: manual, as before.

## What's New (4000)

Your legends now reach out first, and there is a new face in the modern
roster.

• Characters you talk to most will send you a line of their own. Tap it to
  pick up the conversation.
• Leaderboards: see who has given each character the most, and where you
  stand. Open them from the trophy on the home screen or from any
  character's profile.
• Meet Ada, a programmer from Kenting with a PhD and a karaoke habit.
• New characters and gifts can now arrive without waiting for an update.
• Fixes and polish throughout.

## Promotional Text (170)

Your legends now message you first. Climb each character's leaderboard, meet
Ada in the modern roster, and pick up every story where you left it.

(149 characters)

## Description: one bullet added under HOW IT WORKS

Add after the Coins bullet; everything else stays as it is.

```
• Climb the leaderboards. Every character keeps a board of their most generous admirers.
```

## App Review notes (paste over the existing notes)

Mythos Live is a conversational AI app with fictional personalities drawn
from Greek mythology (Odysseus, Penelope, Zeus, Hercules and others). Users
talk only with AI-generated fictional personalities. There is no
user-to-user messaging and no user-generated content visible to other
users.

What is new in 1.0.7:

1. Leaderboards. Each character has a board ranking people by the coins
   they have spent on gifts for that character. Other people are shown only
   as a generated number, for example "User 482913". The viewer's own row
   says "You". No name, text, photo or any other content written or chosen
   by one user is ever shown to another, so the boards contain no
   user-generated content. To see one: tap the trophy icon at the top of
   the home screen, or open any character's profile and tap Leaderboard.

2. Notifications from characters. After the notification permission is
   granted, the app schedules a small number of local notifications written
   in the voice of the characters the person has talked to, titled for
   example "Zeus says". They are scheduled on the device. There is no push
   server and no device token is collected. None are delivered between
   21:30 and 09:30. Tapping one opens that conversation.

3. Content updates. The list of characters and gifts (names, descriptions,
   images, prices in the app's earned currency) can be refreshed from our
   server, the same way the replies already come from it. This is data
   only. No executable code is downloaded and the app's features do not
   change. One character, Ada, is delivered this way.

4. Service screens. If our service is down for maintenance, or a build is
   too old to work with it, the app shows a single screen saying so. The
   update screen links only to this app's App Store page. Neither is active
   in this build.

Coins are an in-app currency earned by daily check-in and conversation, and
also sold as consumable in-app purchases through the App Store. Gifts are
bought with Coins and are virtual items a character reacts to.

To see the core loop: open any character, send a few messages, tap the gold
coin chip in the chat header to see the wallet, send a gift, then open that
character's Leaderboard.

The photo library permission is used only to pick a profile avatar, stored
on the device.

## Privacy answers

Nothing new is collected for tracking or advertising. One item to check
against what is already declared under App Privacy:

- **Name.** If someone has typed a Name in their profile, 1.0.7 sends it to
  our server when they give a gift, where it is stored against their
  anonymous user id. It is not displayed to anyone. If "Name" (Contact
  Info) is not already declared as collected for App Functionality, add it:
  linked to the user's identity, not used for tracking. The sign-in added
  in 1.0.6 may already have put it there.
- Purchases and gift history were already collected; the leaderboard reads
  the same records.
- Notifications are local. No device token.

## Before pressing Submit

- [ ] 1.0.6 status checked, path chosen from the table above.
- [ ] Build shows as processed and selectable.
- [ ] Installed from TestFlight on a real iPhone and tried: a chat, a gift,
      the leaderboard, the trophy menu, Settings version line, and one
      notification tapped from the lock screen. None of this has been seen
      on a real device, only in the simulator.
- [ ] `RC_SANDBOX_CREDITS` stays `"true"` until Apple approves, then goes to
      `"false"` with a deploy (see `docs/buildboy-long-term-notes.md`).
- [ ] Screenshots: the existing set is still accurate. Optional: add one of
      a leaderboard.

## What was verified, and how

- Flutter and worker test suites pass on the commit this build is cut from.
- Web build of the same code is live and was checked by hand: Ada's card,
  leaderboards with real data shown as user numbers, the version line.
- iOS simulator (iPhone 17 Pro Max), merged code: the five notifications
  arrive in the planned mix (three from the most-talked-to character, one
  each from the second and third), with lines that fit the hour.
- Tapping a notification opened that conversation in the simulator before
  main was merged in. After the merge the simulator tooling could not tap
  inside Notification Centre, so that one step was not repeated.
- Not verified: anything on a real iPhone, the post-gift leaderboard
  snackbar in a running app, a notification tap from a cold start.
