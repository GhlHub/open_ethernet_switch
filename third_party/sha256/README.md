# SHA-256

Brad Conte's public-domain SHA-256 implementation, copied from the Vivado/Vitis
2026.1 embeddedsw `mipicsiss_v1_14/examples/xmipi_vck_example/sha256.{c,h}`.
Upstream: https://github.com/B-Con/crypto-algorithms

Upstream releases the code into the public domain without restrictions or
warranty. The original attribution is retained. Local change: cast message
bytes to WORD before left shifts to avoid signed-integer overflow.

Used for the lab management PBKDF2-HMAC-SHA256 verifier. Not a hardened
side-channel-resistant cryptographic subsystem. Tests compare against Python
hashlib and check malformed credentials and public/read versus write policy.
