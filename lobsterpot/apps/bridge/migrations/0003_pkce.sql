-- PKCE: store code_challenge (SHA-256 hex of codeVerifier) with each pairing code.
-- The iOS client generates a random codeVerifier, sends SHA-256(codeVerifier) as
-- codeChallenge at /pair/start, then sends codeVerifier at /pair/finish.
-- Bridge verifies SHA-256(codeVerifier) === stored codeChallenge before issuing token.
ALTER TABLE pairing_codes ADD COLUMN code_challenge TEXT;
