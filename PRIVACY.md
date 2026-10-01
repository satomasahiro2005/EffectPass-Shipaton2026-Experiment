# EffectPass privacy policy

Last updated 2026-09-30

EffectPass is a separate, experimental app made for the RevenueCat Shipaton 2026
hackathon by nemut.ai. It is built from the open-source code of
[EffectDeck](https://github.com/satomasahiro2005/EffectDeck), but it is not EffectDeck, and
this policy covers EffectPass only. EffectDeck has its own policy.

nemut.ai does not collect or store any of your data. There is no account to sign up for,
no analytics and no advertising. The one service EffectPass talks to on its own is
RevenueCat, for the EffectPass Pro subscription (see **Purchases**).

## Audio

When you select **EffectPass** as the output in Control Center, audio from other apps is
handed to the app's media device extension and passed to the app over a loopback
connection on your device (127.0.0.1). It is processed and played back on the same device.

- Audio never leaves the device.
- Audio is not recorded or written to storage.
- Handling audio makes no network connection.

## Purchases

EffectPass Pro is handled by [RevenueCat](https://www.revenuecat.com/). When the app starts
with a RevenueCat key, the RevenueCat SDK contacts RevenueCat's servers to read the
offering and your subscription status, and again when you buy or restore. It sends:

- a random, anonymous user ID that the SDK creates on the device (not your name, email or
  Apple ID)
- your purchases and their status (which product, when, whether it is active)
- basic app and device details the SDK needs, such as the app version, iOS version,
  store country and language, and your IP address as with any request

nemut.ai can see the anonymous ID and its purchases in the RevenueCat dashboard, and
nothing else about you. The hackathon build uses RevenueCat's Test Store: no payment is
taken and no card or Apple ID payment is involved. RevenueCat's handling is covered by the
[RevenueCat Privacy Policy](https://www.revenuecat.com/privacy). A build without a
RevenueCat key does not contact RevenueCat at all.

## Files you add

Impulse response files and JSFX scripts you import stay in the app's own storage on your
device. They are not uploaded anywhere.

## Links

The app downloads a file only when you ask it to (**Import JSFX → From Link**, or a link
shared to EffectPass from another app). The request goes to the site in the address, which
sees your IP address as with any download.

EffectPass has no ChatGPT buttons and sends nothing to OpenAI.

Sharing a chain makes a link to the EffeTune web app on effetune.frieve.com, which
nemut.ai does not run. The chain is carried in the link itself, and nothing is uploaded
when the link is made.

## Reporting a problem

**Report a problem** in Settings opens an email to support@nemut.ai or a new issue on the
EffectPass GitHub repository, with a report filled in: the app version, the device model
and iOS version, the app's audio settings and output, and the end of the app's log. You can
change or delete any of it first. Nothing is sent until you send the email or submit the
issue (for GitHub, the report is part of the page's address, so it reaches GitHub when the
page opens).

## Settings and presets

The current chain and your saved presets are mirrored to your own iCloud through Apple's
iCloud key-value storage, so your other devices running EffectPass can read them. It goes
to your iCloud account, not to nemut.ai. See the
[Apple Privacy Policy](https://www.apple.com/legal/privacy/).

## Third-party code

The built-in audio effects come from [EffeTune](https://github.com/Frieve-A/effetune) by
Yoshiyuki Kobayashi (MIT), with small patches. The only third-party code that uses the
network is the RevenueCat SDK, described above. License texts are in the app under
Settings → About → Licenses and in [NOTICE.md](NOTICE.md).

## Children

This app is not directed at children.

## Contact

support@nemut.ai (write "EffectPass" in the subject).
