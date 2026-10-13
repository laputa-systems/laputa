# WebAuthn-Minimal

`webauthn-minimal` is the mirror's pure Rust WebAuthn relying-party library.
It supports P-256/ES256 credentials, with passkey and hardware-key registration
modes. It accepts `none` and structurally valid `packed` attestation; it does
not verify attestation signatures or certificates, and rejects other formats.

## Use the API

Construct `RelyingParty::new(rp_id, rp_origin, rp_name)` with the expected RP ID
and exact browser origin.

1. Call `start_registration(user_id, username, mode)` with
   `RegistrationMode::Passkey` or `RegistrationMode::HardwareKey`. Send the
   returned creation options to the browser and retain `RegChallenge`.
2. Pass the browser's `RegistrationResponse` and that challenge state to
   `finish_registration`. Persist the returned `StoredCredential`: credential
   ID, AAGUID, P-256 public key coordinates, and signature counter.
3. Call `start_authentication(credentials)` with the user's stored credentials.
   Send the request options to the browser and retain `AuthChallenge`.
4. Pass the browser's `AuthenticationResponse`, challenge state, and selected
   credential to `finish_authentication`. Persist the returned updated credential.

The caller owns challenge/session lifetime and credential storage. Challenges
contain 32 random bytes. Both finish methods check ceremony type, challenge,
and origin; credential parsing checks RP ID and user presence. Authentication
verifies the signature over authenticator data and the client-data hash,
accepting raw R+S or DER signature encoding.

A non-increasing counter after a positive stored counter logs a warning and
still succeeds. Authenticators that always return zero are supported; counter
tracking alone does not establish that a credential was cloned.
