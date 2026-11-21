# Spike B: App Attest for a customer's app (phase 5)

App id `net.wolvy.spike.attest`. It runs App Attest the way the SDK would:
- `generateKey`, then `attestKey` over the hash of
  `wolvy-attest|1|<challenge>|spike|ios|<bundle id>`;
- then `generateAssertion`.

**On the device, it checks what the server will check:**
- the RP ID against the team ids it can see (the keychain access group, the embedded profile,
  and N858H3328Q);
- the `aaguid` environment;
- the extensions;
- the nonce in the leaf certificate;
- the key id against the certificate's public key;
- which message the assertion signature covers.

The raw attestation and assertion go to the device log in numbered chunks (`WolvyAttest`), so the
PHP verifier can be tested on real objects.

**Build** (unsigned, for Sauce Labs, which re-signs):

```bash
xcodegen
xcodebuild -scheme WolvyAttestSpike -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

Then zip `Payload/WolvyAttestSpike.app` as an `.ipa`. In the simulator App Attest is not
supported, so only the first lines show.

**Not the SDK.** Kit and steps: `deploy/sdk-attest-spike/` in the workspace. Design:
`future plans/sdk-plan/phase-5-attestation.md`.
