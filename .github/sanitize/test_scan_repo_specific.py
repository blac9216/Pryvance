import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("scan_repo_specific.py")
spec = importlib.util.spec_from_file_location("scanner", MODULE_PATH)
scanner = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(scanner)


class SanitizerPositiveTests(unittest.TestCase):
    def assert_caught(self, text: str, needle: str) -> None:
        findings = scanner.scan_text("fixture.txt", text)
        self.assertTrue(any(needle in finding for finding in findings), findings)

    def test_non_example_email_is_caught(self):
        value = "alice" + "@" + "household.test"
        self.assert_caught(value, "non-example email")

    def test_github_domain_is_not_generally_exempt(self):
        value = "alice" + "@" + "github.com"
        self.assert_caught(value, "non-example email")

    def test_valid_ssn_shape_is_caught(self):
        value = "219" + "-09-9999"
        self.assert_caught(value, "SSN/TIN-shaped")

    def test_luhn_valid_pan_is_caught(self):
        value = "4111" + " 1111 1111 1111"
        self.assert_caught(value, "payment-card-shaped")

    def test_valid_iban_is_caught(self):
        value = "GB82" + "WEST12345698765432"
        self.assert_caught(value, "IBAN-shaped")

    def test_contextual_valid_routing_number_is_caught(self):
        value = "routing number: " + "021" + "000021"
        self.assert_caught(value, "ABA routing-number-shaped")

    def test_non_documentation_ipv4_is_caught(self):
        value = "10" + ".23.45.67"
        self.assert_caught(value, "non-documentation IPv4")

    def test_local_fqdn_is_caught(self):
        value = "finance" + ".household.internal"
        self.assert_caught(value, "local/internal FQDN")


class SanitizerNegativeTests(unittest.TestCase):
    def assert_clean(self, text: str) -> None:
        self.assertEqual(scanner.scan_text("fixture.txt", text), [])

    def test_reserved_example_email_is_allowed(self):
        self.assert_clean("person@example.com")

    def test_git_github_transport_identity_is_allowed(self):
        self.assert_clean("git@github.com")

    def test_invalid_ssn_placeholder_is_allowed(self):
        self.assert_clean("000-00-0000")

    def test_non_luhn_long_number_is_allowed(self):
        self.assert_clean("1234567890123456")

    def test_routing_like_digits_without_context_are_allowed(self):
        self.assert_clean("021000021")

    def test_documentation_ipv4_ranges_are_allowed(self):
        self.assert_clean("192.0.2.10 198.51.100.20 203.0.113.30")

    def test_loopback_is_allowed(self):
        self.assert_clean("127.0.0.1")

    def test_example_internal_fqdn_is_allowed(self):
        self.assert_clean("db.example.internal")


if __name__ == "__main__":
    unittest.main()
