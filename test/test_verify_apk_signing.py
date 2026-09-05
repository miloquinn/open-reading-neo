import unittest

from tool.verify_apk_signing import verify_certificate


class ApkSigningTest(unittest.TestCase):
    fingerprint = "0123456789abcdef" * 4

    def test_accepts_signer_labels_from_multiple_build_tools(self):
        for label in [
            "Signer #1",
            "Signer #1:",
            "V2 Signer:",
            "Signer (minSdkVersion=28, maxSdkVersion=2147483647)",
        ]:
            with self.subTest(label=label):
                verify_certificate(
                    f"{label} certificate SHA-256 digest: {self.fingerprint}",
                    self.fingerprint,
                )

    def test_accepts_same_certificate_repeated_by_signature_schemes(self):
        line = f"Signer #1 certificate SHA-256 digest: {self.fingerprint}"
        verify_certificate(f"{line}\n{line}", self.fingerprint.upper())

    def test_rejects_missing_wrong_or_ambiguous_certificates(self):
        valid = f"Signer #1 certificate SHA-256 digest: {self.fingerprint}"
        wrong = "Signer #2 certificate SHA-256 digest: " + "f" * 64
        for report in ["", wrong, f"{valid}\n{wrong}",
                       f"Signer #1 public key SHA-256 digest: {self.fingerprint}"]:
            with self.subTest(report=report), self.assertRaises(ValueError):
                verify_certificate(report, self.fingerprint)


if __name__ == "__main__":
    unittest.main()
